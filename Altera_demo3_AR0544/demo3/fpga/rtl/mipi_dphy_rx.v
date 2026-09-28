//=====================================================================
// mipi_dphy_rx.v -- 4-lane MIPI D-PHY receive front end
//
// Arria II GX has no hard D-PHY. Each lane arrives twice:
//   * as an LVDS pair into ALTLVDS_RX for the HS burst
//   * as two LVCMOS inputs (lp_p / lp_n) for LP state detection
// That is exactly the "both single-ended and differential signalling"
// note in EVBUM2310/D.
//
// LP states:  LP-11 stop  LP-01 HS-request  LP-00 bridge -> HS burst
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module mipi_dphy_rx #(
   parameter LANES = 4
) (
   input  wire              rx_byte_clk,     // ALTLVDS_RX outclock
   input  wire              rst_n,

   // link pins
   input  wire              clk_lp_p,
   input  wire              clk_lp_n,
   input  wire [LANES-1:0]  lp_p,
   input  wire [LANES-1:0]  lp_n,
   input  wire [LANES*8-1:0] lvds_word,      // from ALTLVDS_RX
   input  wire [LANES-1:0]  dpa_locked,
   output wire [LANES-1:0]  chan_data_align, // -> ALTLVDS_RX

   // control
   input  wire [2:0]        num_lanes_m1,    // 0..3
   input  wire              align_req,

   // merged byte stream, rx_byte_clk domain
   output reg  [`RXW-1:0]   m_data,
   output reg  [`RXBE-1:0]  m_be,
   output reg               m_valid,
   output reg               m_sot,           // start of HS burst
   output reg               m_eot,           // end   of HS burst

   output wire [LANES-1:0]  lane_aligned,
   output wire              clk_lane_stop    // clock lane in LP-11
);

   //---------------------------------------------------------------
   // LP state decode. Synchronise the LP pins into the byte clock;
   // they are slow (<10 MHz) so a 2-flop synchroniser is enough.
   //---------------------------------------------------------------
   wire [LANES-1:0] s_lp_p, s_lp_n;
   wire [1:0]       s_clk_lp;

   cdc_sync #(LANES) u_sp (.clk(rx_byte_clk), .rst_n(rst_n), .d(lp_p), .q(s_lp_p));
   cdc_sync #(LANES) u_sn (.clk(rx_byte_clk), .rst_n(rst_n), .d(lp_n), .q(s_lp_n));
   cdc_sync #(2)     u_sc (.clk(rx_byte_clk), .rst_n(rst_n),
                           .d({clk_lp_p, clk_lp_n}), .q(s_clk_lp));

   assign clk_lane_stop = &s_clk_lp;            // LP-11

   // lane 0 drives burst framing for the whole link
   wire lp11_0 =  s_lp_p[0] &  s_lp_n[0];
   wire lp00_0 = ~s_lp_p[0] & ~s_lp_n[0];

   reg hs_active, hs_active_d;
   always @(posedge rx_byte_clk or negedge rst_n) begin
      if (!rst_n) begin
         hs_active   <= 1'b0;
         hs_active_d <= 1'b0;
      end else begin
         if      (lp00_0) hs_active <= 1'b1;    // LP-00 bridge -> HS
         else if (lp11_0) hs_active <= 1'b0;    // back to stop state
         hs_active_d <= hs_active;
      end
   end

   //---------------------------------------------------------------
   // Per-lane word alignment
   //---------------------------------------------------------------
   wire [7:0] lane_byte  [0:LANES-1];
   wire       lane_valid [0:LANES-1];

   genvar g;
   generate
      for (g = 0; g < LANES; g = g + 1) begin : G_LANE
         wire lane_en = (g <= num_lanes_m1);
         mipi_lane_align u_al (
            .clk        (rx_byte_clk),
            .rst_n      (rst_n),
            .hs_active  (hs_active & lane_en & dpa_locked[g]),
            .align_req  (align_req),
            .din        (lvds_word[g*8 +: 8]),
            .slip       (chan_data_align[g]),
            .aligned    (lane_aligned[g]),
            .dout       (lane_byte[g]),
            .dout_valid (lane_valid[g])
         );
      end
   endgenerate

   //---------------------------------------------------------------
   // Lane merge. CSI-2 distributes bytes round-robin across lanes, so
   // with L lanes we emit L bytes per byte-clock, lane 0 first.
   //---------------------------------------------------------------
   integer i;
   reg [`RXBE-1:0] be_mask;
   always @(*) begin
      be_mask = {`RXBE{1'b0}};
      for (i = 0; i < LANES; i = i + 1)
         if (i <= num_lanes_m1) be_mask[i] = 1'b1;
   end

   always @(posedge rx_byte_clk or negedge rst_n) begin
      if (!rst_n) begin
         m_data <= {`RXW{1'b0}}; m_be <= {`RXBE{1'b0}};
         m_valid <= 1'b0; m_sot <= 1'b0; m_eot <= 1'b0;
      end else begin
         m_sot <= hs_active & ~hs_active_d;
         m_eot <= ~hs_active & hs_active_d;

         for (i = 0; i < LANES; i = i + 1)
            m_data[i*8 +: 8] <= lane_valid[i] ? lane_byte[i] : 8'h00;

         m_be    <= be_mask & {lane_valid[3], lane_valid[2],
                               lane_valid[1], lane_valid[0]};
         m_valid <= lane_valid[0];   // lane 0 always carries the first byte
      end
   end
endmodule
