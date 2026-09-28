//=====================================================================
// csi2_decoder.v -- MIPI CSI-2 packet decoder
//
// Consumes the merged byte stream from mipi_dphy_rx, validates the
// packet header ECC, separates short from long packets, checks the
// payload CRC-16 and emits framing events plus a raw payload stream.
//
// Supported lane counts: 1, 2, 4. The 4-byte packet header therefore
// always occupies a whole number of merged words, so payload always
// starts word-aligned.
//
// [VERIFY] The ECC parity equations and the CRC-16 polynomial below are
// from the MIPI CSI-2 specification. Check them against your copy of
// the spec before trusting silent error counters.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module csi2_decoder (
   input  wire              clk,
   input  wire              rst_n,

   // from mipi_dphy_rx
   input  wire [`RXW-1:0]   s_data,
   input  wire [`RXBE-1:0]  s_be,
   input  wire              s_valid,
   input  wire              s_sot,
   input  wire              s_eot,
   input  wire [2:0]        num_lanes_m1,

   // filtering
   input  wire              filter_en,
   input  wire [1:0]        filter_vc,
   input  wire [5:0]        filter_dt,

   // payload out
   output reg  [`RXW-1:0]   m_data,
   output reg  [`RXBE-1:0]  m_be,
   output reg               m_valid,
   output reg  [5:0]        m_dt,
   output reg  [1:0]        m_vc,

   // framing events (1-cycle pulses)
   output reg               ev_frame_start,
   output reg               ev_frame_end,
   output reg               ev_line_start,
   output reg               ev_line_end,
   output reg  [15:0]       frame_number,

   // error events
   output reg               err_ecc_corrected,
   output reg               err_ecc_uncorrectable,
   output reg               err_crc
);

   //------------------------------------------------------------------
   // CSI-2 packet header ECC: 6 parity bits over 24 data bits.
   //------------------------------------------------------------------
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

   //------------------------------------------------------------------
   // CRC-16, x^16 + x^12 + x^5 + 1, init 0xFFFF, LSB first.
   //------------------------------------------------------------------
   function [15:0] crc16_byte;
      input [15:0] c;
      input [7:0]  d;
      integer k;
      reg [15:0] r;
      reg fb;
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

   //------------------------------------------------------------------
   // Lane geometry
   //------------------------------------------------------------------
   reg [2:0] bytes_per_word;           // 1, 2 or 4
   always @(*) begin
      case (num_lanes_m1)
         3'd0:    bytes_per_word = 3'd1;
         3'd1:    bytes_per_word = 3'd2;
         default: bytes_per_word = 3'd4;
      endcase
   end

   localparam ST_IDLE    = 3'd0,
              ST_HEADER  = 3'd1,
              ST_PAYLOAD = 3'd2,
              ST_CRC     = 3'd3,
              ST_DRAIN   = 3'd4;

   reg [2:0]  st;
   reg [31:0] hdr;
   reg [2:0]  hdr_cnt;                 // bytes collected
   reg [15:0] wc;                      // word count from header
   reg [15:0] pay_left;                // payload bytes remaining
   reg [15:0] crc_acc;
   reg [15:0] crc_rx;
   reg [1:0]  crc_cnt;
   reg [5:0]  dt;
   reg [1:0]  vc;
   reg        pass;                    // this packet survives the VC/DT filter

   wire [23:0] hdr_d = hdr[23:0];
   wire [7:0]  hdr_p = hdr[31:24];
   wire [5:0]  ecc_calc = csi2_ecc(hdr_d);
   wire [5:0]  ecc_syn  = ecc_calc ^ hdr_p[5:0];
   wire        ecc_ok   = (ecc_syn == 6'd0);
   // A non-zero syndrome with an odd population is a correctable single-bit
   // error; anything else is reported as uncorrectable.
   wire        ecc_single = (^ecc_syn) & |ecc_syn;

   wire [5:0]  hdr_dt = hdr[5:0];
   wire [1:0]  hdr_vc = hdr[7:6];
   wire [15:0] hdr_wc = hdr[23:8];
   wire        is_short = (hdr_dt < 6'h10);

   integer b;
   reg [15:0] crc_next;
   reg [2:0]  nbytes;

   // how many valid bytes are in this beat
   always @(*) begin
      nbytes = 3'd0;
      for (b = 0; b < `RXBE; b = b + 1)
         if (s_be[b]) nbytes = nbytes + 1'b1;
   end

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         st <= ST_IDLE; hdr <= 32'd0; hdr_cnt <= 3'd0;
         wc <= 16'd0; pay_left <= 16'd0; crc_acc <= 16'hFFFF;
         crc_rx <= 16'd0; crc_cnt <= 2'd0; dt <= 6'd0; vc <= 2'd0;
         pass <= 1'b0; frame_number <= 16'd0;
         m_data <= {`RXW{1'b0}}; m_be <= {`RXBE{1'b0}}; m_valid <= 1'b0;
         m_dt <= 6'd0; m_vc <= 2'd0;
         ev_frame_start <= 1'b0; ev_frame_end <= 1'b0;
         ev_line_start  <= 1'b0; ev_line_end  <= 1'b0;
         err_ecc_corrected <= 1'b0; err_ecc_uncorrectable <= 1'b0;
         err_crc <= 1'b0;
      end else begin
         // default: all strobes low
         m_valid <= 1'b0; m_be <= {`RXBE{1'b0}};
         ev_frame_start <= 1'b0; ev_frame_end <= 1'b0;
         ev_line_start  <= 1'b0; ev_line_end  <= 1'b0;
         err_ecc_corrected <= 1'b0; err_ecc_uncorrectable <= 1'b0;
         err_crc <= 1'b0;

         if (s_eot) st <= ST_IDLE;

         case (st)
         //-----------------------------------------------------------
         ST_IDLE: begin
            hdr_cnt <= 3'd0;
            crc_acc <= 16'hFFFF;
            if (s_sot) st <= ST_HEADER;
            else if (s_valid) begin
               // burst already running (no SoT seen) -- collect anyway
               hdr <= {s_data, hdr} >> (8 * nbytes);
               hdr_cnt <= nbytes;
               st <= ST_HEADER;
            end
         end
         //-----------------------------------------------------------
         ST_HEADER: if (s_valid) begin
            // shift new bytes in from the top
            case (bytes_per_word)
               3'd1: hdr <= {s_data[7:0],   hdr[31:8]};
               3'd2: hdr <= {s_data[15:0],  hdr[31:16]};
               default: hdr <= s_data;
            endcase

            if ((hdr_cnt + bytes_per_word) >= 3'd4) begin
               hdr_cnt <= 3'd0;
               st <= ST_DRAIN;      // one cycle for hdr to settle, decided below
            end else begin
               hdr_cnt <= hdr_cnt + bytes_per_word;
            end
         end
         //-----------------------------------------------------------
         ST_DRAIN: begin
            // header register is now valid: classify it
            dt   <= hdr_dt;
            vc   <= hdr_vc;
            wc   <= hdr_wc;
            pass <= (!filter_en) ||
                    ((hdr_vc == filter_vc) && (hdr_dt == filter_dt)) ||
                    (hdr_dt < 6'h10);        // never filter out framing packets

            if (!ecc_ok) begin
               if (ecc_single) err_ecc_corrected     <= 1'b1;
               else            err_ecc_uncorrectable <= 1'b1;
            end

            if (!ecc_ok && !ecc_single) begin
               st <= ST_IDLE;                // unusable header, resync
            end else if (is_short) begin
               case (hdr_dt)
                  `DT_FS: begin ev_frame_start <= 1'b1; frame_number <= hdr_wc; end
                  `DT_FE: ev_frame_end   <= 1'b1;
                  `DT_LS: ev_line_start  <= 1'b1;
                  `DT_LE: ev_line_end    <= 1'b1;
                  default: ;
               endcase
               st <= ST_IDLE;
            end else begin
               pay_left <= hdr_wc;
               crc_acc  <= 16'hFFFF;
               st       <= (hdr_wc == 16'd0) ? ST_CRC : ST_PAYLOAD;
            end
         end
         //-----------------------------------------------------------
         ST_PAYLOAD: if (s_valid) begin
            crc_next = crc_acc;
            for (b = 0; b < `RXBE; b = b + 1)
               if (s_be[b] && (b < pay_left))
                  crc_next = crc16_byte(crc_next, s_data[b*8 +: 8]);
            crc_acc <= crc_next;

            m_data  <= s_data;
            m_dt    <= dt;
            m_vc    <= vc;
            if (pass) begin
               m_valid <= 1'b1;
               // mask off bytes beyond the payload length
               for (b = 0; b < `RXBE; b = b + 1)
                  m_be[b] <= s_be[b] && (b < pay_left);
            end

            if (pay_left <= {13'd0, nbytes}) begin
               pay_left <= 16'd0;
               crc_cnt  <= 2'd0;
               st       <= ST_CRC;
            end else begin
               pay_left <= pay_left - {13'd0, nbytes};
            end
         end
         //-----------------------------------------------------------
         ST_CRC: if (s_valid) begin
            // the two CRC bytes are the first two valid bytes here
            crc_rx <= {s_data[15:8], s_data[7:0]};
            if (crc_rx != crc_acc) err_crc <= 1'b1;
            st <= ST_IDLE;
         end
         //-----------------------------------------------------------
         default: st <= ST_IDLE;
         endcase
      end
   end
endmodule
