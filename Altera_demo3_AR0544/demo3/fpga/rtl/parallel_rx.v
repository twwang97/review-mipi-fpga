//=====================================================================
// parallel_rx.v -- 10/12-bit parallel sensor interface
//   S_DATA[15:0], S_FRAME_VALID, S_LINE_VALID, S_PIXCLK  (P5 pins)
//   Receiver switches between driven and high-Z asynchronously under
//   pin or register control.  [EVBUM2310/D]
//
// Capture is on the sensor's own pixel clock; the arbiter FIFO does the
// crossing into the 150 MHz core clock.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module parallel_rx (
   input  wire         pixclk,          // S_PIXCLK, already on a clock network
   input  wire         rst_n,
   input  wire [15:0]  s_data,
   input  wire         s_fv,
   input  wire         s_lv,

   input  wire         cfg_fv_pol,      // 1 = active low
   input  wire         cfg_lv_pol,
   input  wire [3:0]   cfg_bitdepth,    // 10 or 12

   output reg  [4*`PIXW-1:0] m_px,
   output reg  [3:0]         m_valid,
   output reg                ev_frame_start,
   output reg                ev_frame_end,
   output reg                ev_line_start,
   output reg                ev_line_end
);
   wire fv = s_fv ^ cfg_fv_pol;
   wire lv = s_lv ^ cfg_lv_pol;

   reg fv_d, lv_d;
   reg [`PIXW-1:0] px;

   always @(*) begin
      case (cfg_bitdepth)
         4'd8:    px = {8'd0, s_data[7:0]};
         4'd10:   px = {6'd0, s_data[9:0]};
         4'd12:   px = {4'd0, s_data[11:0]};
         default: px = {2'd0, s_data[13:0]};
      endcase
   end

   always @(posedge pixclk or negedge rst_n) begin
      if (!rst_n) begin
         fv_d <= 1'b0; lv_d <= 1'b0;
         m_px <= {4*`PIXW{1'b0}}; m_valid <= 4'd0;
         ev_frame_start <= 1'b0; ev_frame_end <= 1'b0;
         ev_line_start  <= 1'b0; ev_line_end  <= 1'b0;
      end else begin
         fv_d <= fv; lv_d <= lv;
         ev_frame_start <=  fv & ~fv_d;
         ev_frame_end   <= ~fv &  fv_d;
         ev_line_start  <=  lv & ~lv_d;
         ev_line_end    <= ~lv &  lv_d;

         // one pixel per clock; sits in slot 0 of the 4-wide bus
         m_px    <= {{(3*`PIXW){1'b0}}, px};
         m_valid <= (fv && lv) ? 4'b0001 : 4'b0000;
      end
   end
endmodule
