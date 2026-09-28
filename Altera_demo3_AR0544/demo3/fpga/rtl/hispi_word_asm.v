//=====================================================================
// hispi_word_asm.v -- byte stream -> N-bit HiSPi words
//
// The MIPI/HiSPi pins on P5 are one physical group, so there can only
// be one ALTLVDS_RX instance on them. It is fixed at J = 8 for MIPI,
// which means HiSPi's 10/12/14-bit words have to be regrouped in
// fabric. A one-bit slip per lane provides the word alignment that
// hispi_rx's preamble hunt asks for.
//=====================================================================
`timescale 1ns/1ps

module hispi_word_asm #(
   parameter LANES = 4,
   parameter J     = 12
) (
   input  wire                  clk,
   input  wire                  rst_n,
   input  wire [LANES*8-1:0]    s_byte,
   input  wire                  s_valid,
   input  wire [LANES-1:0]      slip,
   output reg  [LANES*J-1:0]    m_word,
   output reg                   m_valid
);
   reg [31:0] sh   [0:LANES-1];
   reg [5:0]  cnt  [0:LANES-1];

   integer L;
   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         for (L = 0; L < LANES; L = L + 1) begin
            sh[L]  <= 32'd0;
            cnt[L] <= 6'd0;
         end
         m_word  <= {LANES*J{1'b0}};
         m_valid <= 1'b0;
      end else begin
         m_valid <= 1'b0;

         for (L = 0; L < LANES; L = L + 1) begin
            if (slip[L]) begin
               // discard one bit to shift the word boundary
               sh[L]  <= {sh[L][30:0], 1'b0};
               cnt[L] <= (cnt[L] == 6'd0) ? 6'd0 : cnt[L] - 1'b1;
            end else if (s_valid) begin
               sh[L]  <= {sh[L][23:0], s_byte[L*8 +: 8]};
               cnt[L] <= cnt[L] + 6'd8;
            end
         end

         // lane 0 governs emission; all lanes stay locked together
         if (!slip[0] && s_valid && (cnt[0] + 6'd8) >= J[5:0]) begin
            for (L = 0; L < LANES; L = L + 1) begin
               m_word[L*J +: J] <= {sh[L][23:0], s_byte[L*8 +: 8]} >> ((cnt[L] + 6'd8) - J);
               cnt[L]           <= (cnt[L] + 6'd8) - J;
            end
            m_valid <= 1'b1;
         end
      end
   end
endmodule
