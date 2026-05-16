// Copyright (c) 2026 Muzaffer Kal <muzaffer@kal.cc>
// All rights reserved.
// KTC (Kal's Tensor Core) - SystemVerilog Interface Definitions
//
// Defines all inter-module interfaces used within the KTC tile.
// Using SV interfaces reduces port list bloat and makes connectivity explicit.

package ktc_interfaces;
  import ktc_params::*;
endpackage

// CV-X-IF: use `cv32e40x_if_xif` from the upstream CV32E40X package directly.
// (Previously this file declared a karadelik-specific `cvxif_if`; replaced
// to avoid a translation layer between the core and the adapter.)


// ────────────────────────────────────────────────────
// L1 SRAM Port Interface
// Used by all modules that access L1 memory.
// ────────────────────────────────────────────────────
interface l1_if;

  import ktc_params::*;

  logic                      req;
  logic                      gnt;       // Grant from arbiter
  logic                      we;        // Write enable
  logic [L1_ADDR_WIDTH-1:0]  addr;
  logic [L1_DATA_WIDTH-1:0]  wdata;
  logic [L1_DATA_WIDTH/8-1:0] be;       // Byte enables
  logic [L1_DATA_WIDTH-1:0]  rdata;
  logic                      rvalid;    // Read data valid

  modport master (
    output req, we, addr, wdata, be,
    input  gnt, rdata, rvalid
  );

  modport slave (
    input  req, we, addr, wdata, be,
    output gnt, rdata, rvalid
  );

endinterface


// ────────────────────────────────────────────────────
// Instruction Pipe Interface
// Between CV-X-IF adapter and instruction pipe stages.
// ────────────────────────────────────────────────────
interface pipe_if;

  import ktc_params::*;

  logic                         valid;
  logic                         ready;
  logic [KTC_INSTR_WIDTH-1:0]   instr;      // 32-bit KTC instruction
  logic [X_ID_WIDTH-1:0]        id;          // Instruction ID (for result tracking)
  logic                         committed;   // Post-commit (safe to execute)

  modport source (
    output valid, instr, id, committed,
    input  ready
  );

  modport sink (
    input  valid, instr, id, committed,
    output ready
  );

endinterface


// ────────────────────────────────────────────────────
// NOC Router Port Interface
// Per-direction port on the 2D torus NOC router.
// ────────────────────────────────────────────────────
interface noc_if;

  import ktc_params::*;

  // Header
  logic                        valid;
  logic                        ready;
  logic [NOC_X_WIDTH-1:0]      dst_x;
  logic [NOC_Y_WIDTH-1:0]      dst_y;
  logic [NOC_LOCAL_WIDTH-1:0]  local_addr;
  logic                        is_write;     // 1 = write, 0 = read request
  logic                        is_multicast;
  logic [7:0]                  length;       // Payload length in flits

  // Data
  logic [NOC_DATA_WIDTH*8-1:0] data;         // Flit data (256 bytes = 2048 bits)
  logic                        data_valid;
  logic                        data_ready;

  modport tx (
    output valid, dst_x, dst_y, local_addr, is_write, is_multicast, length,
           data, data_valid,
    input  ready, data_ready
  );

  modport rx (
    input  valid, dst_x, dst_y, local_addr, is_write, is_multicast, length,
           data, data_valid,
    output ready, data_ready
  );

endinterface


// ────────────────────────────────────────────────────
// Register File Interface
// For SrcA, SrcB, Dst read/write ports.
// ────────────────────────────────────────────────────
interface regfile_if #(
  parameter int ADDR_WIDTH = 8,
  parameter int DATA_WIDTH = 32
);

  logic                      re;        // Read enable
  logic                      we;        // Write enable
  logic [ADDR_WIDTH-1:0]     addr;
  logic [DATA_WIDTH-1:0]     wdata;
  logic [DATA_WIDTH-1:0]     rdata;
  logic                      rvalid;

  modport master (
    output re, we, addr, wdata,
    input  rdata, rvalid
  );

  modport slave (
    input  re, we, addr, wdata,
    output rdata, rvalid
  );

endinterface


// ────────────────────────────────────────────────────
// Execution Unit Status Interface
// Each backend unit reports busy/done status.
// ────────────────────────────────────────────────────
interface unit_status_if;

  logic busy;
  logic done;
  logic error;

  modport unit (
    output busy, done, error
  );

  modport monitor (
    input busy, done, error
  );

endinterface


// ────────────────────────────────────────────────────
// Synchronization Interface
// Access to mutexes and semaphores from instruction pipes.
// ────────────────────────────────────────────────────
interface sync_if;

  import ktc_params::*;

  // Semaphore access
  logic                      sem_post;
  logic                      sem_get;
  logic [$clog2(NUM_SEMAPHORES)-1:0] sem_idx;
  logic [SEM_WIDTH-1:0]      sem_value;     // Current semaphore value (read)
  logic                      sem_ack;

  // Mutex access
  logic                      mutex_acq;
  logic                      mutex_rel;
  logic [$clog2(NUM_MUTEXES)-1:0] mutex_idx;
  logic                      mutex_granted;
  logic                      mutex_ack;

  // Stall request
  logic [15:0]               stall_mask;    // Condition mask from STALLWAIT
  logic                      stall_active;  // Currently stalled

  modport pipe (
    output sem_post, sem_get, sem_idx,
           mutex_acq, mutex_rel, mutex_idx,
           stall_mask,
    input  sem_value, sem_ack,
           mutex_granted, mutex_ack,
           stall_active
  );

  modport controller (
    input  sem_post, sem_get, sem_idx,
           mutex_acq, mutex_rel, mutex_idx,
           stall_mask,
    output sem_value, sem_ack,
           mutex_granted, mutex_ack,
           stall_active
  );

endinterface
