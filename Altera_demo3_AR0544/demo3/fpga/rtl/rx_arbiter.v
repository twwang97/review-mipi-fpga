//=====================================================================
// rx_arbiter.v -- source select + clock-domain crossing into the core
//
// One DCFIFO per source clock domain. Only the selected receiver is
// clocked into its FIFO; the core-side mux picks which FIFO to drain.
// This is the "per-RX output FIFO moving data from the receiver clock
// to the 150 MHz FPGA core clock" described in EVBUM2310/D.
//
// Payload word: { eol, sol, eof, sof, valid[3:0], px3, px2, px1, px0 }
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module rx_arbiter (
   input  wire        clk_core,
   input  wire        rst_core_n,
   input  wire [1:0]  rx_sel,

   // ---- MIPI / CCP domain -------------------------------------------
   input  wire        mc_clk,
   input  wire        mc_rst_n,
   input  wire [4*`PIXW-1:0] mc_px,
   input  wire [3:0]  mc_valid,
   input  wire        mc_sof, input wire mc_eof,
   input  wire        mc_sol, input wire mc_eol,

   // ---- HiSPi domain ------------------------------------------------
   input  wire        hs_clk,
   input  wire        hs_rst_n,
   input  wire [4*`PIXW-1:0] hs_px,
   input  wire [3:0]  hs_valid,
   input  wire        hs_sof, input wire hs_eof,
   input  wire        hs_sol, input wire hs_eol,

   // ---- parallel domain ---------------------------------------------
   input  wire        pr_clk,
   input  wire        pr_rst_n,
   input  wire [4*`PIXW-1:0] pr_px,
   input  wire [3:0]  pr_valid,
   input  wire        pr_sof, input wire pr_eof,
   input  wire        pr_sol, input wire pr_eol,

   // ---- core side ----------------------------------------------------
   input  wire        m_ready,
   output reg  [4*`PIXW-1:0] m_px,
   output reg  [3:0]  m_valid,
   output reg         m_sof, output reg m_eof,
   output reg         m_sol, output reg m_eol,
   output wire        fifo_overflow,
   output wire        fifo_underflow
);
   localparam FW = 4*`PIXW + 4 + 4;      // 64 + 4 + 4 = 72
   localparam FD = 9;                    // 512 deep

   wire [FW-1:0] mc_w = {mc_eol, mc_sol, mc_eof, mc_sof, mc_valid, mc_px};
   wire [FW-1:0] hs_w = {hs_eol, hs_sol, hs_eof, hs_sof, hs_valid, hs_px};
   wire [FW-1:0] pr_w = {pr_eol, pr_sol, pr_eof, pr_sof, pr_valid, pr_px};

   wire mc_push = (|mc_valid) | mc_sof | mc_eof | mc_sol | mc_eol;
   wire hs_push = (|hs_valid) | hs_sof | hs_eof | hs_sol | hs_eol;
   wire pr_push = (|pr_valid) | pr_sof | pr_eof | pr_sol | pr_eol;

   wire sel_mc = (rx_sel == `SRC_MIPI) || (rx_sel == `SRC_CCP);
   wire sel_hs = (rx_sel == `SRC_HISPI);
   wire sel_pr = (rx_sel == `SRC_PAR);

   wire [FW-1:0] mc_q, hs_q, pr_q;
   wire mc_empty, hs_empty, pr_empty;
   wire mc_full,  hs_full,  pr_full;
   wire [FD-1:0] mc_used, hs_used, pr_used;
   wire [FD-1:0] mc_rused, hs_rused, pr_rused;

   wire aclr = ~rst_core_n;

   wire mc_pop = sel_mc & m_ready & ~mc_empty;
   wire hs_pop = sel_hs & m_ready & ~hs_empty;
   wire pr_pop = sel_pr & m_ready & ~pr_empty;

   dcfifo_wrap #(.W(FW), .DEPTH_LOG2(FD)) u_fifo_mc (
      .aclr(aclr),
      .wrclk(mc_clk), .wrreq(mc_push & sel_mc & ~mc_full), .data(mc_w),
      .wrfull(mc_full), .wrusedw(mc_used),
      .rdclk(clk_core), .rdreq(mc_pop), .q(mc_q), .rdempty(mc_empty),
      .rdusedw(mc_rused));

   dcfifo_wrap #(.W(FW), .DEPTH_LOG2(FD)) u_fifo_hs (
      .aclr(aclr),
      .wrclk(hs_clk), .wrreq(hs_push & sel_hs & ~hs_full), .data(hs_w),
      .wrfull(hs_full), .wrusedw(hs_used),
      .rdclk(clk_core), .rdreq(hs_pop), .q(hs_q), .rdempty(hs_empty),
      .rdusedw(hs_rused));

   dcfifo_wrap #(.W(FW), .DEPTH_LOG2(FD)) u_fifo_pr (
      .aclr(aclr),
      .wrclk(pr_clk), .wrreq(pr_push & sel_pr & ~pr_full), .data(pr_w),
      .wrfull(pr_full), .wrusedw(pr_used),
      .rdclk(clk_core), .rdreq(pr_pop), .q(pr_q), .rdempty(pr_empty),
      .rdusedw(pr_rused));

   // ---- overflow / underflow reporting, brought into the core domain --
   wire ovf_raw = (sel_mc & mc_full & mc_push) |
                  (sel_hs & hs_full & hs_push) |
                  (sel_pr & pr_full & pr_push);
   reg  ovf_lat_mc, ovf_lat_hs, ovf_lat_pr;
   always @(posedge mc_clk or negedge mc_rst_n)
      if (!mc_rst_n) ovf_lat_mc <= 1'b0; else if (mc_full & mc_push) ovf_lat_mc <= 1'b1;
   always @(posedge hs_clk or negedge hs_rst_n)
      if (!hs_rst_n) ovf_lat_hs <= 1'b0; else if (hs_full & hs_push) ovf_lat_hs <= 1'b1;
   always @(posedge pr_clk or negedge pr_rst_n)
      if (!pr_rst_n) ovf_lat_pr <= 1'b0; else if (pr_full & pr_push) ovf_lat_pr <= 1'b1;

   wire [2:0] ovf_sync;
   cdc_sync #(3) u_ovf (.clk(clk_core), .rst_n(rst_core_n),
                        .d({ovf_lat_pr, ovf_lat_hs, ovf_lat_mc}), .q(ovf_sync));
   assign fifo_overflow = |ovf_sync;

   reg unf;
   assign fifo_underflow = unf;

   // ---- core-side output mux -----------------------------------------
   reg [FW-1:0] q_mux;
   reg          q_vld;
   always @(*) begin
      case (rx_sel)
         `SRC_HISPI: begin q_mux = hs_q; q_vld = ~hs_empty; end
         `SRC_PAR:   begin q_mux = pr_q; q_vld = ~pr_empty; end
         default:    begin q_mux = mc_q; q_vld = ~mc_empty; end
      endcase
   end

   always @(posedge clk_core or negedge rst_core_n) begin
      if (!rst_core_n) begin
         m_px <= {4*`PIXW{1'b0}}; m_valid <= 4'd0;
         m_sof <= 1'b0; m_eof <= 1'b0; m_sol <= 1'b0; m_eol <= 1'b0;
         unf <= 1'b0;
      end else begin
         if (m_ready && q_vld) begin
            m_px    <= q_mux[4*`PIXW-1:0];
            m_valid <= q_mux[4*`PIXW+3 -: 4];
            m_sof   <= q_mux[4*`PIXW+4];
            m_eof   <= q_mux[4*`PIXW+5];
            m_sol   <= q_mux[4*`PIXW+6];
            m_eol   <= q_mux[4*`PIXW+7];
         end else begin
            m_valid <= 4'd0;
            m_sof <= 1'b0; m_eof <= 1'b0; m_sol <= 1'b0; m_eol <= 1'b0;
            if (m_ready && ovf_raw) unf <= 1'b1;
         end
      end
   end
endmodule
