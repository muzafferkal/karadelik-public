#!/usr/bin/env bash
# Copyright (c) 2026 Muzaffer Kal <muzaffer@kal.cc>
# All rights reserved.
# Discover and run every cocotb test under src/tb/cocotb/.
#
# Each test file is invoked as a standalone python program (it calls
# cocotb_tools.runner.get_runner() in its own _runner_main() block).
# Exits non-zero if any test file fails or times out.
#
# Tunables via environment variables:
#   KTC_TEST_TIMEOUT_S  per-file timeout in seconds (default: 600)
#   KTC_TEST_FILTER     glob applied to test paths (default: "*")

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMEOUT_S="${KTC_TEST_TIMEOUT_S:-600}"
FILTER="${KTC_TEST_FILTER:-*}"

mapfile -t TESTS < <(find "$REPO_ROOT/src/tb/cocotb" -name 'test_*.py' -type f 2>/dev/null \
                     | grep -E "$(echo "$FILTER" | sed 's/\*/.\*/g')" \
                     | sort)

# Skip TRISC firmware-dependent tests when riscv64-unknown-elf-gcc isn't
# on PATH (e.g. CI without the toolchain). The tests would otherwise
# crash on the make step. Set KTC_INCLUDE_TRISC_TESTS=1 to force-include.
if [[ "${KTC_INCLUDE_TRISC_TESTS:-0}" != "1" ]] \
   && ! command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
  echo "[run_tests] riscv64-unknown-elf-gcc not found; skipping TRISC tests."
  echo "[run_tests] (set KTC_INCLUDE_TRISC_TESTS=1 to override.)"
  TESTS=("${TESTS[@]/$REPO_ROOT\/src\/tb\/cocotb\/tile\/test_trisc_engine_smoke.py/}")
  # Drop any empty entries the filter above produced.
  FILTERED=()
  for t in "${TESTS[@]}"; do
    [[ -n "$t" ]] && FILTERED+=("$t")
  done
  TESTS=("${FILTERED[@]}")
fi

if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "no tests found under src/tb/cocotb/"
  exit 0
fi

PASS=0
FAIL=0
FAILED_FILES=()
LOG_DIR=$(mktemp -d)

for t in "${TESTS[@]}"; do
  rel="${t#$REPO_ROOT/}"
  printf '─── %s\n' "$rel"
  log="$LOG_DIR/$(echo "$rel" | tr '/' '_').log"
  if timeout "$TIMEOUT_S" python3 "$t" > "$log" 2>&1; then
    # Read PASS/FAIL counts from the cocotb summary line.
    summary=$(grep -E "TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+" "$log" | tail -1 \
              | sed -E 's/.*(TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+).*/\1/')
    if [[ -n "$summary" ]]; then
      printf '    %s\n' "$summary"
      sub_fail=$(echo "$summary" | sed -E 's/.*FAIL=([0-9]+).*/\1/')
      if [[ "$sub_fail" -gt 0 ]]; then
        FAIL=$((FAIL+1))
        FAILED_FILES+=("$rel — $summary")
      else
        PASS=$((PASS+1))
      fi
    else
      printf '    PASS (no cocotb summary line)\n'
      PASS=$((PASS+1))
    fi
  else
    rc=$?
    FAIL=$((FAIL+1))
    if [[ $rc -eq 124 ]]; then
      FAILED_FILES+=("$rel — TIMEOUT after ${TIMEOUT_S}s")
      printf '    TIMEOUT\n'
    else
      FAILED_FILES+=("$rel — exit $rc")
      printf '    FAIL (exit %d) — last 30 log lines:\n' "$rc"
      tail -n 30 "$log" | sed 's/^/      /'
    fi
  fi
done

echo
echo "─────────────────────────────────────────────"
printf 'files: PASS=%d FAIL=%d (logs in %s)\n' "$PASS" "$FAIL" "$LOG_DIR"
if [[ $FAIL -gt 0 ]]; then
  echo "failing files:"
  printf '  %s\n' "${FAILED_FILES[@]}"
  exit 1
fi
exit 0
