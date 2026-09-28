//=====================================================================
// dpcm_decode.v -- DPCM 10->8 expansion, table driven
//
// The AR0544 offers DPCM 10->8 compression on the MIPI link [DS]. The
// predictor and quantisation table are specified in the sensor's full
// (NDA) data sheet, so this block does NOT hard-code them. Instead it
// holds a 256-entry table that the host loads over R_DPCM_ADDR /
// R_DPCM_DATA, and applies:
//
//     pixel = clamp( predictor + table[code] )
//
// with the predictor being the previous pixel in the same colour plane
// (simple predictor). Set bypass when the sensor is not compressing.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module dpcm_decode (
   input  wire              clk,
   input  wire              rst_n,
   input  wire              bypass,
   input  wire              line_start,

   // table load port (control clock domain writes are synchronised
   // upstream; tbl_we is a single-cycle pulse in this domain)
   input  wire              tbl_we,
   input  wire [7:0]        tbl_addr,
   input  wire [15:0]       tbl_data,

   input  wire [4*`PIXW-1:0] s_px,
   input  wire [3:0]         s_valid,
   output reg  [4*`PIXW-1:0] m_px,
   output reg  [3:0]         m_valid
);
   reg signed [15:0] tbl [0:255];
   integer t;
   initial for (t = 0; t < 256; t = t + 1) tbl[t] = 16'sd0;

   always @(posedge clk)
      if (tbl_we) tbl[tbl_addr] <= tbl_data;

   // two predictors: even and odd colour planes of a Bayer line
   reg signed [16:0] pred_e, pred_o;

   function [15:0] clamp10;
      input signed [16:0] v;
      begin
         if (v < 0)                 clamp10 = 16'd0;
         else if (v > 17'sd1023)    clamp10 = 16'd1023;
         else                       clamp10 = v[15:0];
      end
   endfunction

   integer k;
   reg signed [16:0] acc;
   reg [4*`PIXW-1:0] out_px;

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         pred_e <= 17'sd0; pred_o <= 17'sd0;
         m_px <= {4*`PIXW{1'b0}}; m_valid <= 4'd0;
      end else if (bypass) begin
         m_px    <= s_px;
         m_valid <= s_valid;
      end else begin
         if (line_start) begin pred_e <= 17'sd0; pred_o <= 17'sd0; end
         out_px  = m_px;
         m_valid <= s_valid;
         for (k = 0; k < 4; k = k + 1) begin
            if (s_valid[k]) begin
               if (k[0] == 1'b0) begin
                  acc    = pred_e + {{1{tbl[s_px[k*`PIXW +: 8]][15]}}, tbl[s_px[k*`PIXW +: 8]]};
                  pred_e <= $signed({1'b0, clamp10(acc)});
               end else begin
                  acc    = pred_o + {{1{tbl[s_px[k*`PIXW +: 8]][15]}}, tbl[s_px[k*`PIXW +: 8]]};
                  pred_o <= $signed({1'b0, clamp10(acc)});
               end
               out_px[k*`PIXW +: `PIXW] = clamp10(acc);
            end
         end
         m_px <= out_px;
      end
   end
endmodule
