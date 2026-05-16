// Copyright (c) 2026 Muzaffer Kal <muzaffer@kal.cc>
// All rights reserved.
// KTC (Kal's Tensor Core) - Data Type Definitions
//
// Packed struct types for all numeric formats supported by the KTC tile,
// plus format conversion function prototypes.

package ktc_types;

  import ktc_params::*;

  // ──────────────────────────────────────────────
  // IEEE 754 Floating Point Types
  // ──────────────────────────────────────────────

  // FP32 (IEEE 754 single precision)
  typedef struct packed {
    logic        sign;
    logic [7:0]  exponent;
    logic [22:0] mantissa;
  } fp32_t;

  // FP16 (IEEE 754 half precision)
  typedef struct packed {
    logic        sign;
    logic [4:0]  exponent;
    logic [9:0]  mantissa;
  } fp16_t;

  // BF16 (Brain Float 16 - truncated FP32)
  typedef struct packed {
    logic        sign;
    logic [7:0]  exponent;
    logic [6:0]  mantissa;
  } bf16_t;

  // TF32 (TensorFloat-32: 1+8+10 = 19 bits, padded to 32)
  typedef struct packed {
    logic        sign;
    logic [7:0]  exponent;
    logic [9:0]  mantissa;
    logic [12:0] _pad;
  } tf32_t;

  // FP8 E4M3 (1+4+3 = 8 bits, higher precision, lower range)
  typedef struct packed {
    logic       sign;
    logic [3:0] exponent;
    logic [2:0] mantissa;
  } fp8_e4m3_t;

  // FP8 E5M2 (1+5+2 = 8 bits, lower precision, higher range)
  typedef struct packed {
    logic       sign;
    logic [4:0] exponent;
    logic [1:0] mantissa;
  } fp8_e5m2_t;

  // ──────────────────────────────────────────────
  // Block Floating Point Types
  // ──────────────────────────────────────────────

  // Block FP: shared exponent + array of mantissas
  // A block is typically 16 or 32 elements sharing one exponent
  parameter int BFP_BLOCK_SIZE = 16;

  // Packed BFP block layouts: shared exponent followed by BLOCK_SIZE
  // mantissas. Packed (not unpacked) so the structs themselves remain
  // packed-typeable (IEEE 1800 7.2.1).
  typedef struct packed {
    logic [7:0]                       shared_exponent;
    logic [BFP_BLOCK_SIZE-1:0][7:0]   mantissa; // BFP8: 8-bit mantissa
  } bfp8_block_t;

  typedef struct packed {
    logic [7:0]                       shared_exponent;
    logic [BFP_BLOCK_SIZE-1:0][3:0]   mantissa; // BFP4: 4-bit mantissa
  } bfp4_block_t;

  typedef struct packed {
    logic [7:0]                       shared_exponent;
    logic [BFP_BLOCK_SIZE-1:0][1:0]   mantissa; // BFP2: 2-bit mantissa
  } bfp2_block_t;

  // ──────────────────────────────────────────────
  // Format Descriptor (used in config registers)
  // ──────────────────────────────────────────────

  typedef enum logic [3:0] {
    DATA_FP32     = 4'd0,
    DATA_FP16     = 4'd1,
    DATA_BF16     = 4'd2,
    DATA_FP8_E4M3 = 4'd3,
    DATA_FP8_E5M2 = 4'd4,
    DATA_TF32     = 4'd5,
    DATA_INT8     = 4'd6,
    DATA_INT16    = 4'd7,
    DATA_INT32    = 4'd8,
    DATA_BFP8     = 4'd9,
    DATA_BFP4     = 4'd10,
    DATA_BFP2     = 4'd11
  } data_format_t;

  // Bytes per element (for non-block formats)
  function automatic int format_bytes(input data_format_t fmt);
    case (fmt)
      DATA_FP32:     return 4;
      DATA_FP16:     return 2;
      DATA_BF16:     return 2;
      DATA_FP8_E4M3: return 1;
      DATA_FP8_E5M2: return 1;
      DATA_TF32:     return 4;
      DATA_INT8:     return 1;
      DATA_INT16:    return 2;
      DATA_INT32:    return 4;
      DATA_BFP8:     return 1; // Per element (plus shared exp amortized)
      DATA_BFP4:     return 1; // Packed: 2 elements per byte
      DATA_BFP2:     return 1; // Packed: 4 elements per byte
      default:       return 4;
    endcase
  endfunction

  // ──────────────────────────────────────────────
  // Rounding Modes
  // ──────────────────────────────────────────────

  typedef enum logic [1:0] {
    ROUND_NEAREST_EVEN = 2'd0,  // IEEE 754 default
    ROUND_STOCHASTIC   = 2'd1,  // Stochastic rounding (for training)
    ROUND_TRUNCATE     = 2'd2,  // Truncation (toward zero)
    ROUND_UP           = 2'd3   // Round toward +inf
  } round_mode_t;

  // ──────────────────────────────────────────────
  // KTC Instruction Encoding
  // ──────────────────────────────────────────────

  typedef struct packed {
    logic [7:0]  opcode;
    logic [23:0] operands;
  } ktc_instr_t;

  // Common operand field layouts (opcode-dependent interpretation)

  // Math ops: MVMUL, ELWADD, etc.
  typedef struct packed {
    logic [7:0]  opcode;
    logic [3:0]  dst_idx;      // Dst tile index
    logic [3:0]  srca_idx;     // SrcA tile index
    logic [3:0]  srcb_idx;     // SrcB tile index
    logic        clear_acc;    // Clear accumulator before op
    logic        state_id;     // Dual-context select
    logic [9:0]  reserved;
  } math_instr_t;

  // SFPU ops
  typedef struct packed {
    logic [7:0]  opcode;
    logic [2:0]  lreg_dst;     // Destination Lreg (0-7)
    logic [2:0]  lreg_src_a;   // Source A Lreg
    logic [2:0]  lreg_src_b;   // Source B Lreg
    logic [3:0]  dst_row;      // Dst register row for load/store
    logic [2:0]  imm;          // Small immediate
    logic [6:0]  reserved;
  } sfpu_instr_t;

  // Sync ops: STALLWAIT
  typedef struct packed {
    logic [7:0]  opcode;
    logic [15:0] stall_mask;   // Bitmask of conditions to wait on
    logic [7:0]  reserved;
  } sync_instr_t;

  // MOP ops
  typedef struct packed {
    logic [7:0]  opcode;
    logic [6:0]  loop_count;   // Iteration count
    logic        template_sel; // Template 0 or 1
    logic [7:0]  inner_count;  // Inner loop count
    logic [7:0]  reserved;
  } mop_instr_t;

  // Config ops: SETC16, WRCFG, RDCFG
  typedef struct packed {
    logic [7:0]  opcode;
    logic [8:0]  cfg_addr;     // Config register address (0-511)
    logic [15:0] cfg_data;     // 16-bit data (for SETC16)
  } config_instr_t; // Note: total 41 bits; in practice operands overlap

  // ──────────────────────────────────────────────
  // Tile Data Structure
  // ──────────────────────────────────────────────

  // A tile in L1 SRAM (32x32 elements in tile-order)
  typedef logic [31:0] tile_element_t;
  typedef tile_element_t tile_data_t [TILE_DIM][TILE_DIM];

  // ──────────────────────────────────────────────
  // SFPU Lane Data
  // ──────────────────────────────────────────────

  typedef logic [SFPU_LREG_WIDTH-1:0] sfpu_lane_t [SFPU_LANES];

endpackage
