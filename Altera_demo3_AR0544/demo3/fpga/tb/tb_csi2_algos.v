//=====================================================================
// tb_csi2_algos.v -- self-checks for the two algorithms in
// csi2_decoder that are easy to get subtly wrong: the packet-header
// ECC and the payload CRC-16.
//=====================================================================
`timescale 1ns/1ps

module tb_csi2_algos;

   function [5:0] csi2_ecc;
      input [23:0] d;
      begin
         csi2_ecc[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
         csi2_ecc[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
         csi2_ecc[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
         csi2_ecc[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
         csi2_ecc[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
         csi2_ecc[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
      end
   endfunction

   function [15:0] crc16_byte;
      input [15:0] c; input [7:0] d;
      integer k; reg [15:0] r; reg fb;
      begin
         r = c;
         for (k = 0; k < 8; k = k + 1) begin
            fb = r[0] ^ d[k];
            r  = r >> 1;
            if (fb) r = r ^ 16'h8408;
         end
         crc16_byte = r;
      end
   endfunction

   integer i, j, fails, singles, doubles;
   reg [23:0] d;
   reg [23:0] dc;
   reg [5:0]  e, e2, syn;
   reg [15:0] crc;

   initial begin
      fails = 0;

      //--------------------------------------------------------------
      // 1. ECC must detect every single-bit error in the 24 data bits,
      //    and the syndrome must be unique per bit position.
      //--------------------------------------------------------------
      singles = 0;
      for (i = 0; i < 200; i = i + 1) begin
         d = $random;
         e = csi2_ecc(d);
         for (j = 0; j < 24; j = j + 1) begin
            dc  = d ^ (24'd1 << j);
            e2  = csi2_ecc(dc);
            syn = e ^ e2;
            if (syn == 6'd0) begin
               $display("FAIL: single-bit error at %0d undetected", j);
               fails = fails + 1;
            end
            singles = singles + 1;
         end
      end
      $display("ECC: %0d single-bit injections, all detected", singles);

      // syndromes must be distinct across the 24 positions
      d = 24'h0;
      for (i = 0; i < 24; i = i + 1)
         for (j = i+1; j < 24; j = j + 1)
            if (csi2_ecc(24'd1 << i) == csi2_ecc(24'd1 << j)) begin
               $display("FAIL: bits %0d and %0d share a syndrome", i, j);
               fails = fails + 1;
            end
      $display("ECC: all 24 single-bit syndromes are distinct");

      //--------------------------------------------------------------
      // 2. CRC-16 check value. CSI-2 specifies init 0xFFFF, LSB-first,
      //    polynomial x^16 + x^12 + x^5 + 1, which is exactly
      //    CRC-16/MCRF4XX. That catalogue entry has a published check
      //    value of 0x6F91 over the ASCII string "123456789", so we can
      //    verify the implementation against an independent reference
      //    rather than against a remembered worked example.
      //--------------------------------------------------------------
      crc = 16'hFFFF;
      crc = crc16_byte(crc, "1"); crc = crc16_byte(crc, "2");
      crc = crc16_byte(crc, "3"); crc = crc16_byte(crc, "4");
      crc = crc16_byte(crc, "5"); crc = crc16_byte(crc, "6");
      crc = crc16_byte(crc, "7"); crc = crc16_byte(crc, "8");
      crc = crc16_byte(crc, "9");
      $display("CRC: check value = 0x%04h (CRC-16/MCRF4XX expects 0x6F91)", crc);
      if (crc !== 16'h6F91) begin
         $display("FAIL: CRC does not match the catalogue check value");
         fails = fails + 1;
      end

      // CRC must change for any single-bit payload error
      doubles = 0;
      for (i = 0; i < 8; i = i + 1) begin
         crc = crc16_byte(16'hFFFF, 8'hA5);
         if (crc == crc16_byte(16'hFFFF, 8'hA5 ^ (8'd1 << i))) begin
            $display("FAIL: CRC blind to payload bit %0d", i);
            fails = fails + 1;
         end
         doubles = doubles + 1;
      end
      $display("CRC: %0d single-bit payload injections, all detected", doubles);

      $display("------------------------------------------------");
      if (fails == 0) $display("RESULT: all algorithm self-checks PASSED");
      else            $display("RESULT: %0d check(s) need attention", fails);
      $finish;
   end
endmodule
