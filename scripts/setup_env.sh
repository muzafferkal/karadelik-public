#!/bin/bash
# Copyright (c) 2026 Muzaffer Kal <muzaffer@kal.cc>
# All rights reserved.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# --- Tenstorrent reference repos ---
TT_DIR="$BASE_DIR/tenstorrent"
mkdir -p "$TT_DIR"

# Curated reference set for the BabyRISC-V -> FPU/SFPU dispatch path:
#   tt-isa-documentation  authoritative opcode-field reference (BlackholeA0/TensixTile)
#   tt-llk                unified active LLK (WH-B0 / BH / Quasar) - opcode headers,
#                         macros, and tests
#   tt-metal              canonical BRISC/TRISC example kernels and boot stubs
#                         under tt_metal/hw/ (unshallowed below for LLK history)
repos_tt=(
    "tt-metal"
    "tt-isa-documentation"
    "tt-llk"
)

for repo in "${repos_tt[@]}"; do
    if [ ! -d "$TT_DIR/$repo" ]; then
        echo "Cloning tenstorrent/$repo..."
        git clone --depth 1 "https://github.com/tenstorrent/$repo.git" "$TT_DIR/$repo"
    fi
done

# tt-metal needs more history for LLK reference
if [ -d "$TT_DIR/tt-metal" ]; then
    (cd "$TT_DIR/tt-metal" && git fetch --unshallow 2>/dev/null || true)
fi

# Optional: tenstorrent/sfpi (recursive) - GCC 10.2 fork with SFPU __builtin_*
# intrinsics. Only needed if/when we move from .insn-encoded SFPU ops to a
# C++ lane DSL. Uncomment to enable.
# if [ ! -d "$TT_DIR/sfpi" ]; then
#     echo "Cloning tenstorrent/sfpi (with submodules)..."
#     git clone --recursive "https://github.com/tenstorrent/sfpi.git" "$TT_DIR/sfpi"
# fi

# --- OpenHW Group repos ---
OHW_DIR="$BASE_DIR/openhw"
mkdir -p "$OHW_DIR"

repos_ohw=(
    "cv32e40x"
    "cve2"
    "core-v-xif"
    "core-v-verif"
    "cva6"
)

for repo in "${repos_ohw[@]}"; do
    if [ ! -d "$OHW_DIR/$repo" ]; then
        echo "Cloning openhwgroup/$repo..."
        git clone "https://github.com/openhwgroup/$repo.git" "$OHW_DIR/$repo"
    fi
done

echo "All repos cloned. Recording versions..."
# Record commit SHAs for reproducibility
VERSIONS="$(dirname "$0")/versions.txt"
echo "# Upstream commit SHAs - $(date -I)" > "$VERSIONS"
for repo in "${repos_tt[@]}"; do
    sha=$(git -C "$TT_DIR/$repo" rev-parse HEAD 2>/dev/null || echo "N/A")
    echo "tenstorrent/$repo $sha" >> "$VERSIONS"
done
for repo in "${repos_ohw[@]}"; do
    sha=$(git -C "$OHW_DIR/$repo" rev-parse HEAD 2>/dev/null || echo "N/A")
    echo "openhwgroup/$repo $sha" >> "$VERSIONS"
done
echo "Versions recorded in $VERSIONS"
