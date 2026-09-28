//=====================================================================
// demo3_clk_rst.v -- clock generation, reset tree, MCLK output
//
// Vendor IP: ALTPLL  (altera_mf) x2
//   u_pll_core : 50 MHz board ref -> 150 MHz core, 100 MHz ctrl,
//                200 MHz ddr3 ref, 25..150 MHz HDMI pixel
//   u_pll_head : core -> MCLK generation reference
//
// The 50 MHz reference is the on-board oscillator feeding the FPGA.
// [INF] onsemi does not publish the board reference frequency; change
// REF_HZ and regenerate the PLL if yours differs.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module demo3_clk_rst (
   input  wire        ref_clk,        // board reference oscillator
   input  wire        por_n,          // power-on reset, active low

   output wire        clk_core,       // 150 MHz  -- main datapath
   output wire        clk_ctrl,       // 100 MHz  -- I2C/SPI/register plane
   output wire        clk_ddr_ref,    // ref into the UniPHY DDR3 controller
   output wire        clk_pix,        // HDMI pixel clock
   output wire        pll_locked,

   output wire        rst_core_n,
   output wire        rst_ctrl_n,
   output wire        rst_pix_n,

   // programmable master clock out to the headboard (P5 pin 44)
   input  wire        mclk_en,
   input  wire [15:0] mclk_div,       // MCLK = clk_core / (2*(div+1))
   output reg         head_mclk
);

   wire locked_core;

   //------------------------------------------------------------------
   // ALTPLL -- regenerate with MegaWizard for your exact reference.
   //------------------------------------------------------------------
   altpll_core u_pll_core (
      .inclk0 (ref_clk),
      .areset (~por_n),
      .c0     (clk_core),     // 150.000 MHz
      .c1     (clk_ctrl),     // 100.000 MHz
      .c2     (clk_ddr_ref),  // 200.000 MHz
      .c3     (clk_pix),      // 74.25 MHz (720p60/1080p60)
      .locked (locked_core)
   );

   assign pll_locked = locked_core;

   wire global_arst_n = por_n & locked_core;

   rst_sync u_rs_core (.clk(clk_core), .arst_n(global_arst_n), .srst_n(rst_core_n));
   rst_sync u_rs_ctrl (.clk(clk_ctrl), .arst_n(global_arst_n), .srst_n(rst_ctrl_n));
   rst_sync u_rs_pix  (.clk(clk_pix ), .arst_n(global_arst_n), .srst_n(rst_pix_n ));

   //------------------------------------------------------------------
   // MCLK divider. Headboards normally select their own oscillator
   // (AR0544 board: P20 1-3 = 20 MHz Y1), so this is optional. Route
   // through an ALTCLKCTRL if you need it on a global network.
   //------------------------------------------------------------------
   reg [15:0] mclk_cnt;
   always @(posedge clk_core or negedge rst_core_n) begin
      if (!rst_core_n) begin
         mclk_cnt  <= 16'd0;
         head_mclk <= 1'b0;
      end else if (!mclk_en) begin
         mclk_cnt  <= 16'd0;
         head_mclk <= 1'b0;
      end else if (mclk_cnt >= mclk_div) begin
         mclk_cnt  <= 16'd0;
         head_mclk <= ~head_mclk;
      end else begin
         mclk_cnt  <= mclk_cnt + 1'b1;
      end
   end

endmodule
