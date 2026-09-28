//=====================================================================
// mipi_lane_align.v -- per-lane word alignment for MIPI D-PHY HS bursts
//
// ALTLVDS_RX gives us J=8 bits per lane per outclock, but with an
// arbitrary bit phase. CSI-2 ends SoT with the sync byte 0xB8, so we
// issue bit-slip requests until 0xB8 appears, then declare the lane
// aligned and hold that slip for the rest of the burst.
//=====================================================================
`timescale 1ns/1ps

module mipi_lane_align (
   input  wire       clk,          // rx_outclock (bit rate / 8)
   input  wire       rst_n,
   input  wire       hs_active,    // LP-to-HS burst in progress
   input  wire       align_req,    // host forces a re-hunt
   input  wire [7:0] din,          // raw deserialised byte from ALTLVDS_RX
   output reg        slip,         // -> rx_channel_data_align (1 clk pulse)
   output reg        aligned,
   output reg  [7:0] dout,
   output reg        dout_valid
);
   localparam [7:0] SYNC_B8 = 8'hB8;
   localparam SLIP_GAP = 4;        // ALTLVDS_RX needs idle clocks between slips

   reg [2:0] gap;
   reg       hs_d;

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         slip <= 1'b0; aligned <= 1'b0; gap <= 3'd0;
         dout <= 8'd0; dout_valid <= 1'b0; hs_d <= 1'b0;
      end else begin
         slip       <= 1'b0;
         dout_valid <= 1'b0;
         hs_d       <= hs_active;

         // leaving HS: drop valid but keep the learned alignment
         if (!hs_active) begin
            if (align_req) aligned <= 1'b0;
         end
         // entering HS: if we were never aligned, start hunting
         else if (hs_active && !hs_d && align_req) begin
            aligned <= 1'b0;
         end

         if (hs_active) begin
            if (!aligned) begin
               if (din == SYNC_B8) begin
                  aligned <= 1'b1;          // sync found, consume it
                  gap     <= 3'd0;
               end else if (gap == SLIP_GAP[2:0]) begin
                  slip <= 1'b1;
                  gap  <= 3'd0;
               end else begin
                  gap <= gap + 1'b1;
               end
            end else begin
               dout       <= din;
               dout_valid <= 1'b1;
            end
         end
      end
   end
endmodule
