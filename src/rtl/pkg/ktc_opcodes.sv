// Copyright (c) 2026 Muzaffer Kal <muzaffer@kal.cc>
// All rights reserved.
// KTC (Kal's Tensor Core) - Opcode Definitions
//
// Full KTC instruction opcode encoding table.
// 8-bit opcode space (values < 0xC0), organized by functional unit.
//
// Instruction format (32 bits):
//   [31:24] opcode    - 8-bit operation code
//   [23:0]  operands  - Opcode-specific fields (register indices, immediates, modes)
//
// When dispatched via CV-X-IF, the 32-bit encoding is carried in rs1 GPR.
// The TT_OP_* macros construct these 32-bit encodings.

package ktc_opcodes;

  // ──────────────────────────────────────────────
  // Opcode Categories (upper nibble of opcode)
  // ──────────────────────────────────────────────
  // 0x0_-0x1_  : Unpack operations
  // 0x2_-0x3_  : Math/FPU operations
  // 0x4_-0x5_  : SFPU operations
  // 0x6_-0x7_  : Pack operations
  // 0x8_-0x9_  : Configuration / ThCon
  // 0xA_-0xB_  : Synchronization / Control flow
  // 0xC_-0xFF  : Reserved (invalid in KTC pipe)

  // ──────────────────────────────────────────────
  // Unpack Operations (0x00 - 0x1F)
  // ──────────────────────────────────────────────
  parameter logic [7:0] OP_UNPACR          = 8'h01; // Unpack A register (SrcA load)
  parameter logic [7:0] OP_UNPACR_NOP      = 8'h02; // Unpack NOP (advance counters only)
  parameter logic [7:0] OP_UNPACK_AB       = 8'h03; // Unpack both A and B simultaneously
  parameter logic [7:0] OP_UNPACK_A        = 8'h04; // Unpack A only
  parameter logic [7:0] OP_UNPACK_B        = 8'h05; // Unpack B only
  parameter logic [7:0] OP_UNPACK_TILIZE   = 8'h06; // Unpack with tilize (row-major -> tile)
  parameter logic [7:0] OP_UNPACK_HALO     = 8'h07; // Unpack with halo region (conv)
  parameter logic [7:0] OP_UNPACK_REDUCE   = 8'h08; // Unpack for reduce operations
  parameter logic [7:0] OP_SETADC          = 8'h09; // Set address counter
  parameter logic [7:0] OP_SETADC_MOD      = 8'h0A; // Set address counter modifier
  parameter logic [7:0] OP_ADDR_MOD_SET    = 8'h0B; // Set ADDR_MOD register
  parameter logic [7:0] OP_UNPACK_CFG      = 8'h0C; // Unpack configuration write

  // ──────────────────────────────────────────────
  // Math / FPU Operations (0x20 - 0x3F)
  // ──────────────────────────────────────────────
  parameter logic [7:0] OP_MVMUL           = 8'h20; // Matrix-vector multiply: Dst = SrcB @ SrcA
  parameter logic [7:0] OP_MVMUL_TRANSP    = 8'h21; // Transposed multiply
  parameter logic [7:0] OP_ELWADD          = 8'h22; // Element-wise add: Dst = SrcA + SrcB
  parameter logic [7:0] OP_ELWSUB          = 8'h23; // Element-wise sub: Dst = SrcA - SrcB
  parameter logic [7:0] OP_ELWMUL          = 8'h24; // Element-wise mul: Dst = SrcA * SrcB
  parameter logic [7:0] OP_ZEROACC         = 8'h25; // Zero accumulator (clear Dst)
  parameter logic [7:0] OP_INCRACC         = 8'h26; // Increment accumulator
  parameter logic [7:0] OP_SETPRECISION    = 8'h27; // Set FPU precision mode
  parameter logic [7:0] OP_GAPOOL          = 8'h28; // Global average pool
  parameter logic [7:0] OP_REDUCE          = 8'h29; // Reduce operation

  // ──────────────────────────────────────────────
  // SFPU Operations (0x40 - 0x5F)
  // ──────────────────────────────────────────────
  parameter logic [7:0] OP_SFPLOAD         = 8'h40; // Load Dst row into Lreg
  parameter logic [7:0] OP_SFPSTORE        = 8'h41; // Store Lreg into Dst row
  parameter logic [7:0] OP_SFPADD          = 8'h42; // Vector add: Lreg[d] = Lreg[a] + Lreg[b]
  parameter logic [7:0] OP_SFPSUB          = 8'h43; // Vector sub
  parameter logic [7:0] OP_SFPMUL          = 8'h44; // Vector mul
  parameter logic [7:0] OP_SFPMAD          = 8'h45; // Vector multiply-add: d = a*b + c
  parameter logic [7:0] OP_SFPABS          = 8'h46; // Vector abs
  parameter logic [7:0] OP_SFPNEG          = 8'h47; // Vector negate
  parameter logic [7:0] OP_SFPMAX          = 8'h48; // Vector max
  parameter logic [7:0] OP_SFPMIN          = 8'h49; // Vector min
  parameter logic [7:0] OP_SFPRECIP        = 8'h4A; // Vector reciprocal (1/x)
  parameter logic [7:0] OP_SFPSQRT         = 8'h4B; // Vector sqrt
  parameter logic [7:0] OP_SFPRSQRT        = 8'h4C; // Vector reciprocal sqrt (1/sqrt(x))
  parameter logic [7:0] OP_SFPEXP          = 8'h4D; // Vector exponential (e^x)
  parameter logic [7:0] OP_SFPLOG          = 8'h4E; // Vector natural log (ln(x))
  parameter logic [7:0] OP_SFPTANH         = 8'h4F; // Vector tanh
  parameter logic [7:0] OP_SFPSIGMOID      = 8'h50; // Vector sigmoid (1/(1+e^-x))
  parameter logic [7:0] OP_SFPGELU         = 8'h51; // Vector GELU activation
  parameter logic [7:0] OP_SFPEXMAN        = 8'h52; // Extract mantissa
  parameter logic [7:0] OP_SFPEXEXP        = 8'h53; // Extract exponent
  parameter logic [7:0] OP_SFPSETMAN       = 8'h54; // Set mantissa
  parameter logic [7:0] OP_SFPSETEXP       = 8'h55; // Set exponent
  parameter logic [7:0] OP_SFPSETSGN       = 8'h56; // Set sign bit
  parameter logic [7:0] OP_SFPLZ           = 8'h57; // Count leading zeros
  parameter logic [7:0] OP_SFPSHFT         = 8'h58; // Shift left/right
  parameter logic [7:0] OP_SFPAND          = 8'h59; // Bitwise AND
  parameter logic [7:0] OP_SFPOR           = 8'h5A; // Bitwise OR
  parameter logic [7:0] OP_SFPXOR          = 8'h5B; // Bitwise XOR
  parameter logic [7:0] OP_SFPNOT          = 8'h5C; // Bitwise NOT
  parameter logic [7:0] OP_SFPCAST         = 8'h5D; // Type cast (fp32<->fp16, int<->float)
  parameter logic [7:0] OP_SFPLUT          = 8'h5E; // LUT-based transcendental
  parameter logic [7:0] OP_SFPSETCC        = 8'h5F; // Set condition code (predication)

  // ──────────────────────────────────────────────
  // Pack Operations (0x60 - 0x7F)
  // ──────────────────────────────────────────────
  parameter logic [7:0] OP_PACR            = 8'h60; // Pack register to L1
  parameter logic [7:0] OP_PACR_NOP        = 8'h61; // Pack NOP (advance counters)
  parameter logic [7:0] OP_PACK_A          = 8'h62; // Pack from Dst to L1 (section A)
  parameter logic [7:0] OP_PACK_B          = 8'h63; // Pack from Dst to L1 (section B)
  parameter logic [7:0] OP_PACK_RELU       = 8'h64; // Pack with ReLU activation
  parameter logic [7:0] OP_PACK_UNTILIZE   = 8'h65; // Pack with untilize (tile -> row-major)
  parameter logic [7:0] OP_PACK_REDUCE     = 8'h66; // Pack for reduce results
  parameter logic [7:0] OP_PACK_CFG        = 8'h67; // Pack configuration write

  // ──────────────────────────────────────────────
  // Configuration / ThCon Operations (0x80 - 0x9F)
  // ──────────────────────────────────────────────
  parameter logic [7:0] OP_SETC16          = 8'h80; // Set 16-bit config register
  parameter logic [7:0] OP_WRCFG           = 8'h81; // Write config from GPR
  parameter logic [7:0] OP_RDCFG           = 8'h82; // Read config to GPR
  parameter logic [7:0] OP_REG2FLOP        = 8'h83; // Transfer GPR value to functional unit FLOP
  parameter logic [7:0] OP_FLOP2REG        = 8'h84; // Transfer FLOP value to GPR
  parameter logic [7:0] OP_SETDMAREG       = 8'h85; // Set DMA register (for data movement)
  parameter logic [7:0] OP_RMWCIB          = 8'h86; // Read-modify-write config in block
  parameter logic [7:0] OP_LOADIND         = 8'h87; // Load indirect (GPR indexing)
  parameter logic [7:0] OP_STOREIND        = 8'h88; // Store indirect
  parameter logic [7:0] OP_ATCAS           = 8'h89; // Atomic compare-and-swap
  parameter logic [7:0] OP_ATINCR          = 8'h8A; // Atomic increment
  parameter logic [7:0] OP_ATSWAP          = 8'h8B; // Atomic swap

  // ThCon ALU operations
  parameter logic [7:0] OP_THADD           = 8'h90; // ThCon add: GPR[d] = GPR[a] + GPR[b]
  parameter logic [7:0] OP_THSUB           = 8'h91; // ThCon sub
  parameter logic [7:0] OP_THMUL           = 8'h92; // ThCon mul
  parameter logic [7:0] OP_THAND           = 8'h93; // ThCon AND
  parameter logic [7:0] OP_THOR            = 8'h94; // ThCon OR
  parameter logic [7:0] OP_THXOR           = 8'h95; // ThCon XOR
  parameter logic [7:0] OP_THSHL           = 8'h96; // ThCon shift left
  parameter logic [7:0] OP_THSHR           = 8'h97; // ThCon shift right
  parameter logic [7:0] OP_THADDI          = 8'h98; // ThCon add immediate

  // ──────────────────────────────────────────────
  // Synchronization / Control (0xA0 - 0xBF)
  // ──────────────────────────────────────────────
  parameter logic [7:0] OP_STALLWAIT       = 8'hA0; // Stall until condition met
  parameter logic [7:0] OP_SEMPOST         = 8'hA1; // Semaphore post (increment)
  parameter logic [7:0] OP_SEMGET          = 8'hA2; // Semaphore get (decrement)
  parameter logic [7:0] OP_SEMWAIT         = 8'hA3; // Wait for semaphore > 0
  parameter logic [7:0] OP_MUTEX_ACQ       = 8'hA4; // Acquire mutex
  parameter logic [7:0] OP_MUTEX_REL       = 8'hA5; // Release mutex
  parameter logic [7:0] OP_FLUSH           = 8'hA6; // Flush pipeline
  parameter logic [7:0] OP_NOP             = 8'hA7; // No operation

  // MOP (Macro-Op) control
  parameter logic [7:0] OP_MOP             = 8'hA8; // Execute macro-op template
  parameter logic [7:0] OP_MOP_CFG         = 8'hA9; // Configure MOP register
  parameter logic [7:0] OP_MOP_END         = 8'hAA; // End of MOP body (expansion boundary)

  // Replay control
  parameter logic [7:0] OP_REPLAY          = 8'hAB; // Replay instruction sequence
  parameter logic [7:0] OP_REPLAY_CFG      = 8'hAC; // Configure replay (record/tee/play)

  // State control
  parameter logic [7:0] OP_SETSTATEID      = 8'hAD; // Set dual-context StateID (0 or 1)
  parameter logic [7:0] OP_CLEARDVALID     = 8'hAE; // Clear destination valid flags

  // ──────────────────────────────────────────────
  // Stall Condition Bit Masks (for OP_STALLWAIT)
  // ──────────────────────────────────────────────
  parameter int STALL_MATH_BUSY     = 0;    // FPU is busy
  parameter int STALL_SFPU_BUSY     = 1;    // SFPU is busy
  parameter int STALL_UNPACK_BUSY   = 2;    // Unpacker is busy
  parameter int STALL_PACK_BUSY     = 3;    // Packer is busy
  parameter int STALL_THCON_BUSY    = 4;    // ThCon is busy
  parameter int STALL_SRCA_VALID    = 5;    // Wait for SrcA valid
  parameter int STALL_SRCB_VALID    = 6;    // Wait for SrcB valid
  parameter int STALL_DST_VALID     = 7;    // Wait for Dst valid
  parameter int STALL_DST_FREE      = 8;    // Wait for Dst bank free

  // ──────────────────────────────────────────────
  // Instruction Field Extraction Functions
  // ──────────────────────────────────────────────
  function automatic logic [7:0] get_opcode(input logic [31:0] instr);
    return instr[31:24];
  endfunction

  function automatic logic [23:0] get_operands(input logic [31:0] instr);
    return instr[23:0];
  endfunction

  // Unit select based on opcode category
  typedef enum logic [2:0] {
    UNIT_UNPACK  = 3'd0,
    UNIT_FPU     = 3'd1,
    UNIT_SFPU    = 3'd2,
    UNIT_PACK    = 3'd3,
    UNIT_THCON   = 3'd4,
    UNIT_SYNC    = 3'd5,
    UNIT_MOP     = 3'd6,
    UNIT_REPLAY  = 3'd7
  } unit_sel_t;

  function automatic unit_sel_t decode_unit(input logic [7:0] opcode);
    casez (opcode)
      8'h0?:    return UNIT_UNPACK;
      8'h1?:    return UNIT_UNPACK;
      8'h2?:    return UNIT_FPU;
      8'h3?:    return UNIT_FPU;
      8'h4?:    return UNIT_SFPU;
      8'h5?:    return UNIT_SFPU;
      8'h6?:    return UNIT_PACK;
      8'h7?:    return UNIT_PACK;
      8'h8?:    return UNIT_THCON;
      8'h9?:    return UNIT_THCON;
      8'hA8:    return UNIT_MOP;     // OP_MOP
      8'hA9:    return UNIT_MOP;     // OP_MOP_CFG
      8'hAA:    return UNIT_MOP;     // OP_MOP_END
      8'hAB:    return UNIT_REPLAY;  // OP_REPLAY
      8'hAC:    return UNIT_REPLAY;  // OP_REPLAY_CFG
      8'hA?:    return UNIT_SYNC;
      8'hB?:    return UNIT_SYNC;
      default:  return UNIT_SYNC;    // Invalid -> treat as NOP
    endcase
  endfunction

endpackage
