//=====================================================================
// demo3_util.v -- small reusable primitives (Verilog-2001)
//=====================================================================
`timescale 1ns/1ps

// ---------------------------------------------------------------- CDC
// Two-flop level synchroniser. Constrain with set_false_path on .d.
module cdc_sync #(parameter W = 1, parameter INIT = 0) (
   input  wire         clk,
   input  wire         rst_n,
   input  wire [W-1:0] d,
   output wire [W-1:0] q
);
   reg [W-1:0] s0, s1;
   always @(posedge clk or negedge rst_n)
      if (!rst_n) begin s0 <= {W{INIT[0]}}; s1 <= {W{INIT[0]}}; end
      else        begin s0 <= d;            s1 <= s0;           end
   assign q = s1;
endmodule

// ------------------------------------------------------- pulse across CDC
// Toggle handshake: one src pulse -> one dst pulse. Src pulses must be
// separated by at least 3 dst clocks.
module pulse_sync (
   input  wire src_clk, input wire src_rst_n, input wire src_pulse,
   input  wire dst_clk, input wire dst_rst_n, output wire dst_pulse
);
   reg  tgl;
   wire [0:0] sync_q;
   reg  sync_d;
   always @(posedge src_clk or negedge src_rst_n)
      if (!src_rst_n) tgl <= 1'b0; else if (src_pulse) tgl <= ~tgl;
   cdc_sync #(1) u_s (.clk(dst_clk), .rst_n(dst_rst_n), .d(tgl), .q(sync_q));
   always @(posedge dst_clk or negedge dst_rst_n)
      if (!dst_rst_n) sync_d <= 1'b0; else sync_d <= sync_q[0];
   assign dst_pulse = sync_d ^ sync_q[0];
endmodule

// ------------------------------------------------------ reset synchroniser
module rst_sync (
   input  wire clk, input wire arst_n, output wire srst_n
);
   reg r0, r1;
   always @(posedge clk or negedge arst_n)
      if (!arst_n) begin r0 <= 1'b0; r1 <= 1'b0; end
      else         begin r0 <= 1'b1; r1 <= r0;   end
   assign srst_n = r1;
endmodule

// ------------------------------------------------------------ edge detect
module edge_det (
   input wire clk, input wire rst_n, input wire d,
   output wire rise, output wire fall
);
   reg q;
   always @(posedge clk or negedge rst_n) if (!rst_n) q <= 1'b0; else q <= d;
   assign rise =  d & ~q;
   assign fall = ~d &  q;
endmodule

// --------------------------------------------------- saturating event counter
module evt_counter #(parameter W = 16) (
   input  wire         clk, input wire rst_n,
   input  wire         clr, input wire inc,
   output reg  [W-1:0] cnt
);
   always @(posedge clk or negedge rst_n)
      if (!rst_n)                 cnt <= {W{1'b0}};
      else if (clr)               cnt <= {W{1'b0}};
      else if (inc && ~&cnt)      cnt <= cnt + 1'b1;
endmodule
