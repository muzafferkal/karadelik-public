// Copyright (c) 2026 Muzaffer Kal <muzaffer@kal.cc>
// All rights reserved.
// KTC (Kal's Tensor Core) - Global Parameters
//
// Defines all architectural constants for the KTC tile.

package ktc_params;

  // ──────────────────────────────────────────────
  // Tile Geometry
  // ──────────────────────────────────────────────
  parameter int TILE_DIM        = 32;       // Tile is 32x32 elements
  parameter int TILE_SIZE       = TILE_DIM * TILE_DIM; // 1024 elements per tile

  // ──────────────────────────────────────────────
  // FPU (Matrix Engine) Parameters
  // ──────────────────────────────────────────────
  parameter int NUM_MULS        = 2048;     // Logical multiplies per row-group
  parameter int FPU_ROWS        = 8;        // Dst rows computed per row-group
  parameter int FPU_COLS        = 16;       // Dst columns computed per row-group
  parameter int FPU_K           = 16;       // Inner dimension (SrcA rows = SrcB cols)
  parameter int FPU_NUM_OUTPUTS = FPU_ROWS * FPU_COLS; // 128 output elements
  // FPU computes: Dst[8,16] += SrcB[8,16] @ SrcA[16,16] per row-group
  // Full 32x32 tile requires 4 row-groups (4 x 8 rows)

  // ──────────────────────────────────────────────
  // FPU DSP58 Mapping (FPGA)
  // ──────────────────────────────────────────────
  // Dual 8x8 packing: {a0, 8'h0, a1} × {b0, 8'h0, b1}
  //   P[15:0]  = a1 × b1           (exact)
  //   P[47:32] = a0 × b0 + carry   (carry is 0 or 1 from cross terms)
  //
  // Per output element: K=16 products, 2 per DSP → 8 DSPs
  // Per row-group: 128 outputs × 8 DSPs = 1024 DSP58 cells
  //
  // Format-dependent throughput (all use same 1024 physical DSPs):
  //   INT8/BFP8/BF16/FP8: dual-pack, 1 multiply cycle per row-group
  //   FP16/TF32:          single,    2 multiply cycles per row-group
  //   FP32:               single,    2 multiply cycles per row-group
  parameter int FPU_DSP_COUNT      = 1024;  // Physical DSP58 cells per tile
  parameter int FPU_DSPS_PER_OUT   = 8;     // DSPs per output element (dual mode)
  parameter int FPU_PRODS_PER_DSP  = 2;     // Products per DSP in dual 8×8 mode
  parameter int FPU_MUL_CYCLES_DUAL = 1;    // Multiply cycles for ≤8-bit mantissa
  parameter int FPU_MUL_CYCLES_WIDE = 2;    // Multiply cycles for >8-bit mantissa

  // ──────────────────────────────────────────────
  // SFPU (Vector Engine) Parameters
  // ──────────────────────────────────────────────
  parameter int SFPU_LANES      = 32;       // SIMD width
  parameter int SFPU_LREGS      = 8;        // Local registers per lane (Lreg0-Lreg7)
  parameter int SFPU_LREG_WIDTH = 32;       // Bits per lane register element

  // ──────────────────────────────────────────────
  // Register File Sizes (bytes)
  // ──────────────────────────────────────────────
  parameter int SRCA_SIZE       = 4096;     // SrcA: 4 KiB
  parameter int SRCB_SIZE       = 4096;     // SrcB: 4 KiB
  parameter int DST_SIZE        = 32768;    // Dst accumulator: 32 KiB
  parameter int DST_WIDTH       = 32;       // Dst element width (FP32 accumulation)

  // Derived register file dimensions
  // SrcA: 16 rows x 16 cols x 16b = 4 KiB (BF16/FP16 default)
  parameter int SRCA_ROWS       = 16;
  parameter int SRCA_COLS       = 16;
  // SrcB: 8 rows x 16 cols x 16b = ~4 KiB (with padding)
  parameter int SRCB_ROWS       = 16;
  parameter int SRCB_COLS       = 16;
  // Dst: 16 rows x 16 cols x 32b = ~32 KiB (FP32 accumulation)
  parameter int DST_ROWS        = 16;       // Rows per half (dual-bank)
  parameter int DST_COLS        = 16;
  parameter int DST_BANKS       = 2;        // Dual-bank for concurrent R/W

  // ──────────────────────────────────────────────
  // L1 SRAM
  // ──────────────────────────────────────────────
  parameter int L1_SIZE         = 1464 * 1024; // 1,464 KiB (~1.5 MB)
  parameter int L1_ADDR_WIDTH   = 21;       // ceil(log2(L1_SIZE))
  parameter int L1_DATA_WIDTH   = 128;      // L1 port width (bits)
  parameter int L1_NUM_BANKS    = 16;       // SRAM banks for concurrent access
  parameter int L1_BANK_SIZE    = L1_SIZE / L1_NUM_BANKS;

  // L1 address map
  parameter int L1_BASE_ADDR    = 32'h0000_0000;
  parameter int L1_END_ADDR     = L1_BASE_ADDR + L1_SIZE;

  // Write cache
  parameter int L1_WCACHE_LINES = 4;        // 4 cachelines
  parameter int L1_WCACHE_LINE  = 16;       // 16 bytes per line

  // ──────────────────────────────────────────────
  // L1 Arbiter Ports
  // ──────────────────────────────────────────────
  parameter int L1_NUM_PORTS    = 7;        // BRISC, NCRISC, TRISC0-2, Unpack DMA, Pack DMA

  // Port indices
  parameter int L1_PORT_BRISC   = 0;
  parameter int L1_PORT_NCRISC  = 1;
  parameter int L1_PORT_TRISC0  = 2;
  parameter int L1_PORT_TRISC1  = 3;
  parameter int L1_PORT_TRISC2  = 4;
  parameter int L1_PORT_UNPACK  = 5;
  parameter int L1_PORT_PACK    = 6;

  // ──────────────────────────────────────────────
  // NOC Parameters
  // ──────────────────────────────────────────────
  parameter int NOC_ADDR_WIDTH  = 64;       // NOC address: (x, y, local_addr)
  parameter int NOC_DATA_WIDTH  = 256;      // 256 bytes = 2048 bits per flit
  parameter int NOC_FLIT_BYTES  = NOC_DATA_WIDTH; // Alias
  parameter int NOC_X_WIDTH     = 6;        // X coordinate bits
  parameter int NOC_Y_WIDTH     = 6;        // Y coordinate bits
  parameter int NOC_LOCAL_WIDTH = 36;       // Local address bits

  // DRAM alignment requirements
  parameter int NOC_DRAM_RD_ALIGN = 64;     // Read: 64-byte aligned
  parameter int NOC_DRAM_WR_ALIGN = 16;     // Write: 16-byte aligned

  // ──────────────────────────────────────────────
  // Synchronization Primitives
  // ──────────────────────────────────────────────
  parameter int NUM_MUTEXES     = 8;
  parameter int NUM_SEMAPHORES  = 8;
  parameter int SEM_WIDTH       = 4;        // Semaphore counter width (0-15)

  // Mutex owner encoding
  parameter int MUTEX_TRISC0    = 2'd0;
  parameter int MUTEX_TRISC1    = 2'd1;
  parameter int MUTEX_TRISC2    = 2'd2;
  parameter int MUTEX_FREE      = 2'd3;

  // ──────────────────────────────────────────────
  // Instruction Pipe
  // ──────────────────────────────────────────────
  parameter int NUM_PIPES       = 3;        // One per TRISC (Unpack, Math, Pack)
  parameter int KTC_INSTR_WIDTH = 32;       // KTC instruction width
  parameter int KTC_OPCODE_WIDTH = 8;       // Opcode field width

  // MOP (Macro-Op) expander
  parameter int MOP_NUM_CFGS    = 9;        // mop_cfg[0..8] registers
  parameter int MOP_CFG_WIDTH   = 32;       // Config register width
  parameter int MOP_TEMPLATES   = 2;        // Number of MOP templates
  parameter int MOP_COUNT_WIDTH = 7;        // Loop counter width (0-127)

  // Replay expander
  parameter int REPLAY_IDX_WIDTH = 5;       // Replay buffer index (0-31)
  parameter int REPLAY_LEN_WIDTH = 5;       // Replay length (0-31)
  parameter int REPLAY_BUF_DEPTH = 32;      // Max instructions in replay buffer

  // ──────────────────────────────────────────────
  // ThCon (Tensor Configuration) Scalar Unit
  // ──────────────────────────────────────────────
  parameter int THCON_GPR_SETS  = 3;        // One per TRISC pipe
  parameter int THCON_GPR_DEPTH = 64;       // 64 registers per set
  parameter int THCON_GPR_WIDTH = 32;       // 32-bit registers
  parameter int THCON_NUM_CFGREGS = 261;    // Configuration registers (1-16 bits)
  parameter int THCON_NUM_CONTEXTS = 2;     // Dual context (StateID 0/1)

  // ──────────────────────────────────────────────
  // CV-X-IF Parameters (matching CV32E40X config)
  // ──────────────────────────────────────────────
  parameter int X_ID_WIDTH      = 4;        // Instruction ID width
  parameter int X_NUM_RS        = 2;        // Number of source registers (rs1, rs2)
  parameter int X_RFR_WIDTH     = 32;       // Register file read width (XLEN)
  parameter int X_RFW_WIDTH     = 32;       // Register file write width (XLEN)
  parameter int X_MISA          = 32'h0000_0000; // No standard extensions claimed
  parameter int X_DUALREAD      = 0;        // Single-read (rs1 only needed)
  parameter int X_DUALWRITE     = 0;        // No dual write
  parameter int X_ISSUE_REGISTER = 0;       // Combinational issue (0) or registered (1)

  // ──────────────────────────────────────────────
  // RISC-V Core Count
  // ──────────────────────────────────────────────
  parameter int NUM_DM_CORES    = 2;        // BRISC + NCRISC (CVE2)
  parameter int NUM_TRISC_CORES = 3;        // TRISC0 + TRISC1 + TRISC2 (CV32E40X)
  parameter int NUM_RISCV_CORES = NUM_DM_CORES + NUM_TRISC_CORES; // 5 total

  // Core ID encoding
  parameter int CORE_BRISC      = 0;
  parameter int CORE_NCRISC     = 1;
  parameter int CORE_TRISC0     = 2;
  parameter int CORE_TRISC1     = 3;
  parameter int CORE_TRISC2     = 4;

  // ──────────────────────────────────────────────
  // Per-core Instruction RAM
  // ──────────────────────────────────────────────
  // Each RISC-V core has a dedicated 16 KiB IRAM that holds its kernel.
  // IRAMs are loaded by BRISC (or by the host via NOC) before reset is
  // released. Cores fetch single-cycle from their IRAM; no I-cache.
  parameter int IRAM_SIZE          = 16 * 1024; // 16 KiB per core
  parameter int IRAM_DEPTH         = IRAM_SIZE / 4; // 4096 words
  parameter int IRAM_ADDR_WIDTH    = 14;        // byte addr width inside an IRAM
  parameter int IRAM_WORD_AW       = 12;        // word addr width (clog2(IRAM_DEPTH))

  // Per-core IRAM base addresses in the tile-local address space (high MMIO).
  parameter logic [31:0] IRAM_BRISC_BASE  = 32'hFFC0_0000;
  parameter logic [31:0] IRAM_NCRISC_BASE = 32'hFFC0_4000;
  parameter logic [31:0] IRAM_TRISC0_BASE = 32'hFFC0_8000;
  parameter logic [31:0] IRAM_TRISC1_BASE = 32'hFFC0_C000;
  parameter logic [31:0] IRAM_TRISC2_BASE = 32'hFFC1_0000;
  parameter logic [31:0] IRAM_REGION_MASK = 32'hFFFC_0000; // identifies 0xFFC0/0xFFC1 region

  // ──────────────────────────────────────────────
  // MMIO Control Blocks
  // ──────────────────────────────────────────────
  // Reset unit: per-core reset bits. Reaches every core's effective reset.
  parameter logic [31:0] RESET_UNIT_BASE  = 32'hFFB1_4000;
  parameter logic [31:0] RESET_UNIT_SIZE  = 32'h0000_1000;

  // Debug/observability unit: status, crash dump, PC buffer, watchdog.
  parameter logic [31:0] DEBUG_UNIT_BASE  = 32'hFFB1_2000;
  parameter logic [31:0] DEBUG_UNIT_SIZE  = 32'h0000_1000;

  // NOC Initiator Units (one per NOC). 4 KiB register window each
  // (regs in [0x000..0x0FF], 256-byte payload buffer in [0x100..0x1FF]).
  parameter logic [31:0] NIU_NOC0_BASE    = 32'hFFB0_0000;
  parameter logic [31:0] NIU_NOC1_BASE    = 32'hFFB0_1000;
  parameter logic [31:0] NIU_SIZE         = 32'h0000_1000;

  parameter int PC_BUF_DEPTH               = 16;
  parameter int PC_BUF_AW                  = 4;        // clog2(PC_BUF_DEPTH)
  parameter logic [31:0] WATCHDOG_THRESHOLD_DEFAULT = 32'd100_000;

  // ──────────────────────────────────────────────
  // DRAM tile (chip-edge DRAM endpoint at (DRAM_X, DRAM_Y))
  // ──────────────────────────────────────────────
  // A single DRAM tile sits east of the compute column at (2,0). Compute
  // tiles reach it by sending NOC packets with local_addr = byte offset
  // into DRAM. The dram_controller turns each local-bus word write into
  // a 1-beat AXI4 master write. The backend behind that AXI master is a
  // build-time choice (see DRAM_BACKEND).
  parameter int DRAM_X            = 2;
  parameter int DRAM_Y            = 0;
  parameter int DRAM_SIZE         = 1 * 1024 * 1024;  // 1 MiB in sim BRAM
  parameter int DRAM_AXI_AW       = 32;               // byte address bits
  parameter int DRAM_AXI_DW       = 32;               // matches local-bus
  parameter int DRAM_AXI_IDW      = 4;                // small ID space

  // ──────────────────────────────────────────────
  // Circular Buffer
  // ──────────────────────────────────────────────
  parameter int CB_MAX_BUFFERS  = 32;       // Max circular buffers per tile
  parameter int CB_PTR_WIDTH    = L1_ADDR_WIDTH; // Pointer width = L1 address width

  // ──────────────────────────────────────────────
  // Data Format Encoding (used in config registers)
  // ──────────────────────────────────────────────
  parameter int FMT_FP32        = 4'd0;
  parameter int FMT_FP16        = 4'd1;
  parameter int FMT_BF16        = 4'd2;
  parameter int FMT_FP8_E4M3    = 4'd3;
  parameter int FMT_FP8_E5M2    = 4'd4;
  parameter int FMT_TF32        = 4'd5;
  parameter int FMT_INT8        = 4'd6;
  parameter int FMT_INT16       = 4'd7;
  parameter int FMT_INT32       = 4'd8;
  parameter int FMT_BFP8        = 4'd9;     // Block FP, 8-bit mantissa
  parameter int FMT_BFP4        = 4'd10;    // Block FP, 4-bit mantissa
  parameter int FMT_BFP2        = 4'd11;    // Block FP, 2-bit mantissa

endpackage
