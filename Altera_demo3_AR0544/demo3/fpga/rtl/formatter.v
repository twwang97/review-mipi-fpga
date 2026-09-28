//=====================================================================
// formatter.v -- pixel stream -> 128-bit DDR3 words
//
// Eight 16-bit pixel containers make one 128-bit beat, matching the
// UniPHY local interface width. Frame boundaries force a flush so every
// frame starts on a beat boundary in memory.
//
// Container format is fixed 16-bit rather than bit-packed. That costs
// memory bandwidth (1.6x for RAW10) but the frame buffer has headroom:
// 400 Mpixel/s in versus the ~300 Mpixel/s a 5 MP/60 fps sensor
// produces. Set PACKED_MODE if you need the bandwidth back.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module formatter (
   input  wire        clk,
   input  wire        rst_n,
   input  wire        enable,

   input  wire [4*`PIXW-1:0] s_px,
   input  wire [3:0]  s_valid,
   input  wire        s_sof,
   input  wire        s_eof,
   input  wire        s_sol,
   input  wire        s_eol,
   output wire        s_ready,

   output reg  [`DDRW-1:0] m_data,
   output reg         m_valid,
   output reg         m_sof,
   output reg         m_eof,
   input  wire        m_ready,

   output reg  [31:0] pixel_count,
   output reg  [15:0] line_count
);
   reg [`DDRW-1:0] acc;
   reg [3:0]       fill;            // pixels currently in acc (0..8)
   reg             pend_sof, pend_eof;

   assign s_ready = m_ready | ~m_valid;

   integer i;
   reg [`DDRW-1:0] acc_n;
   reg [3:0]       fill_n;

   always @(*) begin
      acc_n  = acc;
      fill_n = fill;
      for (i = 0; i < 4; i = i + 1) begin
         if (s_valid[i] && (fill_n < 4'd8)) begin
            acc_n[fill_n*`PIXW +: `PIXW] = s_px[i*`PIXW +: `PIXW];
            fill_n = fill_n + 1'b1;
         end
      end
   end

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         acc <= {`DDRW{1'b0}}; fill <= 4'd0;
         m_data <= {`DDRW{1'b0}}; m_valid <= 1'b0;
         m_sof <= 1'b0; m_eof <= 1'b0;
         pend_sof <= 1'b0; pend_eof <= 1'b0;
         pixel_count <= 32'd0; line_count <= 16'd0;
      end else begin
         if (m_ready) m_valid <= 1'b0;

         if (!enable) begin
            fill <= 4'd0; acc <= {`DDRW{1'b0}};
            pend_sof <= 1'b0; pend_eof <= 1'b0;
         end else begin
            if (s_sof) begin
               pend_sof    <= 1'b1;
               pixel_count <= 32'd0;
               line_count  <= 16'd0;
               fill        <= 4'd0;
            end
            if (s_eol) line_count <= line_count + 1'b1;
            if (s_eof) pend_eof   <= 1'b1;

            pixel_count <= pixel_count + {28'd0, s_valid[0]} + {28'd0, s_valid[1]}
                                        + {28'd0, s_valid[2]} + {28'd0, s_valid[3]};

            if (s_ready) begin
               if (fill_n >= 4'd8) begin
                  m_data   <= acc_n;
                  m_valid  <= 1'b1;
                  m_sof    <= pend_sof;
                  m_eof    <= 1'b0;
                  pend_sof <= 1'b0;
                  acc      <= {`DDRW{1'b0}};
                  fill     <= 4'd0;
               end else if (pend_eof && (fill_n != 4'd0)) begin
                  // flush the partial beat at end of frame, zero padded
                  m_data   <= acc_n;
                  m_valid  <= 1'b1;
                  m_sof    <= pend_sof;
                  m_eof    <= 1'b1;
                  pend_sof <= 1'b0;
                  pend_eof <= 1'b0;
                  acc      <= {`DDRW{1'b0}};
                  fill     <= 4'd0;
               end else if (pend_eof) begin
                  m_eof    <= 1'b1;
                  m_valid  <= 1'b1;
                  pend_eof <= 1'b0;
                  acc      <= acc_n;
                  fill     <= fill_n;
               end else begin
                  acc  <= acc_n;
                  fill <= fill_n;
               end
            end
         end
      end
   end
endmodule
