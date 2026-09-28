//=====================================================================
// hispi_rx.v -- HiSPi receiver (Streaming-S / Streaming-SP / Packetized-SP)
//
// Four differential data lanes plus one DDR clock lane, deserialised by
// ALTLVDS_RX at J = bit depth. Sync codes are held in registers rather
// than hard-coded, because they differ between the three HiSPi
// protocols and between sensor families.
// [VERIFY] Load R_HISPI_SYNC0/1 with the codes from your sensor's
// HiSPi section before enabling this receiver.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module hispi_rx #(
   parameter LANES = 4,
   parameter J     = 12                 // deserialisation factor = word width
) (
   input  wire                 rx_word_clk,
   input  wire                 rst_n,
   input  wire [LANES*J-1:0]   lvds_word,
   input  wire [LANES-1:0]     dpa_locked,
   output wire [LANES-1:0]     chan_data_align,

   input  wire                 align_req,
   input  wire [3:0]           bitdepth,
   input  wire [11:0]          sync_sof,
   input  wire [11:0]          sync_sol,
   input  wire [11:0]          sync_eof,
   input  wire [11:0]          sync_eol,

   output reg  [4*`PIXW-1:0]   m_px,
   output reg  [3:0]           m_valid,
   output reg                  ev_frame_start,
   output reg                  ev_frame_end,
   output reg                  ev_line_start,
   output reg                  ev_line_end,
   output wire [LANES-1:0]     lane_aligned
);
   // ---- per-lane word alignment against the 3-word sync preamble ----
   // HiSPi prefixes every sync code with all-ones words; hunt for that.
   localparam [J-1:0] PREAMBLE = {J{1'b1}};

   reg  [LANES-1:0] aligned_r;
   reg  [2:0]       gap [0:LANES-1];
   reg  [LANES-1:0] slip_r;
   assign chan_data_align = slip_r;
   assign lane_aligned    = aligned_r;

   integer L;
   always @(posedge rx_word_clk or negedge rst_n) begin
      if (!rst_n) begin
         aligned_r <= {LANES{1'b0}};
         slip_r    <= {LANES{1'b0}};
         for (L = 0; L < LANES; L = L + 1) gap[L] <= 3'd0;
      end else begin
         slip_r <= {LANES{1'b0}};
         for (L = 0; L < LANES; L = L + 1) begin
            if (align_req) begin
               aligned_r[L] <= 1'b0;
            end else if (!aligned_r[L] && dpa_locked[L]) begin
               if (lvds_word[L*J +: J] == PREAMBLE) begin
                  aligned_r[L] <= 1'b1;
                  gap[L]       <= 3'd0;
               end else if (gap[L] == 3'd4) begin
                  slip_r[L] <= 1'b1;
                  gap[L]    <= 3'd0;
               end else begin
                  gap[L] <= gap[L] + 1'b1;
               end
            end
         end
      end
   end

   // ---- sync code detection on lane 0 ----
   wire [J-1:0] w0 = lvds_word[0 +: J];
   wire [11:0]  w0e = {{(12-J){1'b0}}, w0};
   reg  [1:0]   pre_cnt;
   reg          in_line;

   always @(posedge rx_word_clk or negedge rst_n) begin
      if (!rst_n) begin
         pre_cnt <= 2'd0; in_line <= 1'b0;
         ev_frame_start <= 1'b0; ev_frame_end <= 1'b0;
         ev_line_start  <= 1'b0; ev_line_end  <= 1'b0;
         m_px <= {4*`PIXW{1'b0}}; m_valid <= 4'd0;
      end else begin
         ev_frame_start <= 1'b0; ev_frame_end <= 1'b0;
         ev_line_start  <= 1'b0; ev_line_end  <= 1'b0;
         m_valid        <= 4'd0;

         if (!(&aligned_r)) begin
            pre_cnt <= 2'd0; in_line <= 1'b0;
         end else if (w0 == PREAMBLE) begin
            if (pre_cnt != 2'd3) pre_cnt <= pre_cnt + 1'b1;
            m_valid <= 4'd0;
         end else if (pre_cnt == 2'd3) begin
            pre_cnt <= 2'd0;
            if      (w0e == sync_sof) begin ev_frame_start <= 1'b1; in_line <= 1'b1; end
            else if (w0e == sync_sol) begin ev_line_start  <= 1'b1; in_line <= 1'b1; end
            else if (w0e == sync_eol) begin ev_line_end    <= 1'b1; in_line <= 1'b0; end
            else if (w0e == sync_eof) begin ev_frame_end   <= 1'b1; in_line <= 1'b0; end
         end else begin
            pre_cnt <= 2'd0;
            if (in_line) begin
               m_px <= { {(`PIXW-J){1'b0}}, lvds_word[3*J +: J],
                         {(`PIXW-J){1'b0}}, lvds_word[2*J +: J],
                         {(`PIXW-J){1'b0}}, lvds_word[1*J +: J],
                         {(`PIXW-J){1'b0}}, lvds_word[0*J +: J] };
               m_valid <= 4'b1111;
            end
         end
      end
   end

   // bitdepth is consumed downstream by the DPCM stage / formatter
   wire _unused_bd = |bitdepth;
endmodule
