//=====================================================================
// ccp_rx.v -- SMIA CCP2 single-lane receiver (data/strobe or data/clock)
// 8/10/12-bit raw, >= 640 Mbps.  [EVBUM2310/D]
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module ccp_rx (
   input  wire        rx_byte_clk,
   input  wire        rst_n,
   input  wire [7:0]  lvds_byte,        // ALTLVDS_RX, 1 channel, J = 8
   input  wire        dpa_locked,
   output reg         chan_data_align,
   input  wire        align_req,

   output reg  [`RXW-1:0]  m_data,
   output reg  [`RXBE-1:0] m_be,
   output reg              m_valid,
   output reg              ev_frame_start,
   output reg              ev_frame_end,
   output reg              ev_line_start,
   output reg              ev_line_end,
   output reg              aligned
);
   // CCP2 sync codes are a run of 0xFF followed by a code byte.
   localparam [7:0] PRE   = 8'hFF;
   localparam [7:0] C_SOF = 8'h01, C_EOF = 8'h02,
                    C_SOL = 8'h03, C_EOL = 8'h04;

   reg [2:0] gap;
   reg [1:0] pre_cnt;
   reg       in_line;

   always @(posedge rx_byte_clk or negedge rst_n) begin
      if (!rst_n) begin
         aligned <= 1'b0; gap <= 3'd0; chan_data_align <= 1'b0;
         pre_cnt <= 2'd0; in_line <= 1'b0;
         m_data <= {`RXW{1'b0}}; m_be <= {`RXBE{1'b0}}; m_valid <= 1'b0;
         ev_frame_start <= 1'b0; ev_frame_end <= 1'b0;
         ev_line_start  <= 1'b0; ev_line_end  <= 1'b0;
      end else begin
         chan_data_align <= 1'b0;
         m_valid <= 1'b0; m_be <= {`RXBE{1'b0}};
         ev_frame_start <= 1'b0; ev_frame_end <= 1'b0;
         ev_line_start  <= 1'b0; ev_line_end  <= 1'b0;

         if (align_req) aligned <= 1'b0;

         if (!aligned && dpa_locked) begin
            if (lvds_byte == PRE) begin aligned <= 1'b1; gap <= 3'd0; end
            else if (gap == 3'd4)  begin chan_data_align <= 1'b1; gap <= 3'd0; end
            else                          gap <= gap + 1'b1;
         end else if (aligned) begin
            if (lvds_byte == PRE) begin
               if (pre_cnt != 2'd3) pre_cnt <= pre_cnt + 1'b1;
            end else if (pre_cnt == 2'd3) begin
               pre_cnt <= 2'd0;
               case (lvds_byte)
                  C_SOF: begin ev_frame_start <= 1'b1; in_line <= 1'b1; end
                  C_SOL: begin ev_line_start  <= 1'b1; in_line <= 1'b1; end
                  C_EOL: begin ev_line_end    <= 1'b1; in_line <= 1'b0; end
                  C_EOF: begin ev_frame_end   <= 1'b1; in_line <= 1'b0; end
                  default: ;
               endcase
            end else begin
               pre_cnt <= 2'd0;
               if (in_line) begin
                  m_data  <= {24'd0, lvds_byte};
                  m_be    <= 4'b0001;
                  m_valid <= 1'b1;
               end
            end
         end
      end
   end
endmodule
