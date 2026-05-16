#!/usr/bin/env python3
# Copyright (c) 2026 Muzaffer Kal <muzaffer@kal.cc>
# All rights reserved.
"""Generate the hierarchical RTL design doc at docs/design/index.html.

Walks every src/rtl/**/*.sv, extracts a small model of each module
(header comment, parameters, ports, child instances), generates an
SVG block diagram for each module, optionally augments leaf modules
with a real yosys-slang + netlistsvg synthesized schematic, and emits a
single self-contained HTML page.

Usage:
  python3 scripts/gen_design_doc.py                 full doc -> docs/design/index.html
  python3 scripts/gen_design_doc.py --public        public doc: leaf internals
                                                    (source/diagram/netlist) stripped,
                                                    yosys synthesis skipped
  python3 scripts/gen_design_doc.py --out <path>    write the HTML elsewhere
"""

from __future__ import annotations

import base64
import dataclasses
import gzip
import html
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional


# ──────────────────────────────────────────────────────────────────
# Paths
# ──────────────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parents[1]
RTL_ROOT  = REPO_ROOT / "src" / "rtl"
PKG_DIR   = RTL_ROOT / "pkg"
DOCS_DIR  = REPO_ROOT / "docs" / "design"
SVG_CACHE = DOCS_DIR / "svg_cache"

# Set by --public on the command line. In public mode the generator skips
# the yosys-slang synthesis stage and strips every leaf module down to
# name/title/description/ports/parameters -- no source, no block diagram,
# no synthesized schematic. The connectivity hierarchy is kept so the
# public doc still describes the design's structure. See main().
PUBLIC_MODE = False

# In public mode, raw SystemVerilog source is embedded only for these
# modules -- every other module (leaf or connectivity) has its source
# stripped. Mirrors the publish allowlist: only ktc_chip_top.sv ships.
PUBLIC_SOURCE_MODULES = {"ktc_chip_top"}

# Source files we explicitly skip in the parser (stubs/black-boxes).
# Stubs are *kept* in the yosys-slang filelist (slang needs port-compatible
# blackbox declarations for cv32e40x_core / cve2_top), but excluded from
# the SV parser so the design tree shows the real upstream modules.
STUB_FILES = {
    RTL_ROOT / "sim" / "upstream_stubs.sv",
}

# Tool autodetect for yosys-slang pipeline.
YOSYS = shutil.which("yosys")
NETLISTSVG = shutil.which("netlistsvg")

# Include directories needed by the upstream packages referenced from
# the chip filelist (cve2 / cv32e40x).
SLANG_INC_DIRS = [
    str(Path.home() / "projects" / "cve2" / "vendor" / "lowrisc_ip"
        / "ip" / "prim" / "rtl"),
    str(Path.home() / "projects" / "cv32e40x" / "rtl" / "include"),
]

# Slang relaxation flags required to elaborate the chip RTL. These match
# the lint waivers documented in CLAUDE.md (verilator's -Wno-WIDTHEXPAND
# / -Wno-SELRANGE / etc.) plus the SV-strictness slang inherits from
# upstream slang.
SLANG_FLAGS = [
    "--allow-use-before-declare",   # forward refs in ktc_tile_top.sv
    "--ignore-assertions",
    "--ignore-timing",
    "-Wno-range-oob",               # deliberate width-casts in
    "-Wno-range-width-oob",         # circular_buffer, addr-gens, fpu_acc
]


# ──────────────────────────────────────────────────────────────────
# Data model
# ──────────────────────────────────────────────────────────────────
@dataclasses.dataclass
class Param:
    name: str
    type: str
    default: str


@dataclasses.dataclass
class Port:
    name: str
    direction: str   # "input", "output", "inout", or "interface"
    type: str        # "logic [31:0]", "noc_if.rx", etc.
    group: str = ""  # optional group label from preceding // comment
    # Unpacked array dimension as it appears after the name, e.g. "[N]" or
    # "[L1_NUM_PORTS]". Empty string if the port is not an unpacked array.
    array_dim: str = ""


@dataclasses.dataclass
class Instance:
    inst_name: str
    module_name: str
    line: int


@dataclasses.dataclass
class Module:
    name: str
    file: Path
    line: int
    title: str
    description: str
    parameters: list
    ports: list
    instances: list
    body_lines: int
    is_stub: bool = False
    # Filled in later.
    auto_svg: str = ""
    yosys_svg: str = ""
    yosys_error: str = ""
    parents: set = dataclasses.field(default_factory=set)

    def file_rel(self) -> str:
        return str(self.file.relative_to(REPO_ROOT))


# ──────────────────────────────────────────────────────────────────
# SystemVerilog parser (regex-based; relies on the project's
# consistent header-comment + formatting conventions)
# ──────────────────────────────────────────────────────────────────
RE_MODULE_START = re.compile(r"^\s*module\s+(\w+)\b", re.MULTILINE)
RE_ENDMODULE    = re.compile(r"^\s*endmodule\b", re.MULTILINE)

# Reserved words that must NOT be mistaken for a module instantiation.
SV_KEYWORDS = {
    "if", "else", "for", "while", "case", "casex", "casez", "endcase",
    "begin", "end", "always", "always_ff", "always_comb", "always_latch",
    "initial", "final", "assign", "function", "endfunction",
    "task", "endtask", "generate", "endgenerate", "module", "endmodule",
    "package", "endpackage", "import", "export", "typedef", "parameter",
    "localparam", "wire", "reg", "logic", "bit", "byte", "int", "integer",
    "shortint", "longint", "string", "real", "input", "output", "inout",
    "return", "break", "continue", "fork", "join", "join_any", "join_none",
    "interface", "endinterface", "modport", "class", "endclass",
    "enum", "struct", "union", "packed", "unique", "priority",
    "automatic", "static", "const", "var", "ref",
    "posedge", "negedge", "or", "and", "not", "xor",
    "$display", "$time", "$finish", "$readmemh", "$readmemb", "$signed",
    "$unsigned", "$clog2", "$bits", "$random",
}


def strip_block_comments(text: str) -> str:
    """Remove /* ... */ blocks. Preserve line numbering."""
    out = []
    i = 0
    while i < len(text):
        if text[i:i+2] == "/*":
            end = text.find("*/", i + 2)
            if end == -1:
                break
            # Keep the newlines so line numbers don't shift.
            chunk = text[i:end+2]
            out.append("".join(c if c == "\n" else " " for c in chunk))
            i = end + 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def extract_header_comment(lines, module_start_idx) -> tuple[str, str]:
    """Walk backwards from the module declaration finding the
    immediately-preceding `//`-comment block. Return (title, description).

    Title = first non-copyright-line that isn't blank.
    Description = remaining lines joined."""
    # Walk up to find the contiguous comment block above module.
    end = module_start_idx
    start = end
    while start > 0 and lines[start-1].lstrip().startswith("//"):
        start -= 1
    # Optional blank line above comment block then more comment? skip.
    while start > 0 and lines[start-1].strip() == "":
        start -= 1
        while start > 0 and lines[start-1].lstrip().startswith("//"):
            start -= 1
    raw = lines[start:end]
    # Strip leading "//" and at most one space.
    cleaned = []
    for ln in raw:
        s = ln.lstrip()
        if s.startswith("//"):
            s = s[2:]
            if s.startswith(" "):
                s = s[1:]
            cleaned.append(s.rstrip())
        elif s == "":
            cleaned.append("")
    # Drop leading copyright lines and the standard "All rights reserved." line.
    while cleaned and (
        cleaned[0].lower().startswith("copyright") or
        cleaned[0].lower().startswith("all rights")
    ):
        cleaned.pop(0)
    # Drop blank lines at top/bottom.
    while cleaned and cleaned[0] == "":
        cleaned.pop(0)
    while cleaned and cleaned[-1] == "":
        cleaned.pop()
    if not cleaned:
        return "", ""
    title = cleaned[0]
    desc_lines = cleaned[1:]
    # Drop leading blanks of description.
    while desc_lines and desc_lines[0] == "":
        desc_lines.pop(0)
    description = "\n".join(desc_lines)
    return title, description


def parse_param_block(text: str) -> list[Param]:
    """Parse the body of `#( ... )`. text contains everything between
    the outer parentheses (already stripped)."""
    params = []
    # Split on commas, respecting nesting.
    parts = split_top_level(text, ",")
    for p in parts:
        p = p.strip()
        if not p:
            continue
        # Strip leading "parameter" / "localparam".
        p = re.sub(r"^\s*(parameter|localparam)\s+", "", p)
        # Form: <type?> <name> = <default>  OR <type?> <name>
        m = re.match(r"^(.*?)(\b\w+\b)\s*(?:=\s*(.+))?$", p, re.DOTALL)
        if not m:
            continue
        type_part = m.group(1).strip()
        name = m.group(2)
        default = (m.group(3) or "").strip()
        params.append(Param(name=name, type=type_part, default=default))
    return params


def split_top_level(text: str, delim: str) -> list[str]:
    """Split text on `delim` chars that are at paren-depth 0."""
    out = []
    depth = 0
    buf = []
    for ch in text:
        if ch in "([{":
            depth += 1
            buf.append(ch)
        elif ch in ")]}":
            depth -= 1
            buf.append(ch)
        elif ch == delim and depth == 0:
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        out.append("".join(buf))
    return out


def parse_port_block(text: str) -> list[Port]:
    """Parse the body of `( ... )` after the parameter block. Each
    comma-separated entry is one port declaration. Inline group
    comments (`// ─── Foo ───` style or `// Foo`) above a port
    attach to it as `group`."""
    ports = []
    # Pre-split on commas at top level.
    parts = split_top_level(text, ",")
    current_group = ""
    for p in parts:
        # Walk through lines: any leading `//` comment becomes group.
        stripped_lines = p.splitlines()
        port_text_lines = []
        for ln in stripped_lines:
            s = ln.strip()
            if s.startswith("//"):
                comment = s[2:].strip()
                # Filter out separator-only comments like "─────".
                if any(ch.isalnum() for ch in comment):
                    current_group = comment
            else:
                # Strip any trailing `// ...` line comment so it doesn't
                # leak into the next port's decoded type (e.g. a port
                # declared as `input logic s_rvalid // unused`).
                idx = s.find("//")
                if idx >= 0:
                    s = s[:idx].rstrip()
                if s:
                    port_text_lines.append(s)
        port_text = " ".join(l.strip() for l in port_text_lines).strip()
        if not port_text:
            continue
        port = decode_port_decl(port_text, current_group)
        if port:
            ports.append(port)
    return ports


def decode_port_decl(decl: str, group: str) -> Optional[Port]:
    """Decode a single port declaration string."""
    # Case A: explicit direction (input|output|inout). Capture the optional
    # unpacked array dim after the name so wrapper-generation can replay it.
    m = re.match(r"^(input|output|inout)\s+(.+?)\s+(\w+)\s*(\[[^\]]*\])?\s*$",
                 decl)
    if m:
        direction = m.group(1)
        type_part = m.group(2).strip()
        name      = m.group(3)
        arr       = m.group(4) or ""
        return Port(name=name, direction=direction, type=type_part, group=group, array_dim=arr)
    # Case B: interface port, e.g. `noc_if.rx local_in` or `noc_if foo`.
    m = re.match(r"^(\w+(?:\.\w+)?)\s+(\w+)\s*(\[[^\]]*\])?\s*$", decl)
    if m:
        type_part = m.group(1)
        name      = m.group(2)
        arr       = m.group(3) or ""
        return Port(name=name, direction="interface", type=type_part, group=group, array_dim=arr)
    return None


def find_balanced(text: str, start: int, open_ch: str, close_ch: str) -> int:
    """Return the index *after* the matching close paren that pairs
    with text[start] == open_ch."""
    assert text[start] == open_ch
    depth = 0
    i = start
    while i < len(text):
        ch = text[i]
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def parse_module_block(text: str, module_start: int, module_end: int,
                       lines, line_offsets) -> Optional[Module]:
    """Parse one `module ... endmodule` block. module_start/end are
    char offsets in `text`."""
    block = text[module_start:module_end]
    m = RE_MODULE_START.match(block)
    if not m:
        return None
    name = m.group(1)

    # After module-name, skip `import pkg::*;` clauses, then optionally
    # parse `#(params)`, then `(ports);`.
    after_name = m.end()
    parameters = []
    ports = []

    i = after_name
    # Skip any "import <ident>::*;" / "import <ident>::<ident>;" clauses.
    import_re = re.compile(r"\s*import\s+[\w:*,\s]+;")
    while True:
        m_imp = import_re.match(block, i)
        if not m_imp:
            break
        i = m_imp.end()

    while True:
        # Find the next semantic token: '#', '(', ';'
        # but stop scanning if we hit ';' (no ports at all).
        rest = block[i:]
        mhash = re.search(r"#\s*\(", rest)
        mparen = re.search(r"\(", rest)
        msemi = re.search(r";", rest)
        starts = [(p.start(), p.group()) for p in
                  [mhash, mparen, msemi] if p is not None]
        if not starts:
            break
        starts.sort()
        first = starts[0]
        if first[1].startswith(";"):
            # No port list at all.
            break
        if first[1].startswith("#"):
            # Parameter block. Find '(' after '#'.
            paren_idx = i + first[0] + first[1].index("(")
            close = find_balanced(block, paren_idx, "(", ")")
            if close == -1:
                break
            param_body = block[paren_idx+1:close-1]
            parameters = parse_param_block(param_body)
            i = close
            continue
        # '(' = start of port list.
        paren_idx = i + first[0]
        close = find_balanced(block, paren_idx, "(", ")")
        if close == -1:
            break
        port_body = block[paren_idx+1:close-1]
        ports = parse_port_block(port_body)
        i = close
        break

    # Find module-body line count (rough).
    line_count = block.count("\n")

    # Find instances within the body. Heuristic: a line of the form
    # `<word>  ...  <word>  (`  where the first word is not a keyword
    # and not the current module's name. We look at the joined-trimmed
    # block-body source.
    body_text = block[i:]   # after port list close-paren
    instances = parse_instances(body_text, name, module_start, line_offsets)

    # Locate the module's start line in the file.
    start_line = char_offset_to_line(line_offsets, module_start) + 1

    # Extract header comment by walking backwards in `lines`.
    title, description = extract_header_comment(lines, start_line - 1)

    return Module(
        name=name,
        file=Path(),
        line=start_line,
        title=title,
        description=description,
        parameters=parameters,
        ports=ports,
        instances=instances,
        body_lines=line_count,
    )


def parse_instances(body_text: str, parent_name: str,
                    body_char_offset: int, line_offsets) -> list[Instance]:
    """Find module instantiations inside a module body."""
    instances = []
    # Pattern A: `module_name #(...)  inst_name (` (with named params)
    # Pattern B: `module_name inst_name (`
    # We match each candidate, verify it's not a keyword, and verify
    # the next-token chain looks like an instance (not always_ff etc.).
    # Use a forgiving regex and post-filter.
    cand_re = re.compile(
        r"^\s*([a-zA-Z_]\w*)"               # 1: module name
        r"(?:\s*#\s*\([^()]*(?:\([^()]*\)[^()]*)*\))?"  # optional #(...)
        r"\s+([a-zA-Z_]\w*)"                # 2: inst name
        r"\s*\(\s*$",                       # opening paren
        re.MULTILINE,
    )
    for m in cand_re.finditer(body_text):
        modname = m.group(1)
        inst    = m.group(2)
        if modname in SV_KEYWORDS:
            continue
        if inst in SV_KEYWORDS:
            continue
        if modname == parent_name:
            continue
        # Verify there is a `)` followed by `;` somewhere after the open.
        # (Cheap sanity check: searching the next ~5000 chars.)
        tail = body_text[m.end():m.end()+8000]
        if ";" not in tail:
            continue
        if ")" not in tail:
            continue
        # Filter out interface declarations: `noc_if foo (), bar ();`
        # Treat as instance only if there's a port-list-shaped body
        # OR module names that look like RTL modules. Conservative: keep
        # all; the post-pass that resolves child_module will simply
        # leave those entries pointing nowhere if they aren't real
        # modules.
        char = body_char_offset + m.start()
        ln = char_offset_to_line(line_offsets, char) + 1
        instances.append(Instance(inst_name=inst, module_name=modname, line=ln))
    # De-dup by (inst_name) keeping first occurrence.
    seen = set()
    out = []
    for ins in instances:
        if ins.inst_name in seen:
            continue
        seen.add(ins.inst_name)
        out.append(ins)
    return out


def char_offset_to_line(line_offsets, char) -> int:
    """Binary search for the line index containing `char`. line_offsets[i] is
    the start char of line i."""
    lo, hi = 0, len(line_offsets) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if line_offsets[mid] <= char:
            lo = mid
        else:
            hi = mid - 1
    return lo


def parse_file(path: Path) -> list[Module]:
    raw = path.read_text(encoding="utf-8", errors="replace")
    text = strip_block_comments(raw)
    lines = raw.splitlines()
    # Build line-offset table from `text` (block-comments stripped but
    # newlines preserved, so line numbering matches `lines`).
    line_offsets = [0]
    for i, ch in enumerate(text):
        if ch == "\n":
            line_offsets.append(i + 1)

    modules = []
    pos = 0
    while pos < len(text):
        m = RE_MODULE_START.search(text, pos)
        if not m:
            break
        # Find matching endmodule.
        end_m = RE_ENDMODULE.search(text, m.end())
        if not end_m:
            break
        mod = parse_module_block(text, m.start(), end_m.end(),
                                 lines, line_offsets)
        if mod is not None:
            mod.file = path
            if path in STUB_FILES:
                mod.is_stub = True
            modules.append(mod)
        pos = end_m.end()
    return modules


def parse_all() -> list[Module]:
    modules = []
    for path in sorted(RTL_ROOT.rglob("*.sv")):
        try:
            modules.extend(parse_file(path))
        except Exception as e:
            print(f"  parse FAIL {path.relative_to(REPO_ROOT)}: {e}",
                  file=sys.stderr)
    return modules


# ──────────────────────────────────────────────────────────────────
# Hierarchy resolution
# ──────────────────────────────────────────────────────────────────
def resolve_hierarchy(modules: list[Module]):
    name_to_mod = {m.name: m for m in modules}
    for m in modules:
        for ins in m.instances:
            child = name_to_mod.get(ins.module_name)
            if child:
                child.parents.add(m.name)
    return name_to_mod


def find_roots(modules: list[Module]) -> list[Module]:
    """Roots = modules with no parent inside the project. Prefer
    canonical top names if available; otherwise take all."""
    preferred = ["ktc_chip_top", "ktc_tile_top", "ktc_host_tile"]
    name_to_mod = {m.name: m for m in modules}
    roots = []
    for p in preferred:
        if p in name_to_mod:
            roots.append(name_to_mod[p])
    seen = {m.name for m in roots}
    for m in modules:
        if not m.parents and m.name not in seen and not m.is_stub:
            roots.append(m)
            seen.add(m.name)
    return roots


# ──────────────────────────────────────────────────────────────────
# Auto block-diagram SVG (per module)
# ──────────────────────────────────────────────────────────────────
def auto_block_svg(mod: Module, by_name: dict) -> str:
    """Render an SVG showing `mod`'s ports and instances. Inner
    instance boxes carry data-module=<child> so the JS layer can
    drill into them on click."""
    inputs  = [p for p in mod.ports if p.direction == "input"]
    outputs = [p for p in mod.ports if p.direction == "output"]
    ifaces  = [p for p in mod.ports if p.direction == "interface"
                                     or p.direction == "inout"]

    insts = mod.instances or []

    # Layout constants.
    PORT_H        = 18
    PORT_GAP      = 4
    SIDE_PAD      = 16
    TOP_PAD       = 60
    BOT_PAD       = 30
    INNER_W       = 200
    INNER_H       = 64
    INNER_GAP_X   = 36
    INNER_GAP_Y   = 22

    n_l = max(len(inputs), 1)
    n_r = max(len(outputs), 1)
    port_col_h = max(n_l, n_r) * (PORT_H + PORT_GAP) + PORT_GAP

    # Decide layout of inner instance grid.
    if insts:
        cols = 1 if len(insts) <= 2 else (2 if len(insts) <= 6 else 3)
        rows = (len(insts) + cols - 1) // cols
        inst_grid_w = cols * INNER_W + (cols - 1) * INNER_GAP_X
        inst_grid_h = rows * INNER_H + (rows - 1) * INNER_GAP_Y
    else:
        cols, rows = 0, 0
        inst_grid_w = 360
        inst_grid_h = 0

    body_w = max(inst_grid_w, 360)
    body_h = max(port_col_h, inst_grid_h + 80) + BOT_PAD

    PORT_LABEL_W = 170   # space outside the box for port name + width
    total_w = PORT_LABEL_W + SIDE_PAD + body_w + SIDE_PAD + PORT_LABEL_W
    total_h = TOP_PAD + body_h

    box_x = PORT_LABEL_W + SIDE_PAD
    box_y = TOP_PAD - 24
    box_w = body_w
    box_h = body_h - 6

    parts = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {total_w} {total_h}" '
        f'class="block-svg" width="{total_w}" height="{total_h}">'
    )
    # Outer box for this module.
    parts.append(f'<rect class="mod-outer" x="{box_x}" y="{box_y}" '
                 f'width="{box_w}" height="{box_h}" rx="10" ry="10" />')

    # Title at top.
    title = mod.name
    if mod.parameters:
        psum = "#(" + ", ".join(p.name for p in mod.parameters[:4]) + ")"
        title += " " + psum
    parts.append(f'<text class="mod-title" x="{box_x + box_w/2}" y="{box_y + 24}" '
                 f'text-anchor="middle">{html.escape(title)}</text>')

    # Left side: inputs
    for i, p in enumerate(inputs):
        y = box_y + 40 + i * (PORT_H + PORT_GAP)
        parts.append(_port_marker(box_x, y, "left", p))
    # Right side: outputs
    for i, p in enumerate(outputs):
        y = box_y + 40 + i * (PORT_H + PORT_GAP)
        parts.append(_port_marker(box_x + box_w, y, "right", p))
    # Bottom side: interface / inout ports (split left/right halves).
    for i, p in enumerate(ifaces):
        x = box_x + 40 + i * 130
        if x > box_x + box_w - 40:
            break
        parts.append(_port_marker_bottom(x, box_y + box_h, p))

    # Inner instance boxes (clickable). Grid layout.
    if insts:
        # Center grid horizontally inside the box.
        grid_x = box_x + (box_w - inst_grid_w) / 2
        # Place vertically below the title area.
        grid_y = box_y + 70
        for idx, ins in enumerate(insts):
            r = idx // cols
            c = idx % cols
            x = grid_x + c * (INNER_W + INNER_GAP_X)
            y = grid_y + r * (INNER_H + INNER_GAP_Y)
            child = by_name.get(ins.module_name)
            is_real = (child is not None)
            cls = "inst" + (" inst-real" if is_real else " inst-extern")
            tip = ""
            if is_real and child.title:
                tip = child.title
            parts.append(
                f'<g class="{cls}" '
                f'data-module="{html.escape(ins.module_name)}" '
                f'data-inst="{html.escape(ins.inst_name)}" '
                f'tabindex="0">'
                f'<title>{html.escape(tip)}</title>'
                f'<rect x="{x}" y="{y}" width="{INNER_W}" height="{INNER_H}" '
                f'rx="6" ry="6"/>'
                f'<text x="{x + INNER_W/2}" y="{y + INNER_H/2 - 6}" '
                f'class="inst-name" text-anchor="middle">'
                f'{html.escape(ins.inst_name)}</text>'
                f'<text x="{x + INNER_W/2}" y="{y + INNER_H/2 + 12}" '
                f'class="inst-mod" text-anchor="middle">'
                f': {html.escape(ins.module_name)}</text>'
                f'</g>'
            )
    else:
        # Leaf — show description placeholder inside the box.
        leaf_msg = "leaf module"
        parts.append(f'<text x="{box_x + box_w/2}" y="{box_y + box_h/2}" '
                     f'class="leaf-label" text-anchor="middle">'
                     f'{html.escape(leaf_msg)}</text>')

    parts.append("</svg>")
    return "".join(parts)


def _port_marker(box_x: float, y: float, side: str, p) -> str:
    """Render a small port stub + label on the left or right of a box."""
    PORT_H = 18
    PORT_LEN = 14
    if side == "left":
        x1 = box_x - PORT_LEN
        x2 = box_x
        label_x = x1 - 4
        anchor = "end"
        arrow = "→"
    else:
        x1 = box_x
        x2 = box_x + PORT_LEN
        label_x = x2 + 4
        anchor = "start"
        arrow = "→"
    width = _port_width_str(p.type)
    label = p.name + (f" [{width}]" if width else "")
    if p.direction == "output":
        label = f"{label} {arrow}" if side == "right" else f"{arrow} {label}"
    elif p.direction == "input":
        label = f"{arrow} {label}" if side == "left" else f"{label} {arrow}"
    return (
        f'<line class="port-stub" x1="{x1}" y1="{y+PORT_H/2}" '
        f'x2="{x2}" y2="{y+PORT_H/2}"/>'
        f'<text class="port-label" x="{label_x}" y="{y+PORT_H/2+4}" '
        f'text-anchor="{anchor}">{html.escape(label)}</text>'
    )


def _port_marker_bottom(x: float, y: float, p) -> str:
    """Interface/inout ports rendered on the bottom edge."""
    return (
        f'<line class="port-stub" x1="{x}" y1="{y}" x2="{x}" y2="{y+12}"/>'
        f'<text class="port-label" x="{x}" y="{y+24}" text-anchor="middle">'
        f'{html.escape(p.name)}</text>'
        f'<text class="port-type" x="{x}" y="{y+38}" text-anchor="middle">'
        f'{html.escape(p.type)}</text>'
    )


def _port_width_str(t: str) -> str:
    """Extract `[hi:lo]` width annotation from a port type string."""
    m = re.search(r"\[([^\]]+)\]", t)
    if m:
        return m.group(1)
    return ""


# ──────────────────────────────────────────────────────────────────
# Yosys + netlistsvg pipeline for leaf modules
# ──────────────────────────────────────────────────────────────────
def _expand_filelist(path: Path) -> list[Path]:
    """Expand a verilator `-f` filelist (recursively). Returns absolute
    .sv file paths in declaration order. Ignores +incdir+ and comments."""
    out = []
    for raw in path.read_text().splitlines():
        s = raw.strip()
        if not s or s.startswith("//") or s.startswith("+incdir+"):
            continue
        if s.startswith("-f "):
            nested = Path(s.split(maxsplit=1)[1])
            if not nested.is_absolute():
                nested = (REPO_ROOT / nested).resolve()
            out.extend(_expand_filelist(nested))
            continue
        p = Path(s)
        if not p.is_absolute():
            p = (REPO_ROOT / p).resolve()
        if p.suffix == ".sv":
            out.append(p)
    return out


_SLANG_FILES_CACHE = None


def _chip_filelist_for_slang() -> list[Path]:
    """Return the chip-level filelist expanded to absolute .sv paths.
    Stubs are kept (slang needs blackbox decls for upstream cores)."""
    global _SLANG_FILES_CACHE
    if _SLANG_FILES_CACHE is not None:
        return _SLANG_FILES_CACHE
    chip_f = RTL_ROOT / "karadelik_chip.f"
    if not chip_f.exists():
        _SLANG_FILES_CACHE = []
        return _SLANG_FILES_CACHE
    _SLANG_FILES_CACHE = _expand_filelist(chip_f)
    return _SLANG_FILES_CACHE


# JSONs bigger than this confuse netlistsvg (stack overflow under
# node). Skip rendering and report a clean error.
_NETLIST_JSON_MAX_BYTES = 2 * 1024 * 1024

# Packages to import in synthetic wrappers. Only Karadelik packages are
# imported because the upstream packages (cve2_pkg, cv32e40x_pkg) define
# colliding identifiers like X_ID_WIDTH that slang flags as ambiguous if
# both are pulled in. None of the wrapped leaves expose upstream types
# in their non-interface ports.
_WRAPPER_IMPORTS = [
    "ktc_params", "ktc_opcodes", "ktc_types",
    "noc_pkg", "cvxif_pkg",
]


def _slang_wrapper_sv(mod: Module) -> Optional[str]:
    """Generate a synthetic SystemVerilog wrapper that instantiates
    `mod` with each interface port bound to a fresh interface instance
    and each non-interface port bound to a local logic wire. This
    lets yosys-slang elaborate leaves that have interface modport
    ports (which slang refuses to leave dangling at top-level).

    Returns the wrapper source string, or None if the module's ports
    use a feature the wrapper synthesizer doesn't handle (currently:
    parameterized interface types like `regfile_if #(.W(...))`).
    """
    lines = [
        f"// Auto-generated wrapper for yosys-slang synthesis of {mod.name}.",
        f"module __wrap_{mod.name};",
    ]
    for pkg in _WRAPPER_IMPORTS:
        lines.append(f"  import {pkg}::*;")
    lines.append("")
    bindings = []
    for p in mod.ports:
        if p.direction == "interface":
            # `noc_if.rx` -> base type `noc_if`.
            base = p.type.split(".")[0]
            if "#" in base or "(" in base:
                return None  # parameterized interface — give up
            arr = f" {p.array_dim}" if p.array_dim else ""
            lines.append(f"  {base} if_{p.name}{arr}();")
            bindings.append(f"    .{p.name}(if_{p.name})")
        else:
            arr = f" {p.array_dim}" if p.array_dim else ""
            lines.append(f"  {p.type} w_{p.name}{arr};")
            bindings.append(f"    .{p.name}(w_{p.name})")
    lines.append("")
    lines.append(f"  {mod.name} u (")
    lines.append(",\n".join(bindings))
    lines.append("  );")
    lines.append("endmodule")
    return "\n".join(lines)


def yosys_slang_synthesize(mod: Module) -> tuple[bool, str]:
    """Run `yosys -m slang` with `read_slang` over the full chip
    filelist and produce `svg_cache/<mod.name>.json`. Returns
    (ok, err_msg). Each invocation is independent (~80 ms for small
    leaves), so the caller can parallelize across leaves.

    For leaves with interface modport ports, a synthetic wrapper is
    written to `svg_cache/_wrap_<mod>.sv` first, slang is given
    `--top __wrap_<mod>` plus the wrapper, then yosys renames the
    inner mangled module back to `<mod>` and drops the wrapper before
    writing JSON."""
    if not YOSYS:
        return False, "yosys not on PATH"
    files = _chip_filelist_for_slang()
    if not files:
        return False, "chip filelist not found"

    SVG_CACHE.mkdir(parents=True, exist_ok=True)
    json_path = SVG_CACHE / f"{mod.name}.json"
    try:
        json_path.unlink()
    except FileNotFoundError:
        pass

    has_iface_port = any(p.direction == "interface" for p in mod.ports)
    wrapper_path = None
    post_read_cmds = []
    if has_iface_port:
        wrapper_src = _slang_wrapper_sv(mod)
        if wrapper_src is None:
            return False, "module has parameterized interface ports (wrapper not supported)"
        wrapper_path = SVG_CACHE / f"_wrap_{mod.name}.sv"
        wrapper_path.write_text(wrapper_src, encoding="utf-8")
        slang_top = f"__wrap_{mod.name}"
        slang_extra_flags = ["--best-effort-hierarchy"]
        # yosys-slang preserves the wrapped module under a mangled name:
        # `<mod>$<top>.<inst>`. Rename it back to `<mod>` and drop the
        # wrapper before writing JSON. Note: plain `$` (no backslash) —
        # yosys treats `\$` as an escape.
        mangled = f"{mod.name}$__wrap_{mod.name}.u"
        post_read_cmds = [
            f"rename {mangled} {mod.name}",
            f"delete __wrap_{mod.name}",
            f"hierarchy -top {mod.name}",
        ]
    else:
        slang_top = mod.name
        slang_extra_flags = []

    slang_cmd = ["read_slang", "--top", slang_top, *SLANG_FLAGS,
                 *slang_extra_flags]
    for d in SLANG_INC_DIRS:
        slang_cmd.extend(["-I", d])
    slang_cmd.extend(str(f) for f in files)
    if wrapper_path is not None:
        slang_cmd.append(str(wrapper_path))
    script = "; ".join([
        " ".join(slang_cmd),
        *post_read_cmds,
        "proc",
        "opt -fast",
        f"write_json {json_path}",
    ])

    try:
        r = subprocess.run(
            [YOSYS, "-q", "-m", "slang", "-p", script],
            capture_output=True, text=True, timeout=240,
        )
    except subprocess.TimeoutExpired:
        return False, "yosys-slang timeout"

    if json_path.exists() and json_path.stat().st_size > 100:
        return True, ""

    # Extract a useful error line from the slang output.
    log = (r.stderr or "") + "\n" + (r.stdout or "")
    err = "yosys-slang produced no JSON"
    for line in log.splitlines():
        s = line.strip()
        if not s:
            continue
        if "error:" in s or s.startswith("ERROR"):
            err = s[:300]
            break
    return False, err


def render_netlistsvg(mod_name: str) -> tuple[str, str]:
    """Run netlistsvg on the JSON for `mod_name` and return (svg, err)."""
    json_path = SVG_CACHE / f"{mod_name}.json"
    svg_path  = SVG_CACHE / f"{mod_name}.svg"
    if not json_path.exists():
        return "", "no JSON netlist"
    node_bin = shutil.which("node")
    if node_bin:
        cmd_ns = [node_bin, "--stack-size=16384", NETLISTSVG,
                  str(json_path), "-o", str(svg_path)]
    else:
        cmd_ns = [NETLISTSVG, str(json_path), "-o", str(svg_path)]
    try:
        r = subprocess.run(cmd_ns, capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return "", "netlistsvg timeout"
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip().splitlines()
        # Find the first non-empty, non-stack-trace line.
        first = next((l for l in msg if l.strip() and not l.startswith(" ")), "")
        return "", f"netlistsvg error: {first[:300]}"
    svg = svg_path.read_text()
    svg = re.sub(r"^\s*<\?xml[^>]*\?>\s*", "", svg)
    svg = svg.replace("<svg ", '<svg class="yosys-svg" ', 1)
    return svg, ""


# ──────────────────────────────────────────────────────────────────
# HTML emission
# ──────────────────────────────────────────────────────────────────
def emit_html(modules: list[Module], roots: list[Module],
              out_path: Path):
    """Build docs/design/index.html — single-file, self-contained."""
    by_name = {m.name: m for m in modules}
    data_json = _build_data_json(modules, roots, by_name)

    html_doc = _HTML_SHELL.replace("__DATA_PLACEHOLDER__", data_json)
    out_path.write_text(html_doc, encoding="utf-8")


# SVG payloads are wrapped in an HTTP-response-shaped envelope so the
# JS layer can pick the right decode path. `Content-Encoding: gzip`
# bodies are base64-encoded gzip bytes; `identity` bodies are the raw
# SVG text. The other headers (`Content-Type`, `Content-Length`) are
# documentation -- they describe the wire format the same way an HTTP
# response would.
_SVG_GZIP_THRESHOLD = 4 * 1024  # below this, store the SVG uncompressed


def _wrap_svg(svg: str) -> Optional[dict]:
    if not svg:
        return None
    raw_len = len(svg.encode("utf-8"))
    if raw_len < _SVG_GZIP_THRESHOLD:
        return {
            "Content-Type":     "image/svg+xml",
            "Content-Encoding": "identity",
            "Content-Length":   raw_len,
            "body":             svg,
        }
    # mtime=0 keeps the gzip header byte-identical across runs, so a
    # regenerated doc with unchanged RTL produces an unchanged file
    # (no spurious churn / empty publish commits).
    compressed = gzip.compress(svg.encode("utf-8"), compresslevel=9, mtime=0)
    return {
        "Content-Type":             "image/svg+xml",
        "Content-Encoding":         "gzip",
        "Content-Length":           len(compressed),
        "X-Content-Length-Uncompressed": raw_len,
        "body":                     base64.b64encode(compressed).decode("ascii"),
    }


def _build_data_json(modules, roots, by_name) -> str:
    payload = {
        "roots": [m.name for m in roots],
        "modules": {},
    }
    for m in modules:
        # Only emit source for "connectivity" modules (those that
        # instantiate children). Leaf RTL is treated as implementation
        # detail and intentionally omitted from the design doc — the
        # synthesized schematic still shows the leaf's structure.
        is_leaf = not m.instances
        if is_leaf:
            source = ""
        else:
            try:
                source = m.file.read_text(encoding="utf-8", errors="replace")
            except Exception:
                source = ""

        auto_svg  = m.auto_svg
        yosys_svg = m.yosys_svg
        if PUBLIC_MODE:
            # A leaf reveals nothing beyond its interface: drop its block
            # diagram and (already-empty) synthesized schematic.
            if is_leaf:
                auto_svg  = ""
                yosys_svg = ""
            # Source ships only for the publish allowlist (ktc_chip_top);
            # every other module -- including private connectivity tiles
            # like ktc_tile_top -- has its source stripped.
            if m.name not in PUBLIC_SOURCE_MODULES:
                source = ""

        payload["modules"][m.name] = {
            "name":         m.name,
            "title":        m.title,
            "description":  m.description,
            "file":         m.file_rel(),
            "line":         m.line,
            "bodyLines":    m.body_lines,
            "isStub":       m.is_stub,
            "isLeaf":       is_leaf,
            "parameters":   [dataclasses.asdict(p) for p in m.parameters],
            "ports":        [dataclasses.asdict(p) for p in m.ports],
            "instances":    [dataclasses.asdict(i) for i in m.instances],
            "parents":      sorted(m.parents),
            "autoSvg":      _wrap_svg(auto_svg),
            "yosysSvg":     _wrap_svg(yosys_svg),
            "yosysError":   m.yosys_error,
            "source":       source,
        }
    return json.dumps(payload, separators=(",", ":"))


_HTML_SHELL = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Karadelik — Design Browser</title>
<style>
:root {
  --bg: #14171c;
  --fg: #e4e4e7;
  --muted: #8a8f99;
  --border: #2a2f37;
  --accent: #7ab8ff;
  --accent2: #b58eff;
  --good: #6fcf97;
  --warn: #f5b067;
  --bad: #f06b6b;
  --panel: #1c2026;
  --panel2: #232830;
  --code-bg: #11141a;
  --tooltip-bg: #2a2f37;
  --shadow: 0 8px 28px rgba(0,0,0,.5);
}
@media (prefers-color-scheme: light) {
  :root {
    --bg: #fafafa;
    --fg: #1a1d23;
    --muted: #5b6470;
    --border: #d8dbe1;
    --accent: #1366c8;
    --accent2: #6e3fc0;
    --panel: #fff;
    --panel2: #f2f3f6;
    --code-bg: #f4f6f9;
    --tooltip-bg: #eef0f4;
    --shadow: 0 8px 28px rgba(0,0,0,.12);
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; height: 100%; font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--fg); font-size: 13.5px; }
#layout { display: grid; grid-template-columns: 280px 1fr; height: 100vh; }
#sidebar { background: var(--panel); border-right: 1px solid var(--border); overflow-y: auto; padding: 12px; }
#sidebar h1 { font-size: 14px; margin: 0 0 12px; letter-spacing: .04em; color: var(--accent); }
#sidebar input { width: 100%; padding: 6px 8px; background: var(--panel2); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; margin-bottom: 10px; }
#tree details { margin: 2px 0; }
#tree summary { cursor: pointer; padding: 3px 6px; border-radius: 3px; user-select: none; list-style: none; }
#tree summary::-webkit-details-marker { display: none; }
#tree summary::before { content: "▸ "; color: var(--muted); display: inline-block; transition: transform .15s; }
#tree details[open] > summary::before { content: "▾ "; }
#tree summary:hover { background: var(--panel2); }
#tree summary.active { background: var(--accent); color: #000; }
#tree details details { margin-left: 14px; border-left: 1px dotted var(--border); padding-left: 8px; }
#main { display: flex; flex-direction: column; overflow: hidden; }
#breadcrumb { padding: 10px 16px; border-bottom: 1px solid var(--border); display: flex; align-items: center; gap: 6px; font-size: 13px; }
#breadcrumb .crumb { color: var(--accent); cursor: pointer; text-decoration: none; }
#breadcrumb .crumb:hover { text-decoration: underline; }
#breadcrumb .sep { color: var(--muted); }
#breadcrumb .here { color: var(--fg); font-weight: 600; }
#tabs { display: flex; gap: 1px; background: var(--border); padding: 0 16px; }
#tabs button { background: var(--panel); color: var(--fg); border: 0; padding: 8px 14px; cursor: pointer; font-size: 13px; }
#tabs button.active { background: var(--bg); border-bottom: 2px solid var(--accent); }
#tabs button:disabled { color: var(--muted); cursor: not-allowed; }
#view { flex: 1; overflow: auto; padding: 16px; position: relative; background: var(--bg); }
.block-svg { max-width: 100%; height: auto; display: block; margin: 0 auto; }
.yosys-svg { max-width: 100%; height: auto; display: block; margin: 0 auto; background: white; border-radius: 6px; padding: 10px; }
.mod-outer { fill: var(--panel); stroke: var(--accent); stroke-width: 1.5; }
.mod-title { fill: var(--fg); font: 600 14px ui-monospace, monospace; }
.port-stub { stroke: var(--muted); stroke-width: 1.2; }
.port-label { fill: var(--fg); font: 11px ui-monospace, monospace; }
.port-type { fill: var(--muted); font: 10px ui-monospace, monospace; }
.leaf-label { fill: var(--muted); font: italic 11px ui-monospace, monospace; }
.inst { cursor: pointer; }
.inst rect { fill: var(--panel2); stroke: var(--accent2); stroke-width: 1.4; transition: fill .12s; }
.inst:hover rect, .inst:focus rect { fill: var(--accent2); }
.inst:hover .inst-name, .inst:focus .inst-name { fill: #000; }
.inst:hover .inst-mod, .inst:focus .inst-mod { fill: #000; }
.inst-extern rect { stroke: var(--muted); stroke-dasharray: 4 3; }
.inst-name { fill: var(--accent); font: 600 12px ui-monospace, monospace; }
.inst-mod { fill: var(--muted); font: 11px ui-monospace, monospace; }
.source { padding: 0; }
.source pre { background: var(--code-bg); color: var(--fg); padding: 14px 16px; margin: 0; overflow: auto; font: 12px/1.4 ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace; border-radius: 6px; max-height: calc(100vh - 130px); }
.source pre .kw { color: var(--accent2); font-weight: 600; }
.source pre .ty { color: var(--good); }
.source pre .cm { color: var(--muted); font-style: italic; }
.source pre .st { color: var(--warn); }
.source pre .nm { color: var(--accent); }
.unavailable { padding: 24px; color: var(--muted); background: var(--panel); border: 1px dashed var(--border); border-radius: 6px; max-width: 600px; margin: 24px auto; text-align: center; }
.unavailable code { background: var(--code-bg); padding: 2px 6px; border-radius: 3px; }
.headers { font: 11px ui-monospace, monospace; color: var(--muted); background: var(--code-bg); padding: 8px 12px; border-radius: 4px; margin: 0 0 10px; border: 1px solid var(--border); white-space: pre; }
.headers .hk { color: var(--accent2); }
.headers .hv { color: var(--fg); }

/* tooltip on hover via JS-attached element */
#tooltip {
  position: fixed; pointer-events: none; z-index: 50;
  background: var(--tooltip-bg); color: var(--fg);
  border: 1px solid var(--border); border-radius: 4px;
  padding: 6px 10px; font: 12px ui-sans-serif, system-ui;
  max-width: 320px; box-shadow: var(--shadow);
  opacity: 0; transition: opacity .12s;
}
#tooltip.visible { opacity: 1; }

/* right-click context popup */
#ctx-pop {
  position: fixed; z-index: 60; min-width: 240px; max-width: 340px;
  background: var(--panel); color: var(--fg);
  border: 1px solid var(--border); border-radius: 6px;
  box-shadow: var(--shadow); padding: 0; display: none;
}
#ctx-pop .ctx-title { font: 600 12.5px ui-monospace, monospace; padding: 10px 12px 4px; color: var(--accent); }
#ctx-pop .ctx-desc { padding: 0 12px 10px; font: 12px ui-sans-serif, system-ui; line-height: 1.4; color: var(--fg); border-bottom: 1px solid var(--border); }
#ctx-pop .ctx-action { display: block; width: 100%; text-align: left; background: transparent; color: var(--fg); border: 0; padding: 8px 12px; cursor: pointer; font: 12.5px ui-sans-serif, system-ui; }
#ctx-pop .ctx-action:hover { background: var(--panel2); }
#ctx-pop .ctx-action.primary { color: var(--accent); }

/* slide-in drawer (right) */
#drawer {
  position: fixed; top: 0; right: 0; height: 100vh;
  width: min(440px, 38%); background: var(--panel);
  border-left: 1px solid var(--border); box-shadow: var(--shadow);
  transform: translateX(100%); transition: transform .18s ease;
  overflow-y: auto; padding: 18px 20px; z-index: 40;
}
#drawer.open { transform: translateX(0); }
#drawer h2 { margin: 0 0 4px; font-size: 14.5px; color: var(--accent); }
#drawer .subtitle { color: var(--muted); font-size: 12px; margin-bottom: 10px; }
#drawer h3 { font-size: 12px; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); margin: 18px 0 6px; }
#drawer .desc { white-space: pre-wrap; font: 12px ui-monospace, monospace; color: var(--fg); line-height: 1.45; }
#drawer table { width: 100%; border-collapse: collapse; margin: 4px 0; }
#drawer td, #drawer th { padding: 4px 6px; border-bottom: 1px solid var(--border); text-align: left; font: 11.5px ui-monospace, monospace; vertical-align: top; }
#drawer th { color: var(--muted); font-weight: 600; }
#drawer .closebtn { position: absolute; top: 8px; right: 10px; background: transparent; color: var(--muted); border: 0; cursor: pointer; font-size: 18px; padding: 4px 8px; }
#drawer .closebtn:hover { color: var(--fg); }
.dir-input { color: var(--accent); }
.dir-output { color: var(--accent2); }
.dir-interface { color: var(--warn); }
#topbar { display: flex; align-items: center; padding: 0 16px; }
#topbar #info-btn { background: var(--panel); color: var(--fg); border: 1px solid var(--border); padding: 4px 10px; border-radius: 3px; cursor: pointer; font-size: 12px; margin-left: auto; }
#topbar #info-btn:hover { background: var(--panel2); }
</style>
</head>
<body>
<div id="layout">
  <aside id="sidebar">
    <h1>Karadelik design</h1>
    <input id="search" type="text" placeholder="Filter (/) …" autocomplete="off">
    <div id="tree"></div>
  </aside>
  <div id="main">
    <div id="topbar">
      <div id="breadcrumb"></div>
      <button id="info-btn" title="Open details drawer (i)">ⓘ details</button>
    </div>
    <div id="tabs">
      <button data-tab="block" class="active">Block diagram</button>
      <button data-tab="yosys">Synthesized (yosys)</button>
      <button data-tab="source">Source</button>
    </div>
    <div id="view"></div>
  </div>
</div>

<div id="tooltip"></div>
<div id="ctx-pop"></div>

<aside id="drawer">
  <button class="closebtn" aria-label="Close">×</button>
  <h2 id="dr-name"></h2>
  <div class="subtitle" id="dr-subtitle"></div>
  <h3>Short description</h3>
  <div class="desc" id="dr-title-desc"></div>
  <h3>Detail</h3>
  <div class="desc" id="dr-desc"></div>
  <h3>Parameters</h3>
  <table id="dr-params"><thead><tr><th>Name</th><th>Type</th><th>Default</th></tr></thead><tbody></tbody></table>
  <h3>Ports</h3>
  <table id="dr-ports"><thead><tr><th>Dir</th><th>Type</th><th>Name</th><th>Group</th></tr></thead><tbody></tbody></table>
  <h3>Instantiated by</h3>
  <div id="dr-parents" class="desc"></div>
  <h3>Source</h3>
  <div id="dr-source" class="desc"></div>
</aside>

<script id="data" type="application/json">__DATA_PLACEHOLDER__</script>
<script>
(function(){
  const data = JSON.parse(document.getElementById("data").textContent);
  const modules = data.modules;
  const roots = data.roots;
  const $tree = document.getElementById("tree");
  const $view = document.getElementById("view");
  const $crumb = document.getElementById("breadcrumb");
  const $tabs = document.getElementById("tabs");
  const $tooltip = document.getElementById("tooltip");
  const $ctx = document.getElementById("ctx-pop");
  const $drawer = document.getElementById("drawer");
  const $search = document.getElementById("search");
  let currentTab = "block";
  let breadcrumb = [];
  let currentModule = null;

  // ── Sidebar tree ─────────────────────────────────────────────
  function buildTreeNode(name, depth) {
    const m = modules[name];
    if (!m) return null;
    const wrap = document.createElement(m.instances && m.instances.length ? "details" : "div");
    if (depth < 1 && wrap.tagName === "DETAILS") wrap.open = true;
    const sum = document.createElement(wrap.tagName === "DETAILS" ? "summary" : "div");
    sum.textContent = name;
    sum.title = m.title || "";
    sum.dataset.module = name;
    sum.classList.add("tree-row");
    sum.style.cursor = "pointer";
    if (wrap.tagName !== "DETAILS") sum.style.padding = "3px 6px 3px 20px";
    sum.addEventListener("click", (e) => {
      e.stopPropagation();
      navigateTo(name, /*resetCrumb=*/true);
    });
    sum.addEventListener("contextmenu", (e) => {
      showCtx(e, name);
      e.preventDefault();
    });
    wrap.appendChild(sum);
    if (m.instances && m.instances.length && wrap.tagName === "DETAILS") {
      for (const inst of m.instances) {
        const childNode = buildTreeNode(inst.module_name, depth + 1);
        if (childNode) {
          // Replace its summary text with "inst : module" for clarity.
          const childSum = childNode.querySelector(".tree-row");
          if (childSum) childSum.textContent = inst.inst_name + " : " + inst.module_name;
          wrap.appendChild(childNode);
        } else {
          const li = document.createElement("div");
          li.className = "tree-row";
          li.style.cssText = "padding:3px 6px 3px 20px; color:var(--muted); cursor:default;";
          li.textContent = inst.inst_name + " : " + inst.module_name + "  (external)";
          wrap.appendChild(li);
        }
      }
    }
    return wrap;
  }

  function buildTree() {
    $tree.innerHTML = "";
    for (const r of roots) {
      const node = buildTreeNode(r, 0);
      if (node) $tree.appendChild(node);
    }
  }

  // ── Breadcrumb ───────────────────────────────────────────────
  function renderCrumb() {
    $crumb.innerHTML = "";
    breadcrumb.forEach((name, idx) => {
      if (idx > 0) {
        const sep = document.createElement("span");
        sep.className = "sep";
        sep.textContent = "/";
        $crumb.appendChild(sep);
      }
      if (idx === breadcrumb.length - 1) {
        const here = document.createElement("span");
        here.className = "here";
        here.textContent = name;
        $crumb.appendChild(here);
      } else {
        const a = document.createElement("a");
        a.href = "#";
        a.className = "crumb";
        a.textContent = name;
        a.onclick = (e) => { e.preventDefault(); breadcrumb = breadcrumb.slice(0, idx + 1); navigateTo(name, false); };
        $crumb.appendChild(a);
      }
    });
  }

  // ── Sidebar active highlight ─────────────────────────────────
  function highlightTree(name) {
    $tree.querySelectorAll(".tree-row").forEach(r => r.classList.toggle("active", r.dataset.module === name));
  }

  // ── SVG envelope decoder (HTTP-shaped) ───────────────────────
  // Each SVG payload is shipped as { Content-Type, Content-Encoding,
  // Content-Length, body }. `gzip` bodies are base64-encoded gzip
  // bytes; `identity` bodies are raw SVG text.
  const _svgCache = new Map();
  async function decodeSvgEnvelope(env) {
    if (!env) return "";
    if (_svgCache.has(env)) return _svgCache.get(env);
    let text;
    if (env["Content-Encoding"] === "gzip") {
      const bin = Uint8Array.from(atob(env.body), c => c.charCodeAt(0));
      const stream = new Blob([bin]).stream().pipeThrough(new DecompressionStream("gzip"));
      text = await new Response(stream).text();
    } else {
      text = env.body;
    }
    _svgCache.set(env, text);
    return text;
  }

  function renderHeaders(env) {
    if (!env) return "";
    const order = ["Content-Type", "Content-Encoding", "Content-Length", "X-Content-Length-Uncompressed"];
    const lines = [];
    for (const k of order) {
      if (env[k] === undefined) continue;
      lines.push(`<span class="hk">${k}</span>: <span class="hv">${escapeHtml(String(env[k]))}</span>`);
    }
    return `<div class="headers">${lines.join("\n")}</div>`;
  }

  // ── Main view rendering ──────────────────────────────────────
  let _renderToken = 0;
  async function renderView() {
    const m = modules[currentModule];
    if (!m) {
      $view.innerHTML = "<p>No module selected.</p>";
      return;
    }
    const token = ++_renderToken;
    if (currentTab === "block") {
      // Synchronous: every autoSvg envelope was predecoded at boot, so
      // the block diagram paints in this tick and attachBlockHandlers()
      // always runs (instance boxes stay clickable).
      const env = m.autoSvg;
      const svg = env ? (_svgCache.get(env) || "") : "";
      $view.innerHTML = renderHeaders(env) + (svg || "<p class='unavailable'>no diagram</p>");
      attachBlockHandlers();
    } else if (currentTab === "yosys") {
      if (m.yosysSvg) {
        const env = m.yosysSvg;
        $view.innerHTML = renderHeaders(env) + "<div class='unavailable'>decoding gzip…</div>";
        const svg = await decodeSvgEnvelope(env);
        if (token !== _renderToken) return;
        $view.innerHTML = renderHeaders(env) + svg;
      } else {
        const reason = m.yosysError || (m.instances && m.instances.length ? "wrapper module (yosys only renders leaves)" : "not generated");
        $view.innerHTML = `<div class="unavailable">No synthesized schematic for <code>${m.name}</code><br><br>Reason: ${escapeHtml(reason)}</div>`;
      }
    } else if (currentTab === "source") {
      if (m.source) {
        $view.innerHTML = `<div class="source"><pre>${highlightSV(m.source)}</pre></div>`;
      } else {
        const reason = m.isLeaf
          ? "leaf RTL is intentionally omitted from the design doc — see the Synthesized (yosys) tab for the module's structure"
          : "source not captured";
        $view.innerHTML = `<div class="unavailable">No source view for <code>${m.name}</code><br><br>${escapeHtml(reason)}</div>`;
      }
    }
  }

  function attachBlockHandlers() {
    const svg = $view.querySelector("svg.block-svg");
    if (!svg) return;
    svg.querySelectorAll(".inst").forEach(g => {
      const mod = g.dataset.module;
      g.addEventListener("click", () => navigateTo(mod, false));
      g.addEventListener("contextmenu", (e) => { showCtx(e, mod); e.preventDefault(); });
      g.addEventListener("mouseenter", (e) => showTooltip(e, mod));
      g.addEventListener("mousemove", positionTooltip);
      g.addEventListener("mouseleave", hideTooltip);
    });
  }

  function setTab(tab) {
    currentTab = tab;
    $tabs.querySelectorAll("button").forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
    renderView();
  }

  $tabs.addEventListener("click", (e) => {
    const b = e.target.closest("button[data-tab]");
    if (!b) return;
    if (b.disabled) return;
    setTab(b.dataset.tab);
  });

  // ── Navigation ───────────────────────────────────────────────
  function navigateTo(name, resetCrumb) {
    if (!modules[name]) return;
    if (resetCrumb || breadcrumb.length === 0) {
      breadcrumb = [name];
    } else if (breadcrumb[breadcrumb.length - 1] !== name) {
      breadcrumb.push(name);
    }
    currentModule = name;
    history.replaceState(null, "", "#" + name);
    renderCrumb();
    highlightTree(name);
    updateTabAvailability();
    renderView();
    hideCtx();
    hideTooltip();
  }

  function updateTabAvailability() {
    const m = modules[currentModule];
    if (!m) return;
    const yosysBtn = $tabs.querySelector("button[data-tab='yosys']");
    if (yosysBtn) yosysBtn.disabled = !m.yosysSvg;
    const srcBtn = $tabs.querySelector("button[data-tab='source']");
    if (srcBtn) srcBtn.disabled = !m.source;
    // If the active tab is now disabled, fall back to the block tab.
    const activeBtn = $tabs.querySelector("button.active");
    if (activeBtn && activeBtn.disabled) setTab("block");
  }

  // ── Hover tooltip ────────────────────────────────────────────
  function showTooltip(ev, modName) {
    const m = modules[modName];
    if (!m) return;
    $tooltip.textContent = m.title || modName;
    positionTooltip(ev);
    $tooltip.classList.add("visible");
  }
  function positionTooltip(ev) {
    const pad = 14;
    let x = ev.clientX + pad;
    let y = ev.clientY + pad;
    const rect = $tooltip.getBoundingClientRect();
    if (x + rect.width > window.innerWidth - 8) x = ev.clientX - rect.width - pad;
    if (y + rect.height > window.innerHeight - 8) y = ev.clientY - rect.height - pad;
    $tooltip.style.left = x + "px";
    $tooltip.style.top  = y + "px";
  }
  function hideTooltip() { $tooltip.classList.remove("visible"); }

  // ── Right-click context popup ────────────────────────────────
  function showCtx(ev, modName) {
    const m = modules[modName];
    if (!m) return;
    $ctx.innerHTML = "";
    const title = document.createElement("div");
    title.className = "ctx-title";
    title.textContent = m.name;
    $ctx.appendChild(title);
    const desc = document.createElement("div");
    desc.className = "ctx-desc";
    desc.textContent = m.title || "(no summary)";
    $ctx.appendChild(desc);
    const drillBtn = document.createElement("button");
    drillBtn.className = "ctx-action primary";
    drillBtn.textContent = "↳ Drill into " + m.name;
    drillBtn.onclick = () => { navigateTo(m.name, false); hideCtx(); };
    $ctx.appendChild(drillBtn);
    const detailBtn = document.createElement("button");
    detailBtn.className = "ctx-action";
    detailBtn.textContent = "ⓘ Open details panel";
    detailBtn.onclick = () => { openDrawer(m.name); hideCtx(); };
    $ctx.appendChild(detailBtn);

    $ctx.style.display = "block";
    const rect = $ctx.getBoundingClientRect();
    let x = ev.clientX, y = ev.clientY;
    if (x + rect.width > window.innerWidth - 8)  x = window.innerWidth - rect.width - 8;
    if (y + rect.height > window.innerHeight - 8) y = window.innerHeight - rect.height - 8;
    $ctx.style.left = x + "px";
    $ctx.style.top  = y + "px";
  }
  function hideCtx() { $ctx.style.display = "none"; }
  document.addEventListener("click", (ev) => { if (!$ctx.contains(ev.target)) hideCtx(); });
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") { hideCtx(); closeDrawer(); hideTooltip(); }
    if (ev.key === "i" && document.activeElement.tagName !== "INPUT") openDrawer(currentModule);
    if (ev.key === "/") { ev.preventDefault(); $search.focus(); }
  });

  // ── Drawer ───────────────────────────────────────────────────
  function openDrawer(name) {
    const m = modules[name];
    if (!m) return;
    document.getElementById("dr-name").textContent = m.name;
    document.getElementById("dr-subtitle").textContent = m.file + ":" + m.line + "  •  " + m.bodyLines + " lines";
    document.getElementById("dr-title-desc").textContent = m.title || "(no summary)";
    document.getElementById("dr-desc").textContent = m.description || "(no detail)";
    const paramsTb = document.querySelector("#dr-params tbody");
    paramsTb.innerHTML = "";
    if (m.parameters.length === 0) {
      paramsTb.innerHTML = "<tr><td colspan=3 style='color:var(--muted)'>(none)</td></tr>";
    } else {
      for (const p of m.parameters) {
        const tr = document.createElement("tr");
        tr.innerHTML = `<td>${escapeHtml(p.name)}</td><td>${escapeHtml(p.type)}</td><td>${escapeHtml(p.default)}</td>`;
        paramsTb.appendChild(tr);
      }
    }
    const portsTb = document.querySelector("#dr-ports tbody");
    portsTb.innerHTML = "";
    if (m.ports.length === 0) {
      portsTb.innerHTML = "<tr><td colspan=4 style='color:var(--muted)'>(none)</td></tr>";
    } else {
      for (const p of m.ports) {
        const tr = document.createElement("tr");
        tr.innerHTML = `<td class="dir-${p.direction}">${escapeHtml(p.direction)}</td>` +
                       `<td>${escapeHtml(p.type)}</td>` +
                       `<td>${escapeHtml(p.name)}</td>` +
                       `<td style="color:var(--muted)">${escapeHtml(p.group || "")}</td>`;
        portsTb.appendChild(tr);
      }
    }
    document.getElementById("dr-parents").textContent =
      m.parents.length ? m.parents.join(", ") : "(top-level / not instantiated)";
    document.getElementById("dr-source").textContent = m.file + ":" + m.line;
    $drawer.classList.add("open");
  }
  function closeDrawer() { $drawer.classList.remove("open"); }
  $drawer.querySelector(".closebtn").onclick = closeDrawer;
  document.getElementById("info-btn").onclick = () => openDrawer(currentModule);

  // ── Search filter ────────────────────────────────────────────
  $search.addEventListener("input", () => {
    const q = $search.value.trim().toLowerCase();
    $tree.querySelectorAll(".tree-row").forEach(r => {
      const matched = !q || r.dataset.module.toLowerCase().includes(q) || (modules[r.dataset.module]?.title || "").toLowerCase().includes(q);
      const wrap = r.closest("details, div");
      wrap.style.display = matched ? "" : "none";
    });
    // Re-open ancestor details when something matches inside.
    if (q) {
      $tree.querySelectorAll("details").forEach(d => {
        d.open = !!d.querySelector(".tree-row:not([style*='display: none'])");
      });
    }
  });

  // ── Syntax highlighter (very light) ──────────────────────────
  function highlightSV(src) {
    src = src.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    src = src.replace(/(\/\/[^\n]*)/g, '<span class="cm">$1</span>');
    src = src.replace(/(&quot;[^&]*&quot;|"[^"]*")/g, '<span class="st">$1</span>');
    const kw = ["module","endmodule","input","output","inout","logic","wire","reg","parameter","localparam","assign","always","always_ff","always_comb","always_latch","if","else","for","while","case","casex","casez","endcase","begin","end","function","endfunction","task","endtask","return","generate","endgenerate","import","package","endpackage","typedef","enum","struct","union","packed","unique","priority","interface","endinterface","modport","posedge","negedge","initial","final","void","int","integer","bit","byte","shortint","longint","real","string","class","endclass","extends","virtual","static","automatic","const","ref","var","new","this","super","null","do"];
    const kwRe = new RegExp("\\b(" + kw.join("|") + ")\\b", "g");
    src = src.replace(kwRe, '<span class="kw">$1</span>');
    src = src.replace(/(\b[A-Z_][A-Z0-9_]+\b)/g, '<span class="ty">$1</span>');
    return src;
  }

  function escapeHtml(s) {
    return (s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // ── Boot ─────────────────────────────────────────────────────
  // Predecode every block-diagram envelope into _svgCache up front, so
  // the block tab renders synchronously (see renderView) and the very
  // first paint cannot race on an async gzip decode.
  async function boot() {
    $view.innerHTML = "<p class='unavailable'>Loading design…</p>";
    for (const m of Object.values(modules)) {
      if (m.autoSvg) await decodeSvgEnvelope(m.autoSvg);
    }
    buildTree();
    const initial = location.hash.replace("#", "") || roots[0];
    navigateTo(initial, true);
  }
  boot();
})();
</script>
</body>
</html>
"""


# ──────────────────────────────────────────────────────────────────
# Main driver
# ──────────────────────────────────────────────────────────────────
def _parse_args(argv):
    """Minimal arg scan. Supports:
      --public        strip leaf internals; skip yosys synthesis
      --out <path>    output HTML path (default docs/design/index.html)
    """
    public = False
    out_path = DOCS_DIR / "index.html"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--public":
            public = True
        elif a == "--out":
            if i + 1 >= len(argv):
                print("error: --out needs a path argument", file=sys.stderr)
                sys.exit(2)
            out_path = Path(argv[i + 1]).resolve()
            i += 1
        else:
            print(f"error: unknown argument {a!r}", file=sys.stderr)
            print(__doc__, file=sys.stderr)
            sys.exit(2)
        i += 1
    return public, out_path


def main():
    global PUBLIC_MODE
    PUBLIC_MODE, out = _parse_args(sys.argv[1:])

    print(f"Karadelik design-doc generator{'  [PUBLIC mode]' if PUBLIC_MODE else ''}")
    print(f"  RTL root:  {RTL_ROOT}")
    print(f"  Output:    {out}")
    if not PUBLIC_MODE:
        print(f"  yosys:      {YOSYS or '(missing)'} (slang plugin via -m slang)")
        print(f"  netlistsvg: {NETLISTSVG or '(missing)'}")

    out.parent.mkdir(parents=True, exist_ok=True)

    print("\n[1/4] Parsing SystemVerilog ...")
    modules = parse_all()
    print(f"      parsed {len(modules)} modules")

    by_name = resolve_hierarchy(modules)
    roots = find_roots(modules)
    print(f"      roots: {[r.name for r in roots]}")

    print("\n[2/4] Generating block diagrams ...")
    for m in modules:
        m.auto_svg = auto_block_svg(m, by_name)
    print(f"      generated {len(modules)} block diagrams")

    if PUBLIC_MODE:
        print("\n[3/4] Skipping yosys-slang schematics (public mode) ...")
        print("      leaf internals (source, block diagram, netlist) omitted")
    else:
        print("\n[3/4] Generating yosys-slang schematics for leaves ...")
        SVG_CACHE.mkdir(parents=True, exist_ok=True)
        leaves = [m for m in modules if not m.is_stub and not m.instances]
        skipped = len(modules) - len(leaves)

        # Per-leaf yosys-slang + netlistsvg, all in parallel. Each leaf
        # invocation is independent (~80 ms read_slang + ~50 ms netlistsvg).
        from concurrent.futures import ThreadPoolExecutor
        import os as _os
        n_jobs = max(2, min(8, (_os.cpu_count() or 4) - 1))
        print(f"      running yosys-slang + netlistsvg on {len(leaves)} "
              f"leaves with {n_jobs} workers ...")

        def _render(m):
            synth_ok, synth_err = yosys_slang_synthesize(m)
            if not synth_ok:
                return m.name, "", synth_err
            json_path = SVG_CACHE / f"{m.name}.json"
            if json_path.stat().st_size > _NETLIST_JSON_MAX_BYTES:
                sz_mb = json_path.stat().st_size / 1024 / 1024
                return m.name, "", f"netlist too large for netlistsvg ({sz_mb:.1f} MB JSON)"
            svg, err = render_netlistsvg(m.name)
            return m.name, svg, err

        results = {}
        with ThreadPoolExecutor(max_workers=n_jobs) as ex:
            for name, svg, err in ex.map(_render, leaves):
                results[name] = (svg, err)

        ok = 0
        failed = 0
        for m in leaves:
            svg, err = results[m.name]
            if svg:
                m.yosys_svg = svg
                ok += 1
            else:
                m.yosys_error = err
                failed += 1
                print(f"      [skip] {m.name}: {err[:120]}", file=sys.stderr)
        print(f"      ok={ok} failed={failed} skipped={skipped}")

    print("\n[4/4] Emitting HTML ...")
    emit_html(modules, roots, out)
    size_kb = out.stat().st_size / 1024
    print(f"      wrote {out} ({size_kb:.0f} KB)")
    print("\nDone. Open the file in your browser to view.")


if __name__ == "__main__":
    sys.exit(main() or 0)
