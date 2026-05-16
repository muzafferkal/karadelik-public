#!/usr/bin/env bash
# Copyright (c) 2026 Muzaffer Kal <muzaffer@kal.cc>
# All rights reserved.
# Remove generated simulation / lint artifacts.
#
# Targets:
#   sim_build/   - cocotb runner workdir (Verilator-built simulator + objects)
#   obj_dir/     - verilator --lint-only scratch (tree dumps, stats)
#
# Both directories are regenerated on the next test run / lint invocation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleaned=0
for dir in sim_build obj_dir; do
  target="$REPO_ROOT/$dir"
  if [[ -d "$target" ]]; then
    rm -rf "$target"
    echo "removed $target"
    cleaned=$((cleaned + 1))
  fi
done

if (( cleaned == 0 )); then
  echo "nothing to clean"
fi
