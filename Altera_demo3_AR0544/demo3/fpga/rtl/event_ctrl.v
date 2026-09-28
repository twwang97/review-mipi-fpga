//=====================================================================
// event_ctrl.v -- interrupt / event aggregator
//
// Demo3 has no interrupt pin to the host; events are latched here and
// polled by DevWare through the register plane, or pushed out over a
// GPIF II control pin. Every source is a one-cycle pulse in the core
// clock domain.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module event_ctrl (
   input  wire        clk,
   input  wire        rst_n,
   input  wire [31:0] ev,              // one-cycle pulses, bit per IRQ_*
   input  wire [31:0] ena,
   input  wire [31:0] force_set,
   input  wire [31:0] clr,             // write-1-to-clear from the register file
   input  wire        clr_stb,
   output reg  [31:0] status,
   output wire        irq
);
   integer i;
   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         status <= 32'd0;
      end else begin
         for (i = 0; i < 32; i = i + 1) begin
            if (clr_stb && clr[i])            status[i] <= 1'b0;
            else if (ev[i] || force_set[i])   status[i] <= 1'b1;
         end
      end
   end
   assign irq = |(status & ena);
endmodule
