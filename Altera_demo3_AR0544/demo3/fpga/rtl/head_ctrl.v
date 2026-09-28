//=====================================================================
// head_ctrl.v -- headboard control plane (P5 side)
//
// Owns HEAD_RESET_L, the six SP general-control lines and the
// headboard power switch enable. On an AR0544 headboard the SP map is
//   SP0 -> TEST   SP1 -> GPIO0 (FLASH)   SP2 -> GPIO1 (SHUTTER)
//   SP3 -> GPI2   SP4 -> GPI3            SP5 -> XSHUTDOWN override
// [AR0544_CSP47_Demo3Head schematic]
//
// SP lines are bidirectional: driven when used as trigger/strap
// outputs, tri-stated and sampled when the sensor drives FLASH or
// SHUTTER back at us. The edge counters give the host a cheap way to
// confirm the sensor is actually strobing.
//=====================================================================
`timescale 1ns/1ps

module head_ctrl (
   input  wire        clk,
   input  wire        rst_n,

   // register controls
   input  wire        cfg_rst_n,          // level control of HEAD_RESET_L
   input  wire        cfg_rst_pulse,      // one-shot pulse request
   input  wire [31:0] cfg_rst_len,        // pulse length in core clocks
   input  wire        cfg_pwr_en,         // headboard power switch
   input  wire [5:0]  cfg_sp_out,
   input  wire [5:0]  cfg_sp_oe,
   input  wire [2:0]  cfg_trig_idx,
   input  wire        cfg_trig_fire,
   input  wire [15:0] cfg_trig_width,

   // pins
   output reg         head_reset_l,
   output wire [5:0]  sp_out,
   output wire [5:0]  sp_oe,
   input  wire [5:0]  sp_in,
   output reg         head_pwr_en,

   // status
   output reg  [5:0]  st_sp_in,
   output reg  [15:0] st_flash_cnt,
   output reg  [15:0] st_shutter_cnt,
   output reg         ev_flash,
   output reg         ev_shutter,
   output reg         st_rst_busy
);
   //------------------------------------------------------------- reset
   reg [31:0] rst_cnt;
   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         head_reset_l <= 1'b1;
         rst_cnt      <= 32'd0;
         st_rst_busy  <= 1'b0;
      end else if (cfg_rst_pulse && !st_rst_busy) begin
         head_reset_l <= 1'b0;
         rst_cnt      <= cfg_rst_len;
         st_rst_busy  <= 1'b1;
      end else if (st_rst_busy) begin
         if (rst_cnt == 32'd0) begin
            head_reset_l <= 1'b1;
            st_rst_busy  <= 1'b0;
         end else begin
            rst_cnt <= rst_cnt - 1'b1;
         end
      end else begin
         head_reset_l <= cfg_rst_n;
      end
   end

   always @(posedge clk or negedge rst_n)
      if (!rst_n) head_pwr_en <= 1'b0; else head_pwr_en <= cfg_pwr_en;

   //--------------------------------------------------------- SP outputs
   reg [15:0] trig_cnt;
   reg [5:0]  trig_mask;

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         trig_cnt <= 16'd0; trig_mask <= 6'd0;
      end else if (cfg_trig_fire && (trig_cnt == 16'd0)) begin
         trig_cnt  <= cfg_trig_width;
         trig_mask <= (6'd1 << cfg_trig_idx);
      end else if (trig_cnt != 16'd0) begin
         trig_cnt <= trig_cnt - 1'b1;
         if (trig_cnt == 16'd1) trig_mask <= 6'd0;
      end
   end

   assign sp_out = cfg_sp_out ^ trig_mask;   // trigger toggles the chosen line
   assign sp_oe  = cfg_sp_oe  | trig_mask;

   //--------------------------------------------------------- SP inputs
   wire [5:0] sp_sync;
   cdc_sync #(6) u_sp (.clk(clk), .rst_n(rst_n), .d(sp_in), .q(sp_sync));

   reg [5:0] sp_d;
   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         sp_d <= 6'd0; st_sp_in <= 6'd0;
         st_flash_cnt <= 16'd0; st_shutter_cnt <= 16'd0;
         ev_flash <= 1'b0; ev_shutter <= 1'b0;
      end else begin
         sp_d     <= sp_sync;
         st_sp_in <= sp_sync;
         // SP1 = GPIO0 = FLASH, SP2 = GPIO1 = SHUTTER (inputs when OE=0)
         ev_flash   <= ~cfg_sp_oe[1] & sp_sync[1] & ~sp_d[1];
         ev_shutter <= ~cfg_sp_oe[2] & sp_sync[2] & ~sp_d[2];
         if (~cfg_sp_oe[1] & sp_sync[1] & ~sp_d[1]) st_flash_cnt   <= st_flash_cnt   + 1'b1;
         if (~cfg_sp_oe[2] & sp_sync[2] & ~sp_d[2]) st_shutter_cnt <= st_shutter_cnt + 1'b1;
      end
   end
endmodule
