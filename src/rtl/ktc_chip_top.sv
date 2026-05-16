// Copyright (c) 2026 Muzaffer Kal <muzaffer@kal.cc>
// All rights reserved.
// KTC Chip Top (2x2 mesh)
//
// Tile (0,0) is a `ktc_host_tile` (AXI-attached, no cores); the other
// three coordinates -- (1,0), (0,1), (1,1) -- are compute tiles
// (`ktc_tile_top`). NOC0 and NOC1 are counter-rotating; the host tile
// boots the compute tiles by writing NIU registers via AXI.
//
// The 2x2 case is unrolled rather than parameterised because Verilator
// rejects 2-D interface arrays as port connections. A future
// CHIP_X/CHIP_Y-parameterised version is a structural rewrite, not a
// behavioural change.
//
//                ┌─────────┐ N ┌─────────┐
//                │ (0,1)   │←→│ (1,1)   │
//                │ compute │ E │ compute │
//                └────┬────┘   └────┬────┘
//                   S│↑              │↑
//                   ▼│               │
//                ┌─────────┐ E ┌─────────┐
//                │ (0,0)   │←→│ (1,0)   │
//                │ HOST    │   │ compute │
//                └─────────┘   └─────────┘
//
// All chip boundary cardinal ports are tied off inside (no torus wrap).

module ktc_chip_top
  import ktc_params::*;
  import noc_pkg::*;
#(
  // DRAM tile backend select: "BRAM" routes to an internal inferred BRAM
  // (cocotb sim, BRAM-only smoke synth); "DDRMC" routes the AXI master
  // out through m_axi_dram_* so a Xilinx DDRMC IP (fabric DDR) or the
  // PS NoC S_AXI_HP slave (PS DDR) can sink it.
  parameter string DRAM_BACKEND = "BRAM"
) (
  input  logic clk,
  input  logic rst_n,
  input  logic tile_reset_n,

  // AXI4-Lite slave (bound to tile (0,0), the host tile).
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_awaddr,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  output logic [1:0]  s_axi_bresp,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  input  logic [31:0] s_axi_araddr,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,

  // AXI4 master from the DRAM tile (bound to tile (2,0)). Live only
  // when DRAM_BACKEND="DDRMC"; tied to inactive defaults under "BRAM".
  output logic                       m_axi_dram_awvalid,
  input  logic                       m_axi_dram_awready,
  output logic [DRAM_AXI_IDW-1:0]    m_axi_dram_awid,
  output logic [DRAM_AXI_AW-1:0]     m_axi_dram_awaddr,
  output logic [7:0]                 m_axi_dram_awlen,
  output logic [2:0]                 m_axi_dram_awsize,
  output logic [1:0]                 m_axi_dram_awburst,
  output logic                       m_axi_dram_wvalid,
  input  logic                       m_axi_dram_wready,
  output logic [DRAM_AXI_DW-1:0]     m_axi_dram_wdata,
  output logic [DRAM_AXI_DW/8-1:0]   m_axi_dram_wstrb,
  output logic                       m_axi_dram_wlast,
  input  logic                       m_axi_dram_bvalid,
  output logic                       m_axi_dram_bready,
  input  logic [DRAM_AXI_IDW-1:0]    m_axi_dram_bid,
  input  logic [1:0]                 m_axi_dram_bresp,
  output logic                       m_axi_dram_arvalid,
  input  logic                       m_axi_dram_arready,
  output logic [DRAM_AXI_IDW-1:0]    m_axi_dram_arid,
  output logic [DRAM_AXI_AW-1:0]     m_axi_dram_araddr,
  output logic [7:0]                 m_axi_dram_arlen,
  output logic [2:0]                 m_axi_dram_arsize,
  output logic [1:0]                 m_axi_dram_arburst,
  input  logic                       m_axi_dram_rvalid,
  output logic                       m_axi_dram_rready,
  input  logic [DRAM_AXI_IDW-1:0]    m_axi_dram_rid,
  input  logic [DRAM_AXI_DW-1:0]     m_axi_dram_rdata,
  input  logic [1:0]                 m_axi_dram_rresp,
  input  logic                       m_axi_dram_rlast
);

  // ────────────────────────────────────────────────────────────────
  // Cardinal interface instances -- one per tile per NOC per direction.
  // Naming: t<x><y>_<noc>_<dir>_<in|out>.
  // ────────────────────────────────────────────────────────────────
  // Tile (0,0) host
  noc_if t00_n0_n_in (), t00_n0_n_out (), t00_n0_s_in (), t00_n0_s_out ();
  noc_if t00_n0_e_in (), t00_n0_e_out (), t00_n0_w_in (), t00_n0_w_out ();
  noc_if t00_n1_n_in (), t00_n1_n_out (), t00_n1_s_in (), t00_n1_s_out ();
  noc_if t00_n1_e_in (), t00_n1_e_out (), t00_n1_w_in (), t00_n1_w_out ();
  // Tile (1,0)
  noc_if t10_n0_n_in (), t10_n0_n_out (), t10_n0_s_in (), t10_n0_s_out ();
  noc_if t10_n0_e_in (), t10_n0_e_out (), t10_n0_w_in (), t10_n0_w_out ();
  noc_if t10_n1_n_in (), t10_n1_n_out (), t10_n1_s_in (), t10_n1_s_out ();
  noc_if t10_n1_e_in (), t10_n1_e_out (), t10_n1_w_in (), t10_n1_w_out ();
  // Tile (0,1)
  noc_if t01_n0_n_in (), t01_n0_n_out (), t01_n0_s_in (), t01_n0_s_out ();
  noc_if t01_n0_e_in (), t01_n0_e_out (), t01_n0_w_in (), t01_n0_w_out ();
  noc_if t01_n1_n_in (), t01_n1_n_out (), t01_n1_s_in (), t01_n1_s_out ();
  noc_if t01_n1_e_in (), t01_n1_e_out (), t01_n1_w_in (), t01_n1_w_out ();
  // Tile (1,1)
  noc_if t11_n0_n_in (), t11_n0_n_out (), t11_n0_s_in (), t11_n0_s_out ();
  noc_if t11_n0_e_in (), t11_n0_e_out (), t11_n0_w_in (), t11_n0_w_out ();
  noc_if t11_n1_n_in (), t11_n1_n_out (), t11_n1_s_in (), t11_n1_s_out ();
  noc_if t11_n1_e_in (), t11_n1_e_out (), t11_n1_w_in (), t11_n1_w_out ();
  // Tile (2,0) DRAM tile
  noc_if t20_n0_n_in (), t20_n0_n_out (), t20_n0_s_in (), t20_n0_s_out ();
  noc_if t20_n0_e_in (), t20_n0_e_out (), t20_n0_w_in (), t20_n0_w_out ();
  noc_if t20_n1_n_in (), t20_n1_n_out (), t20_n1_s_in (), t20_n1_s_out ();
  noc_if t20_n1_e_in (), t20_n1_e_out (), t20_n1_w_in (), t20_n1_w_out ();

  // ────────────────────────────────────────────────────────────────
  // Edge wiring between neighbours
  // ────────────────────────────────────────────────────────────────
`define WIRE_EDGE(out_if, in_if) \
  assign in_if.valid        = out_if.valid; \
  assign in_if.dst_x        = out_if.dst_x; \
  assign in_if.dst_y        = out_if.dst_y; \
  assign in_if.local_addr   = out_if.local_addr; \
  assign in_if.is_write     = out_if.is_write; \
  assign in_if.is_multicast = out_if.is_multicast; \
  assign in_if.length       = out_if.length; \
  assign in_if.data         = out_if.data; \
  assign in_if.data_valid   = out_if.data_valid; \
  assign out_if.ready       = in_if.ready; \
  assign out_if.data_ready  = in_if.data_ready;

  // East ↔ West: (0,0) ↔ (1,0)
  `WIRE_EDGE(t00_n0_e_out, t10_n0_w_in)
  `WIRE_EDGE(t10_n0_w_out, t00_n0_e_in)
  `WIRE_EDGE(t00_n1_e_out, t10_n1_w_in)
  `WIRE_EDGE(t10_n1_w_out, t00_n1_e_in)
  // East ↔ West: (0,1) ↔ (1,1)
  `WIRE_EDGE(t01_n0_e_out, t11_n0_w_in)
  `WIRE_EDGE(t11_n0_w_out, t01_n0_e_in)
  `WIRE_EDGE(t01_n1_e_out, t11_n1_w_in)
  `WIRE_EDGE(t11_n1_w_out, t01_n1_e_in)
  // North ↔ South: (0,0) ↔ (0,1)
  `WIRE_EDGE(t00_n0_n_out, t01_n0_s_in)
  `WIRE_EDGE(t01_n0_s_out, t00_n0_n_in)
  `WIRE_EDGE(t00_n1_n_out, t01_n1_s_in)
  `WIRE_EDGE(t01_n1_s_out, t00_n1_n_in)
  // North ↔ South: (1,0) ↔ (1,1)
  `WIRE_EDGE(t10_n0_n_out, t11_n0_s_in)
  `WIRE_EDGE(t11_n0_s_out, t10_n0_n_in)
  `WIRE_EDGE(t10_n1_n_out, t11_n1_s_in)
  `WIRE_EDGE(t11_n1_s_out, t10_n1_n_in)
  // East ↔ West: (1,0) compute ↔ (2,0) DRAM
  `WIRE_EDGE(t10_n0_e_out, t20_n0_w_in)
  `WIRE_EDGE(t20_n0_w_out, t10_n0_e_in)
  `WIRE_EDGE(t10_n1_e_out, t20_n1_w_in)
  `WIRE_EDGE(t20_n1_w_out, t10_n1_e_in)

`undef WIRE_EDGE

  // ────────────────────────────────────────────────────────────────
  // Chip-boundary tie-offs (no torus wrap)
  // ────────────────────────────────────────────────────────────────
`define TIE_BOUNDARY(if_in, if_out) \
  assign if_in.valid       = 1'b0; \
  assign if_in.data_valid  = 1'b0; \
  assign if_out.ready      = 1'b1; \
  assign if_out.data_ready = 1'b1;

  // Top edge (y=1, north boundary)
  `TIE_BOUNDARY(t01_n0_n_in, t01_n0_n_out)
  `TIE_BOUNDARY(t11_n0_n_in, t11_n0_n_out)
  `TIE_BOUNDARY(t01_n1_n_in, t01_n1_n_out)
  `TIE_BOUNDARY(t11_n1_n_in, t11_n1_n_out)
  // Bottom edge (y=0, south boundary)
  `TIE_BOUNDARY(t00_n0_s_in, t00_n0_s_out)
  `TIE_BOUNDARY(t10_n0_s_in, t10_n0_s_out)
  `TIE_BOUNDARY(t00_n1_s_in, t00_n1_s_out)
  `TIE_BOUNDARY(t10_n1_s_in, t10_n1_s_out)
  // Right edge (x=1 column is interior now that (2,0) DRAM tile exists,
  // so only (1,1) is on the boundary). (2,0)'s east/north/south are the
  // new right edge.
  `TIE_BOUNDARY(t11_n0_e_in, t11_n0_e_out)
  `TIE_BOUNDARY(t11_n1_e_in, t11_n1_e_out)
  `TIE_BOUNDARY(t20_n0_e_in, t20_n0_e_out)
  `TIE_BOUNDARY(t20_n0_n_in, t20_n0_n_out)
  `TIE_BOUNDARY(t20_n0_s_in, t20_n0_s_out)
  `TIE_BOUNDARY(t20_n1_e_in, t20_n1_e_out)
  `TIE_BOUNDARY(t20_n1_n_in, t20_n1_n_out)
  `TIE_BOUNDARY(t20_n1_s_in, t20_n1_s_out)
  // Left edge (x=0, west boundary)
  `TIE_BOUNDARY(t00_n0_w_in, t00_n0_w_out)
  `TIE_BOUNDARY(t01_n0_w_in, t01_n0_w_out)
  `TIE_BOUNDARY(t00_n1_w_in, t00_n1_w_out)
  `TIE_BOUNDARY(t01_n1_w_in, t01_n1_w_out)

`undef TIE_BOUNDARY

  // ────────────────────────────────────────────────────────────────
  // Tile (0,0): host
  // ────────────────────────────────────────────────────────────────
  ktc_host_tile #(
    .MY_X (0),
    .MY_Y (0)
  ) u_host (
    .clk            (clk),
    .rst_n          (rst_n),
    .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awready  (s_axi_awready),
    .s_axi_awaddr   (s_axi_awaddr),
    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wready   (s_axi_wready),
    .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),
    .s_axi_bvalid   (s_axi_bvalid),
    .s_axi_bready   (s_axi_bready),
    .s_axi_bresp    (s_axi_bresp),
    .s_axi_arvalid  (s_axi_arvalid),
    .s_axi_arready  (s_axi_arready),
    .s_axi_araddr   (s_axi_araddr),
    .s_axi_rvalid   (s_axi_rvalid),
    .s_axi_rready   (s_axi_rready),
    .s_axi_rdata    (s_axi_rdata),
    .s_axi_rresp    (s_axi_rresp),
    .noc0_north_in (t00_n0_n_in), .noc0_north_out (t00_n0_n_out),
    .noc0_south_in (t00_n0_s_in), .noc0_south_out (t00_n0_s_out),
    .noc0_east_in  (t00_n0_e_in), .noc0_east_out  (t00_n0_e_out),
    .noc0_west_in  (t00_n0_w_in), .noc0_west_out  (t00_n0_w_out),
    .noc1_north_in (t00_n1_n_in), .noc1_north_out (t00_n1_n_out),
    .noc1_south_in (t00_n1_s_in), .noc1_south_out (t00_n1_s_out),
    .noc1_east_in  (t00_n1_e_in), .noc1_east_out  (t00_n1_e_out),
    .noc1_west_in  (t00_n1_w_in), .noc1_west_out  (t00_n1_w_out)
  );

  // ────────────────────────────────────────────────────────────────
  // Compute tiles: (1,0), (0,1), (1,1)
  // ────────────────────────────────────────────────────────────────
  ktc_tile_top #(
    .TILE_X (1),
    .TILE_Y (0)
  ) u_tile10 (
    .clk          (clk),
    .rst_n        (rst_n),
    .tile_reset_n (tile_reset_n),
    .noc0_north_in (t10_n0_n_in), .noc0_north_out (t10_n0_n_out),
    .noc0_south_in (t10_n0_s_in), .noc0_south_out (t10_n0_s_out),
    .noc0_east_in  (t10_n0_e_in), .noc0_east_out  (t10_n0_e_out),
    .noc0_west_in  (t10_n0_w_in), .noc0_west_out  (t10_n0_w_out),
    .noc1_north_in (t10_n1_n_in), .noc1_north_out (t10_n1_n_out),
    .noc1_south_in (t10_n1_s_in), .noc1_south_out (t10_n1_s_out),
    .noc1_east_in  (t10_n1_e_in), .noc1_east_out  (t10_n1_e_out),
    .noc1_west_in  (t10_n1_w_in), .noc1_west_out  (t10_n1_w_out)
  );

  ktc_tile_top #(
    .TILE_X (0),
    .TILE_Y (1)
  ) u_tile01 (
    .clk          (clk),
    .rst_n        (rst_n),
    .tile_reset_n (tile_reset_n),
    .noc0_north_in (t01_n0_n_in), .noc0_north_out (t01_n0_n_out),
    .noc0_south_in (t01_n0_s_in), .noc0_south_out (t01_n0_s_out),
    .noc0_east_in  (t01_n0_e_in), .noc0_east_out  (t01_n0_e_out),
    .noc0_west_in  (t01_n0_w_in), .noc0_west_out  (t01_n0_w_out),
    .noc1_north_in (t01_n1_n_in), .noc1_north_out (t01_n1_n_out),
    .noc1_south_in (t01_n1_s_in), .noc1_south_out (t01_n1_s_out),
    .noc1_east_in  (t01_n1_e_in), .noc1_east_out  (t01_n1_e_out),
    .noc1_west_in  (t01_n1_w_in), .noc1_west_out  (t01_n1_w_out)
  );

  ktc_tile_top #(
    .TILE_X (1),
    .TILE_Y (1)
  ) u_tile11 (
    .clk          (clk),
    .rst_n        (rst_n),
    .tile_reset_n (tile_reset_n),
    .noc0_north_in (t11_n0_n_in), .noc0_north_out (t11_n0_n_out),
    .noc0_south_in (t11_n0_s_in), .noc0_south_out (t11_n0_s_out),
    .noc0_east_in  (t11_n0_e_in), .noc0_east_out  (t11_n0_e_out),
    .noc0_west_in  (t11_n0_w_in), .noc0_west_out  (t11_n0_w_out),
    .noc1_north_in (t11_n1_n_in), .noc1_north_out (t11_n1_n_out),
    .noc1_south_in (t11_n1_s_in), .noc1_south_out (t11_n1_s_out),
    .noc1_east_in  (t11_n1_e_in), .noc1_east_out  (t11_n1_e_out),
    .noc1_west_in  (t11_n1_w_in), .noc1_west_out  (t11_n1_w_out)
  );

  // ────────────────────────────────────────────────────────────────
  // Tile (2,0): DRAM endpoint
  // ────────────────────────────────────────────────────────────────
  ktc_dram_tile #(
    .MY_X    (2),
    .MY_Y    (0),
    .BACKEND (DRAM_BACKEND)
  ) u_dram (
    .clk           (clk),
    .rst_n         (rst_n),
    .noc0_north_in (t20_n0_n_in), .noc0_north_out (t20_n0_n_out),
    .noc0_south_in (t20_n0_s_in), .noc0_south_out (t20_n0_s_out),
    .noc0_east_in  (t20_n0_e_in), .noc0_east_out  (t20_n0_e_out),
    .noc0_west_in  (t20_n0_w_in), .noc0_west_out  (t20_n0_w_out),
    .noc1_north_in (t20_n1_n_in), .noc1_north_out (t20_n1_n_out),
    .noc1_south_in (t20_n1_s_in), .noc1_south_out (t20_n1_s_out),
    .noc1_east_in  (t20_n1_e_in), .noc1_east_out  (t20_n1_e_out),
    .noc1_west_in  (t20_n1_w_in), .noc1_west_out  (t20_n1_w_out),
    .m_axi_awvalid (m_axi_dram_awvalid),
    .m_axi_awready (m_axi_dram_awready),
    .m_axi_awid    (m_axi_dram_awid),
    .m_axi_awaddr  (m_axi_dram_awaddr),
    .m_axi_awlen   (m_axi_dram_awlen),
    .m_axi_awsize  (m_axi_dram_awsize),
    .m_axi_awburst (m_axi_dram_awburst),
    .m_axi_wvalid  (m_axi_dram_wvalid),
    .m_axi_wready  (m_axi_dram_wready),
    .m_axi_wdata   (m_axi_dram_wdata),
    .m_axi_wstrb   (m_axi_dram_wstrb),
    .m_axi_wlast   (m_axi_dram_wlast),
    .m_axi_bvalid  (m_axi_dram_bvalid),
    .m_axi_bready  (m_axi_dram_bready),
    .m_axi_bid     (m_axi_dram_bid),
    .m_axi_bresp   (m_axi_dram_bresp),
    .m_axi_arvalid (m_axi_dram_arvalid),
    .m_axi_arready (m_axi_dram_arready),
    .m_axi_arid    (m_axi_dram_arid),
    .m_axi_araddr  (m_axi_dram_araddr),
    .m_axi_arlen   (m_axi_dram_arlen),
    .m_axi_arsize  (m_axi_dram_arsize),
    .m_axi_arburst (m_axi_dram_arburst),
    .m_axi_rvalid  (m_axi_dram_rvalid),
    .m_axi_rready  (m_axi_dram_rready),
    .m_axi_rid     (m_axi_dram_rid),
    .m_axi_rdata   (m_axi_dram_rdata),
    .m_axi_rresp   (m_axi_dram_rresp),
    .m_axi_rlast   (m_axi_dram_rlast)
  );

endmodule
