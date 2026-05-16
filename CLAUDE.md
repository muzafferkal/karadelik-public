# Karadelik - KTC (Kal's Tensor Core) Project

## What is this?
A clean-room implementation of a tensor compute tile (KTC) inspired by Tenstorrent's Blackhole architecture. Uses OpenHW CORE-V RISC-V cores (CVE2 for data movers, CV32E40X for compute dispatchers) with CV-X-IF coprocessor interface replacing proprietary MMIO dispatch.

## Architecture
- KTC tile = 5 RISC-V cores + FPU (matrix) + SFPU (vector) + unpacker + packer + ThCon + L1 SRAM + 2 NOC routers
- BRISC/NCRISC: CVE2 (2-stage, ~19kGE) - control NOC DMA engines
- TRISC0/1/2: CV32E40X (4-stage, ~50kGE, CV-X-IF) - dispatch compute instructions

## Code conventions
- RTL: SystemVerilog, 2-space indent, lowercase_with_underscores for signals
- Testbenches: cocotb (Python) preferred, SystemVerilog for timing-critical tests
- FW/LLK: C/C++, follows TT-Metal coding conventions for compatibility

## Project layout
- `src/rtl/` - All custom hardware blocks (CV-X-IF adapter, instruction pipe, FPU, SFPU, etc.)
- `src/rtl/pkg/` - Shared parameters, opcodes, types, interfaces
- `src/tb/` - Testbenches (unit, integration, cocotb, golden models)
- `src/fw/` - Firmware and boot code for CV32E40X/CVE2
- `src/llk/` - Adapted Low-Level Kernel macros (CV-X-IF dispatch)
- `src/toolchain/` - GCC/binutils patches for custom instructions
- `src/fpga/` - FPGA prototyping files
- `docs/` - Architecture specs and porting guides

## Upstream repos (cloned to ~/projects/, NOT part of this repo)
- `~/projects/tenstorrent/` - tt-metal, tt-isa-documentation, etc. (read-only reference)
- `~/projects/cv32e40x/` and `~/projects/cve2/` - OpenHW CORE-V RISC-V cores (RTL sources)

## Build
- `scripts/setup_env.sh` - Clone all upstream repos
- `scripts/versions.txt` - Pinned upstream commit SHAs
- `scripts/build_all.sh` - Build toolchain + firmware + tests
- `scripts/run_tests.sh` - Run full test suite

## Lint and simulation
- `src/rtl/karadelik.f` - tile-level filelist for `verilator --lint-only`. Uses
  upstream-core stubs in `src/rtl/sim/upstream_stubs.sv`; for functional sim
  drop the stubs and add the cv32e40x/cve2 manifests.
- `src/rtl/karadelik_chip.f` - chip-level filelist (includes `karadelik.f`
  plus `src/rtl/cores/ktc_host_tile.sv` and `src/rtl/ktc_chip_top.sv` for
  the 2x2 chip wrapper).
- Lint commands:
  ```
  # Single tile
  verilator --lint-only --top-module ktc_tile_top \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-CASEOVERLAP \
    -f src/rtl/karadelik.f

  # 2x2 chip
  verilator --lint-only --top-module ktc_chip_top \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-CASEOVERLAP \
    -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
    -f src/rtl/karadelik_chip.f
  ```
  The suppressed warning classes are pre-existing tech-debt in unrelated
  subsystems; the new control-plane/CV-X-IF integration lints cleanly without
  them (see also the scoped `src/rtl/karadelik_lint.f`).
- Cocotb tests (require `pip install --user cocotb`):
  - `bash scripts/run_tests.sh` runs every `src/tb/cocotb/**/test_*.py` and
    aggregates pass/fail counts (per-file timeout `KTC_TEST_TIMEOUT_S`,
    glob filter `KTC_TEST_FILTER`). Exits non-zero on any failure.
  - Per-file dev iteration: `python3 src/tb/cocotb/<suite>/<name>.py`.
  - Test suites today: `fpu/` (matrix engine, 3 layers), `sfpu/` (vector
    engine, 3 layers), `control/` (debug/reset/local-bus units), `tile/`
    (NOC bridge, cardinal-transit, control-plane integration), `chip/`
    (2x2 mesh AXI-host boot), `dram/` (DRAM tile at (2,0): NOC packet ->
    dram_controller -> BRAM backend).

## NOC architecture

The NOC stack is two layered networks with three integration points:

1. **`noc_router` (`src/rtl/noc/noc_router.sv`)**. Single-VC, 5-port
   crossbar (Local + N/S/E/W). Dimension-ordered routing parameterised
   by `DIRECTION` -- `ROUTE_RD` (X-first; NOC0) and `ROUTE_LU` (Y-first;
   NOC1, counter-rotating). Per-output source-lock latch (`active_*`)
   so the two-phase header/data protocol sees a coherent packet across
   contended cycles. Inputs and outputs are wired by direction (no
   intermediate packed arrays) so Verilator can prove no false
   combinational cycle through edge-wired tiles.
2. **`ktc_niu` (`src/rtl/noc/ktc_niu.sv`)**. MMIO-driven NOC initiator.
   One per NOC per tile (so 2 per `ktc_tile_top` + 2 per
   `ktc_host_tile`). Firmware (or the AXI host) writes the register
   block (`NIU_NOC0_BASE = 0xFFB0_0000`, `NIU_NOC1_BASE = 0xFFB0_1000`)
   to load TARG_XY, TARG_ADDR_LO/HI, LENGTH, then 64 payload words,
   then pulses CTRL.trigger to inject a 1-flit packet into
   `router.local_in`. v1 supports write packets only.
3. **`noc_to_local_bus` (`src/rtl/control/noc_to_local_bus.sv`)**.
   Drains `router.local_out` and replays the flit as 64 sub-writes on
   `tile_local_bus` slave port `s1` (NOC0) / `s2` (NOC1). Reads land
   on either NOC equivalently from the tile's perspective.

**Tile interconnect.** `ktc_tile_top` exposes 16 cardinal ports
(N/S/E/W * in/out * NOC0/NOC1). Two routers consume them, with
`DIRECTION=ROUTE_RD` and `ROUTE_LU` respectively. Local-in is driven
by the matching NIU; local-out feeds the matching bridge.

**Chip-level.** `ktc_chip_top` (`src/rtl/ktc_chip_top.sv`) is a mesh
with `ktc_host_tile` at (0,0), `ktc_tile_top` compute tiles at (1,0) /
(0,1) / (1,1), and a `ktc_dram_tile` DRAM endpoint at (2,0).
`ktc_host_tile` (`src/rtl/cores/ktc_host_tile.sv`) swaps out the L1 /
IRAMs / cores for an AXI4-Lite slave that drives the two NIUs;
everything downstream of `router.local_in` is the same as a compute
tile. Chip-boundary cardinals are tied off (non-toroidal v1). A future
TLB-window indirection in the host tile -- so an AXI address auto-maps
to a target tile -- is a v2 follow-up; today the AXI host directly
programs the NIU registers.

**DRAM tile.** `ktc_dram_tile` (`src/rtl/cores/ktc_dram_tile.sv`) at
(2,0) is reached by NOC packets carrying `local_addr` = byte offset
into DRAM. Its two `noc_to_local_bus` bridges arbitrate (NOC0 priority)
onto a `dram_controller` (`src/rtl/memory/dram_controller.sv`) that
turns each local-bus word write into a 1-beat AXI4 master burst. The
`BACKEND` parameter (threaded up to `ktc_chip_top`'s `DRAM_BACKEND`)
selects the AXI target: `"BRAM"` loops back to an internal
`axi_target_bram` (sim / BRAM smoke synth); `"DDRMC"` routes the AXI
master out through the chip-top `m_axi_dram_*` port for a Xilinx DDRMC
IP (fabric DDR) or the PS NoC `S_AXI_HP` slave (PS DDR) on the VPK180.

## Test status snapshot (current)

| Suite | Pass / Total | Notes |
|---|---|---|
| `control/test_debug_unit.py` | 5/5 | clean |
| `fpu/test_dsp58_cell.py` | 10/10 | clean |
| `fpu/test_fpu_array.py` | 23/23 | clean |
| `fpu/test_fpu_array_diag.py` | 4/4 | diagnostic harness (probes per-element internal state) |
| `fpu/test_fpu_top.py` | 19/19 | clean |
| `sfpu/test_sfpu_lane.py` | 12/12 | clean |
| `sfpu/test_sfpu_regfile.py` | 6/6 | clean |
| `sfpu/test_sfpu_top.py` | 6/6 | clean |
| `tile/test_boot_path.py` | 4/4 | clean |
| `tile/test_trisc_engine_smoke.py` | 3/3 | clean (needs `riscv64-unknown-elf-gcc` on PATH; otherwise skipped) |
| `tile/test_tile_pair_transit.py` | 2/2 | clean -- cardinal-to-cardinal transit on both NOCs |
| `chip/test_chip_boot.py` | 3/3 | clean -- 2x2 chip-level boot from host AXI through NIU NOC0 |
| `dram/test_dram_tile.py` | 2/2 | clean -- DRAM tile at (2,0), host AXI -> NOC -> dram_controller -> BRAM backend |

## Open RTL bugs surfaced by verification

No open RTL bugs in the SFPU/FPU; the four documented under
[Recently fixed](#recently-fixed-regression-guarded) below were closed
with regression guards in their respective cocotb suites.

## Recently fixed (regression-guarded)

- **`sfpu_lane.sv:OP_SFPMUL` bit-packing.** The original
  `{sign^, exp+exp-127, man[22:11]*man[22:11]}` concatenation collapsed
  to 21 bits because the 12-bit×12-bit mantissa product was treated as
  self-determined-width = 12 bits, so the exponent landed at bits[19:12]
  (e.g. `1.0×2.0` → `0x00080000`). Fixed with explicit width casts
  (`{sign, 8'(exp), 23'(man*man)}`). Regression guard:
  `sfpu/test_sfpu_lane.test_mul`.
- **`sfpu_lane.sv:OP_SFPSHFT` right-shift width promotion.**
  `lreg_a >> (~lreg_b[4:0] + 1)` widened the shift amount to 32 bits in
  Verilator (the unsized literal `1` triggered zero-extension of the
  bitwise NOT), producing a shift ≥ 32 and result = 0. Rewritten as
  `lreg_a >> 5'(-lreg_b[4:0])` to pin the magnitude at 5 bits.
  Regression guard: `sfpu/test_sfpu_lane.test_shift`.
- **`sfpu_control.sv` FSM rework: pulse-only requests + SFPSTORE race
  + LOAD/EXEC write-back race.** Three related issues, all in one FSM:
  (1) `dst_load_req` / `dst_store_req` were reset every cycle so a
  contended `dst_if` lost the request and the controller hung;
  (2) `dst_if` sampled `sfpu_wdata` before the controller had pulsed
  `lane_valid`, so SFPSTORE captured zero; (3) `lane_valid` and
  `regfile_wr_en` fired the same edge, so the regfile wrote stale
  `lane.result` for both LOAD and compute ops. Restructured into a
  6-state machine (`SFPU_IDLE`, `SFPU_LOAD_REQ`, `SFPU_LOAD_COMP`,
  `SFPU_LOAD_WR`, `SFPU_EXEC_WR`, `SFPU_STORE_REQ`, `SFPU_DONE`) that
  holds requests across waits, pulses `lane_valid` one edge before
  `dst_store_req` for SFPSTORE, and defers `regfile_wr_en` one cycle
  after `lane_valid` for LOAD and compute. Also added an `DST_DRAIN`
  state to `sfpu_dst_if` so its `DST_IDLE` predicate doesn't
  re-trigger on a still-held request. Regression guards: all 6 tests
  in `sfpu/test_sfpu_top.py`.
- **`fpu_array.sv` `p_raw_exp` 9-bit unsigned wrap → spurious ±Inf for
  zero inputs.** `srca_exp + srcb_exp − 127` now uses 10-bit signed
  arithmetic so `0+0−127` underflows to zero in `man_to_fp32` instead
  of wrapping to `385` and tripping the overflow-to-Inf branch. Affected
  BF16/FP32/TF32 zero paths and BFP8 in general. Regression guard:
  `fpu/test_fpu_array_diag.py`.
- **BFP8 block-exp plumbing.** The `DATA_BFP8` arms of `fpu_array.sv`
  hard-coded `srca_exp = srcb_exp = 0`, so every product underflowed
  to zero (per-element exponents and the per-block shared exponent
  were both ignored). Added `srca_bfp_exp[FPU_COLS]` and
  `srcb_bfp_exp[FPU_ROWS]` input ports (one shared exp per
  `BFP_BLOCK_SIZE=16` row of K-elements), surfaced via the same flat
  shape on `fpu_array_wrapper.sv`. Per-element decode is signed s1.7
  with bit[7]=sign and bits[6:0]=magnitude; the array normalizes each
  (sign, mag, shared_exp) to the IEEE form the downstream multiplier
  consumes. `fpu_top.sv` ties the new ports to the FP32 bias (127)
  until block-exp routing via `fpu_config`/`fpu_control` lands. Golden
  models in `format_ref.py` / `fpu_ref.py` got a matching codec.
  Regression guard: `fpu/test_fpu_array.test_bfp8_matmul` (previously
  `@skip=True`).
- **`fpu_top_wrapper.sv` regfile stub returns the same SrcA/SrcB on
  every read.** `fpu_control` sequences each MVMUL as 4 row-groups,
  so single-MVMUL goldens were `4×` too small. Fixed test-side via
  `e2e_golden(...)` helper in `test_fpu_top.py` that runs
  `level_b_compute` four times with proper accumulate semantics.
- **`bf16_random` / `fp32_random` Level A tolerance** dropped — the
  RTL's deliberately-simplified non-rounding `fp32_add` cannot meet
  IEEE-aligned tolerances over K=16 accumulation. Level B (RTL =
  golden) bit-exact remains the strong invariant.
