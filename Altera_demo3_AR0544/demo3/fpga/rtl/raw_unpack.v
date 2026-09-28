//=====================================================================
// raw_unpack.v -- RAW8/10/12/14 byte stream -> 16-bit pixel containers
//
// Bytes are accumulated into a staging buffer; one packing group is
// extracted per clock (RAW8: 1B->1px, RAW10: 5B->4px, RAW12: 3B->2px,
// RAW14: 7B->4px). Up to 4 pixels leave per clock, which keeps ahead of
// the 4 bytes/clock that a 4-lane link delivers.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module raw_unpack (
   input  wire              clk,
   input  wire              rst_n,
   input  wire [3:0]        bitdepth,     // 8, 10, 12 or 14

   input  wire [`RXW-1:0]   s_data,
   input  wire [`RXBE-1:0]  s_be,
   input  wire              s_valid,
   input  wire              s_flush,      // end of line/frame: drain buffer

   output reg  [4*`PIXW-1:0] m_px,
   output reg  [3:0]         m_valid
);
   localparam BUFB = 12;                  // staging buffer, bytes

   reg  [BUFB*8-1:0] buf_q;
   reg  [4:0]        buf_n;               // bytes currently in buf_q

   reg  [2:0] grp_bytes;
   reg  [2:0] grp_px;
   always @(*) begin
      case (bitdepth)
         4'd8:    begin grp_bytes = 3'd1; grp_px = 3'd1; end
         4'd10:   begin grp_bytes = 3'd5; grp_px = 3'd4; end
         4'd12:   begin grp_bytes = 3'd3; grp_px = 3'd2; end
         default: begin grp_bytes = 3'd7; grp_px = 3'd4; end   // RAW14
      endcase
   end

   integer i;
   reg [2:0]        inb;
   reg [BUFB*8-1:0] ins;
   reg [BUFB*8-1:0] nxt;
   reg [4:0]        nxt_n;

   // count and left-justify the incoming bytes into a shift value
   always @(*) begin
      inb = 3'd0;
      ins = {BUFB*8{1'b0}};
      for (i = 0; i < `RXBE; i = i + 1) begin
         if (s_be[i]) begin
            ins = ins | ({{(BUFB*8-8){1'b0}}, s_data[i*8 +: 8]} << (8*inb));
            inb = inb + 1'b1;
         end
      end
   end

   wire [7:0] b0 = buf_q[  7:  0];
   wire [7:0] b1 = buf_q[ 15:  8];
   wire [7:0] b2 = buf_q[ 23: 16];
   wire [7:0] b3 = buf_q[ 31: 24];
   wire [7:0] b4 = buf_q[ 39: 32];
   wire [7:0] b5 = buf_q[ 47: 40];
   wire [7:0] b6 = buf_q[ 55: 48];

   reg [`PIXW-1:0] p0, p1, p2, p3;
   always @(*) begin
      p0 = {`PIXW{1'b0}}; p1 = {`PIXW{1'b0}};
      p2 = {`PIXW{1'b0}}; p3 = {`PIXW{1'b0}};
      case (bitdepth)
      4'd8: begin
         p0 = {8'd0, b0};
      end
      4'd10: begin   // 4 pixels in 5 bytes, LSBs packed in byte 4
         p0 = {6'd0, b0, b4[1:0]};
         p1 = {6'd0, b1, b4[3:2]};
         p2 = {6'd0, b2, b4[5:4]};
         p3 = {6'd0, b3, b4[7:6]};
      end
      4'd12: begin   // 2 pixels in 3 bytes
         p0 = {4'd0, b0, b2[3:0]};
         p1 = {4'd0, b1, b2[7:4]};
      end
      default: begin // RAW14: 4 pixels in 7 bytes
         p0 = {2'd0, b0, b4[5:0]};
         p1 = {2'd0, b1, b4[7:6], b5[3:0]};
         p2 = {2'd0, b2, b5[7:4], b6[1:0]};
         p3 = {2'd0, b3, b6[7:2]};
      end
      endcase
   end

   wire have_group = (buf_n >= {2'd0, grp_bytes});

   always @(*) begin
      nxt   = buf_q;
      nxt_n = buf_n;
      if (s_valid) begin
         nxt   = buf_q | (ins << (8*buf_n));
         nxt_n = buf_n + {2'd0, inb};
      end
   end

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         buf_q <= {BUFB*8{1'b0}};
         buf_n <= 5'd0;
         m_px  <= {4*`PIXW{1'b0}};
         m_valid <= 4'd0;
      end else if (s_flush) begin
         buf_q   <= {BUFB*8{1'b0}};
         buf_n   <= 5'd0;
         m_valid <= 4'd0;
      end else begin
         m_valid <= 4'd0;
         if (have_group) begin
            m_px  <= {p3, p2, p1, p0};
            case (grp_px)
               3'd1: m_valid <= 4'b0001;
               3'd2: m_valid <= 4'b0011;
               default: m_valid <= 4'b1111;
            endcase
            buf_q <= nxt >> (8*grp_bytes);
            buf_n <= nxt_n - {2'd0, grp_bytes};
         end else begin
            buf_q <= nxt;
            buf_n <= nxt_n;
         end
      end
   end
endmodule
