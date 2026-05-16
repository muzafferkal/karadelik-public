# Karadelik — KTC (Kal's Tensor Core)

A clean-room SystemVerilog implementation of a tensor-compute tile,
loosely inspired by the open architecture of a commercial AI
accelerator. The tile pairs open-source RISC-V cores with custom
matrix and vector engines, using a standard coprocessor interface
rather than the proprietary MMIO-dispatch mechanism the reference
architecture relies on.

## What's inside the tile

- **5 RISC-V cores**
  - 2× small data-movement cores (BRISC, NCRISC) — drive NOC DMA
  - 3× compute-dispatch cores (TRISC0/1/2) — issue custom instructions
    to the engines via the CV-X-IF coprocessor interface
- **FPU** — 8×8 matrix engine with FP32 accumulation; supports BF16,
  FP16, FP32, TF32, FP8, INT8, BFP{2,4,8} formats
- **SFPU** — 32-lane SIMD vector engine for element-wise math (ADD,
  MUL, MAD, TANH, GELU, EXP, RECIP, …)
- **Unpacker / Packer** — format-converting DMA between L1 SRAM and
  the SrcA/SrcB/Dst register files
- **ThCon** — scalar configuration unit
- **L1 SRAM** + 2× NOC router

The instruction-dispatch story: the TRISC core issues a custom
RISC-V instruction (CUSTOM_0 / `.insn r`) whose `rs1` carries a 32-bit
packed KTC opcode word. A CV-X-IF adapter (`cvxif_to_ktc`) routes that
word onto the instruction pipe, which decodes and fans it out to the
appropriate engine.

## Repository layout

```
karadelik/
├── CLAUDE.md          Project conventions, lint commands, live test snapshot
├── README.md          This file
├── docs/              Architecture specs and porting guides
├── scripts/
│   ├── setup_env.sh   Clone upstream reference repos under ~/projects/
│   ├── run_tests.sh   Discover & run every cocotb test
│   └── versions.txt   Pinned upstream commit SHAs (generated)
└── src/
    ├── rtl/                  All hardware blocks
    │   ├── pkg/              Shared params, opcodes, types, interfaces
    │   ├── cvxif_adapter/    CV-X-IF ↔ KTC instruction-pipe bridge
    │   ├── matrix_engine/    FPU (8×8 array, DSP58 mapping, control FSM)
    │   ├── vector_engine/    SFPU (32 lanes, regfile, predicate, control)
    │   ├── unpacker/         L1 → SrcA/B with format conversion + tilize
    │   ├── packer/           Dst → L1 with format conversion + ReLU
    │   ├── thcon/            Scalar config / REG2FLOP unit
    │   ├── instruction_pipe/ Decoder, dispatcher, MOP/replay expanders
    │   ├── regfiles/         SrcA, SrcB, Dst accumulator + arbiter
    │   ├── memory/           L1 SRAM, arbiter, DMA, write-cache, core adapter
    │   ├── noc/              Router, DMA, packet interface
    │   ├── cores/            Per-core wrappers around upstream RISC-V IP
    │   ├── control/          Reset unit, debug unit, tile local bus
    │   ├── sim/              Simulation-only stubs
    │   ├── karadelik.f       Lint filelist (uses upstream-core stubs)
    │   ├── karadelik_sim.f   Functional-sim filelist (real cv32e40x RTL)
    │   └── ktc_tile_top.sv   Top-level integration
    ├── fw/                   Bare-metal firmware for the RISC-V cores
    │   ├── runtime/          crt0.S, HAL header
    │   ├── linker/           Per-core linker scripts
    │   ├── boot/             Boot kernels for BRISC, NCRISC, TRISC
    │   └── tests/            Smoke kernels + Makefile (exercise engines)
    ├── llk/                  Low-level kernel macros
    │   └── encoding/         KTC opcode → RISC-V custom-instruction mapping
    ├── tb/cocotb/            Verification — see src/tb/cocotb/README.md
    ├── toolchain/            GCC / binutils patches (scaffolded)
    └── fpga/                 FPGA prototyping files
```

## Building and running tests

Lint the integrated RTL (no simulator state required):

```sh
verilator --lint-only --top-module ktc_tile_top \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-CASEOVERLAP \
  -f src/rtl/karadelik.f
```

Run the cocotb verification suite:

```sh
bash scripts/run_tests.sh
```

See **[`src/tb/cocotb/README.md`](src/tb/cocotb/README.md)** for the
full test inventory, per-suite status, prerequisites (cocotb,
verilator, optional `riscv64-unknown-elf-gcc` toolchain), and how to
add new tests.

## Building firmware

To compile a TRISC smoke kernel that exercises the FPU and SFPU via
the CV-X-IF dispatch path:

```sh
make -C src/fw/tests
```

This produces `.elf`, `.hex` (Verilog `$readmemh` format), and `.lst`
artifacts. The Debian/Ubuntu prerequisite is:

```sh
sudo apt install --no-install-recommends \
    gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
    picolibc-riscv64-unknown-elf
```

Ubuntu 24.04+ / Debian trixie+ is needed for the `rv32imc/ilp32`
multilib.

## Upstream dependencies

`scripts/setup_env.sh` clones reference and IP repos under
`~/projects/` (outside this tree). The pinned commit SHAs land in
`scripts/versions.txt`. The RISC-V cores (CV32E40X, CVE2) come from
the OpenHW Group; their RTL is pulled in via `src/rtl/karadelik_sim.f`
when a functional simulation is built.

## Conventions

See [`CLAUDE.md`](CLAUDE.md) for the live state of:
- Coding conventions (SystemVerilog, cocotb Python, C/C++ firmware)
- Lint command and suppression rationale
- Current test pass/fail snapshot
- Open RTL bugs surfaced by verification, with file:line references
