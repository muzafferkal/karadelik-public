#!/usr/bin/env bash
# Copyright (c) 2026 Muzaffer Kal <muzaffer@kal.cc>
# All rights reserved.
#
# publish_public.sh -- export a restricted, public-safe snapshot of the
# karadelik repo to a separate public remote.
#
# This is a DEFAULT-DENY publisher: it copies only the paths listed in
# scripts/public_manifest.txt into a clean public worktree, regenerates
# the design doc with leaf internals stripped, runs a hard audit gate,
# and only then commits + pushes. The private repo's git state and
# history are never touched or exposed.
#
# Usage:
#   PUBLIC_REMOTE=<url-or-path> [PUBLIC_WORKTREE=<dir>] bash scripts/publish_public.sh
#
#   PUBLIC_REMOTE    (required) git URL / path of the public repo.
#   PUBLIC_WORKTREE  (optional) local checkout dir; default ../karadelik-public.
#
# The audit gate aborts -- before any commit or push -- if any .sv file
# other than the five allowlisted ones reaches the public worktree, or if
# any locally-generated artifact (svg_cache, *.abs.f, _wrap_*, sim_build)
# is present.

set -euo pipefail

# ── Locations ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$SCRIPT_DIR/public_manifest.txt"
WORKTREE="${PUBLIC_WORKTREE:-$(dirname "$REPO_ROOT")/karadelik-public}"

# The complete set of .sv files allowed in the public repo. Any deviation
# is a hard failure.
EXPECTED_SV=$(printf '%s\n' \
  "src/rtl/ktc_chip_top.sv" \
  "src/rtl/pkg/ktc_interfaces.sv" \
  "src/rtl/pkg/ktc_opcodes.sv" \
  "src/rtl/pkg/ktc_params.sv" \
  "src/rtl/pkg/ktc_types.sv" | sort)

die() { echo "publish_public: ERROR: $*" >&2; exit 1; }

# ── Preconditions ────────────────────────────────────────────────────
[ -n "${PUBLIC_REMOTE:-}" ] || die "PUBLIC_REMOTE is not set"
[ -f "$MANIFEST" ]          || die "manifest not found: $MANIFEST"
command -v python3 >/dev/null || die "python3 not on PATH"

echo "publish_public: private repo : $REPO_ROOT"
echo "publish_public: public remote: $PUBLIC_REMOTE"
echo "publish_public: worktree     : $WORKTREE"

# ── 1. Clone or refresh the public worktree ──────────────────────────
if [ ! -d "$WORKTREE/.git" ]; then
  echo "publish_public: cloning public remote ..."
  git clone "$PUBLIC_REMOTE" "$WORKTREE"
else
  echo "publish_public: refreshing existing worktree ..."
  # Tolerate an empty remote (unborn branch) -- nothing to fast-forward.
  git -C "$WORKTREE" pull --ff-only 2>/dev/null || true
fi

# ── 2. Wipe tracked content (keep .git) ──────────────────────────────
find "$WORKTREE" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +

# ── 3. Copy allowlisted paths ────────────────────────────────────────
copied=0
while IFS= read -r raw; do
  line="${raw%%#*}"                       # strip comments
  line="$(echo "$line" | xargs || true)"  # trim whitespace
  [ -z "$line" ] && continue
  src="$REPO_ROOT/$line"
  if [ ! -e "$src" ]; then
    die "manifest path does not exist: $line"
  fi
  # tar preserves the relative tree and drops generated junk.
  tar -C "$REPO_ROOT" -cf - \
      --exclude='__pycache__' --exclude='*.pyc' --exclude='*.abs.f' \
      --exclude='*.swp' --exclude='.DS_Store' \
      "$line" | tar -C "$WORKTREE" -xf -
  copied=$((copied + 1))
done < "$MANIFEST"
echo "publish_public: copied $copied manifest entries"

# ── 4. Regenerate the design doc in public mode ──────────────────────
echo "publish_public: regenerating design doc (--public) ..."
python3 "$REPO_ROOT/scripts/gen_design_doc.py" \
  --public --out "$WORKTREE/docs/design/index.html"

# ── 5. Audit gate (hard fail before any commit/push) ─────────────────
echo "publish_public: auditing public worktree ..."

found_sv=$(cd "$WORKTREE" && find . -name '*.sv' | sed 's|^\./||' | sort)
if [ "$found_sv" != "$EXPECTED_SV" ]; then
  echo "---- expected .sv ----" >&2; echo "$EXPECTED_SV" >&2
  echo "---- found .sv -------" >&2; echo "${found_sv:-<none>}" >&2
  die "unexpected SystemVerilog files in public worktree"
fi

for bad in src/tb src/fw src/llk src/toolchain prompts.md; do
  [ -e "$WORKTREE/$bad" ] && die "private path leaked into public worktree: $bad"
done

leaked=$(find "$WORKTREE" \( -name '*.abs.f' -o -name '_wrap_*' \
           -o -path '*svg_cache*' -o -path '*sim_build*' \) -print)
[ -n "$leaked" ] && { echo "$leaked" >&2; die "generated artifact leaked"; }

echo "publish_public: audit passed -- 5 allowlisted .sv, no private paths"

# ── 6. Commit + push (synthetic history) ─────────────────────────────
priv_sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
git -C "$WORKTREE" add -A
if git -C "$WORKTREE" diff --cached --quiet; then
  echo "publish_public: no changes since last publish -- nothing to do"
  exit 0
fi
git -C "$WORKTREE" commit -m "public snapshot $(date -u +%Y-%m-%d) (private $priv_sha)"
git -C "$WORKTREE" push origin HEAD
echo "publish_public: published (private $priv_sha)"
