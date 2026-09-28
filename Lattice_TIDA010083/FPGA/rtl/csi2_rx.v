//=====================================================================
// csi2_rx.v - MIPI CSI-2 receive path for the AR0234CS.
//
//   dphy_rx_wrap  : shim over the LIFCL-40 hardened D-PHY quad
//   csi2_ecc      : packet-header Hamming ECC
//   csi2_crc16    : payload CRC-16
//   csi2_pkt      : packet decoder, 4 bytes/clock
//   raw10_unpack  : RAW10/RAW8 -> 4 pixels/clock
//   csi2_rx       : the three above wired together
//
// The datapath is 4 pixels wide because the sensor produces
// 1920*1200*120 = 276.5 Mpixel/s. One pixel per clock would need a
// ~300 MHz ISP, which will not close on this device. At 4 px/clock the
// ISP runs below 80 MHz.
//
// Verilog-2001.
//=====================================================================
`timescale 1ns/1ps
`default_nettype none
`include "cam_defs.vh"

//---------------------------------------------------------------------
// dphy_rx_wrap
//
// The hardened D-PHY is a Lattice primitive, not user RTL. Generate it
// in Radiant (Clarity Designer -> "MIPI DPHY") and connect it here.
// This wrapper fixes the interface the rest of the design sees so that
// the hard macro can be swapped for the simulation model below.
//
// Hard-IP ports on CrossLink-NX (names as emitted by Radiant):
//   clk_byte_o        -> byte clock, = lane rate / 8
//   bd_o[31:0]        -> 4 lanes x 8 bits, lane0 in [7:0]
//   bd_en_o           -> byte-data valid
//   pd_dphy_i         -> power down
//   lm_i / ls_i       -> lane management / status
//   cd_o, sp_en_o, lp_en_o, ... -> control/short/long packet side-band
// Only the raw byte stream is used here; packet parsing is done in
// fabric so that the same RTL works with a soft D-PHY on the HP banks.
//---------------------------------------------------------------------
module dphy_rx_wrap #(parameter SIM_MODEL = 0) (
    input  wire        pd_dphy,          // 1 = power down the PHY
    // ---- to the hardened macro (leave unconnected when SIM_MODEL=1)
    input  wire        hard_byte_clk,
    input  wire [31:0] hard_byte_data,
    input  wire        hard_byte_valid,
    input  wire        hard_sync,        // SoT detected on lane 0
    // ---- fabric side
    output wire        byte_clk,
    output wire [31:0] byte_data,
    output wire        byte_valid,
    output wire        byte_sync
);
    assign byte_clk   = hard_byte_clk;
    assign byte_data  = pd_dphy ? 32'h0 : hard_byte_data;
    assign byte_valid = pd_dphy ? 1'b0  : hard_byte_valid;
    assign byte_sync  = pd_dphy ? 1'b0  : hard_sync;
endmodule

//---------------------------------------------------------------------
// csi2_ecc - 6-bit Hamming over the 24-bit packet header.
//
// WARNING: the parity equations below are the commonly published set.
// The MIPI CSI-2 specification is the normative source and is not
// public. Verify this table against the specification before tape-out.
// Because of that uncertainty the decoder never drops a packet on an
// ECC mismatch - it only raises err_o, which the register file counts.
//---------------------------------------------------------------------
module csi2_ecc (
    input  wire [23:0] d,
    input  wire [7:0]  ecc_in,
    output wire [7:0]  ecc_calc,
    output wire        err
);
    wire p0 = ^(d & 24'b1111_0000_0001_0110_1011_0111);
    wire p1 = ^(d & 24'b1111_0000_0010_1011_0101_1011);
    wire p2 = ^(d & 24'b0111_0001_0100_1100_1110_1101);
    wire p3 = ^(d & 24'b1011_1000_1110_0011_1000_1110);
    wire p4 = ^(d & 24'b1101_1111_0000_0011_1111_0000);
    wire p5 = ^(d & 24'b1110_1111_1111_1100_0000_0000);

    assign ecc_calc = {2'b00, p5, p4, p3, p2, p1, p0};
    assign err      = (ecc_calc != ecc_in);
endmodule

//---------------------------------------------------------------------
// csi2_crc16 - x^16 + x^12 + x^5 + 1, init 0xFFFF, LSB-first per byte.
// Processes up to four bytes per clock under a byte-enable mask.
//---------------------------------------------------------------------
module csi2_crc16 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,
    input  wire        en,
    input  wire [31:0] data,      // byte 0 in [7:0]
    input  wire [3:0]  ben,
    output reg  [15:0] crc
);
    function [15:0] crc_byte;
        input [15:0] c;
        input [7:0]  b;
        integer i;
        reg   [15:0] t;
        begin
            t = c;
            for (i = 0; i < 8; i = i + 1)
                if ((t[0] ^ b[i]) == 1'b1) t = (t >> 1) ^ 16'h8408;
                else                       t = (t >> 1);
            crc_byte = t;
        end
    endfunction

    reg [15:0] c0, c1, c2, c3;
    always @(*) begin
        c0 = ben[0] ? crc_byte(crc, data[7:0])   : crc;
        c1 = ben[1] ? crc_byte(c0,  data[15:8])  : c0;
        c2 = ben[2] ? crc_byte(c1,  data[23:16]) : c1;
        c3 = ben[3] ? crc_byte(c2,  data[31:24]) : c2;
    end

    always @(posedge clk or negedge rst_n)
        if (!rst_n)   crc <= 16'hFFFF;
        else if (init) crc <= 16'hFFFF;
        else if (en)   crc <= c3;
endmodule

//---------------------------------------------------------------------
// csi2_pkt - packet decoder. Consumes 4 bytes per byte-clock.
//---------------------------------------------------------------------
module csi2_pkt (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] bd,
    input  wire        bd_en,
    input  wire        sync,
    input  wire [1:0]  cfg_vc,        // virtual channel to accept

    output reg  [31:0] pay_data,      // long-packet payload, 4 bytes
    output reg  [3:0]  pay_ben,
    output reg         pay_vld,
    output reg  [5:0]  pay_dt,

    output reg         frame_start,
    output reg         frame_end,
    output reg         line_start,
    output reg         line_end,
    output reg  [15:0] frame_num,

    output reg         err_ecc,
    output reg         err_crc
);
    localparam S_IDLE = 2'd0, S_HDR = 2'd1, S_PAY = 2'd2, S_CRC = 2'd3;

    reg [1:0]  st;
    reg [15:0] wc;          // bytes remaining in the payload
    reg [1:0]  vc;
    reg [5:0]  dt;

    wire [7:0] di   = bd[7:0];
    wire [7:0] wc_l = bd[15:8];
    wire [7:0] wc_h = bd[23:16];
    wire [7:0] ecc  = bd[31:24];

    wire       ecc_err;
    csi2_ecc u_ecc (.d(bd[23:0]), .ecc_in(ecc), .ecc_calc(), .err(ecc_err));

    wire is_long = (di[5:0] >= 6'h10);
    wire vc_ok   = (di[7:6] == cfg_vc);

    // CRC over the payload
    reg         crc_init, crc_en;
    reg  [31:0] crc_dat;
    reg  [3:0]  crc_ben;
    wire [15:0] crc_val;
    csi2_crc16 u_crc (.clk(clk), .rst_n(rst_n), .init(crc_init), .en(crc_en),
                      .data(crc_dat), .ben(crc_ben), .crc(crc_val));

    wire [3:0] ben_full = 4'hF;
    wire [3:0] ben_tail = (wc == 16'd1) ? 4'h1 :
                          (wc == 16'd2) ? 4'h3 :
                          (wc == 16'd3) ? 4'h7 : 4'hF;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; wc <= 16'd0; vc <= 2'd0; dt <= 6'd0;
            pay_data <= 32'd0; pay_ben <= 4'd0; pay_vld <= 1'b0; pay_dt <= 6'd0;
            frame_start <= 1'b0; frame_end <= 1'b0;
            line_start  <= 1'b0; line_end  <= 1'b0;
            frame_num   <= 16'd0;
            err_ecc <= 1'b0; err_crc <= 1'b0;
            crc_init <= 1'b0; crc_en <= 1'b0; crc_dat <= 32'd0; crc_ben <= 4'd0;
        end else begin
            pay_vld     <= 1'b0;
            frame_start <= 1'b0; frame_end <= 1'b0;
            line_start  <= 1'b0; line_end  <= 1'b0;
            err_ecc     <= 1'b0; err_crc   <= 1'b0;
            crc_init    <= 1'b0; crc_en    <= 1'b0;

            case (st)
            //---------------------------------------------------------
            S_IDLE: if (sync) st <= S_HDR;

            //---------------------------------------------------------
            S_HDR: if (bd_en) begin
                err_ecc <= ecc_err;
                if (!vc_ok) begin
                    st <= S_IDLE;                 // not our virtual channel
                end else if (is_long) begin
                    wc       <= {wc_h, wc_l};
                    dt       <= di[5:0];
                    vc       <= di[7:6];
                    crc_init <= 1'b1;
                    st       <= ({wc_h, wc_l} == 16'd0) ? S_CRC : S_PAY;
                end else begin
                    case (di[5:0])
                        `CSI_DT_FS: begin
                            frame_start <= 1'b1;
                            frame_num   <= {wc_h, wc_l};
                        end
                        `CSI_DT_FE: frame_end  <= 1'b1;
                        `CSI_DT_LS: line_start <= 1'b1;
                        `CSI_DT_LE: line_end   <= 1'b1;
                        default: ;
                    endcase
                    st <= S_IDLE;
                end
            end

            //---------------------------------------------------------
            S_PAY: if (bd_en) begin
                pay_data <= bd;
                pay_ben  <= (wc >= 16'd4) ? ben_full : ben_tail;
                pay_dt   <= dt;
                pay_vld  <= 1'b1;

                crc_dat <= bd;
                crc_ben <= (wc >= 16'd4) ? ben_full : ben_tail;
                crc_en  <= 1'b1;

                if (wc <= 16'd4) begin wc <= 16'd0; st <= S_CRC; end
                else             wc <= wc - 16'd4;
            end

            //---------------------------------------------------------
            S_CRC: if (bd_en) begin
                // The received CRC is little-endian in the first 2 bytes.
                err_crc <= (crc_val != bd[15:0]);
                st      <= S_IDLE;
            end
            endcase
        end
    end
endmodule

//---------------------------------------------------------------------
// raw10_unpack - RAW10 (5 bytes -> 4 pixels) or RAW8 (1 byte -> 1 px).
// Consumes 4 bytes/clock, emits 4 pixels/clock. RAW10 therefore has a
// valid duty cycle of 4/5; RAW8 is 1/1 with the pixels left-shifted.
//---------------------------------------------------------------------
module raw10_unpack (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,             // drop state at line start

    input  wire [31:0] in_data,
    input  wire [3:0]  in_ben,
    input  wire        in_vld,
    input  wire        in_raw8,           // 1 = RAW8, 0 = RAW10

    output reg  [39:0] px_data,           // 4 x 10 bit, pixel 0 in [9:0]
    output reg  [3:0]  px_ben,
    output reg         px_vld
);
    // Byte accumulator: up to 12 bytes.
    reg [95:0] acc;
    reg [3:0]  cnt;                        // bytes held, 0..12

    wire [2:0] in_n = in_ben[3] ? 3'd4 : in_ben[2] ? 3'd3 :
                      in_ben[1] ? 3'd2 : in_ben[0] ? 3'd1 : 3'd0;

    wire take = in_vld && (cnt <= 4'd8);

    // RAW10: pixel k = {byte[k], lsb_byte[2k+1 : 2k]}
    wire [7:0] b0 = acc[7:0];
    wire [7:0] b1 = acc[15:8];
    wire [7:0] b2 = acc[23:16];
    wire [7:0] b3 = acc[31:24];
    wire [7:0] b4 = acc[39:32];

    wire [39:0] px10 = { b3, b4[7:6], b2, b4[5:4], b1, b4[3:2], b0, b4[1:0] };
    wire [39:0] px8  = { b3, 2'b00,   b2, 2'b00,   b1, 2'b00,   b0, 2'b00   };

    wire have10 = (cnt >= 4'd5);
    wire have8  = (cnt >= 4'd4);
    wire emit   = in_raw8 ? have8 : have10;
    wire [2:0] used = in_raw8 ? 3'd4 : 3'd5;

    reg [95:0] acc_n;
    reg [3:0]  cnt_n;

    always @(*) begin
        acc_n = acc;
        cnt_n = cnt;
        if (emit) begin
            acc_n = acc_n >> (8 * used);
            cnt_n = cnt_n - used;
        end
        if (take) begin
            acc_n = acc_n | ({64'd0, in_data} << (8 * cnt_n));
            cnt_n = cnt_n + in_n;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= 96'd0; cnt <= 4'd0;
            px_data <= 40'd0; px_ben <= 4'd0; px_vld <= 1'b0;
        end else if (flush) begin
            acc <= 96'd0; cnt <= 4'd0; px_vld <= 1'b0;
        end else begin
            acc     <= acc_n;
            cnt     <= cnt_n;
            px_vld  <= emit;
            px_data <= in_raw8 ? px8 : px10;
            px_ben  <= 4'hF;
        end
    end
endmodule

//---------------------------------------------------------------------
// csi2_rx - top of the receive path.
//---------------------------------------------------------------------
module csi2_rx (
    input  wire        clk,               // D-PHY byte clock
    input  wire        rst_n,
    input  wire [31:0] bd,
    input  wire        bd_en,
    input  wire        sync,
    input  wire [1:0]  cfg_vc,
    input  wire        cfg_raw8,

    output wire [39:0] px_data,
    output wire [3:0]  px_ben,
    output wire        px_vld,
    output wire        px_sof,
    output wire        px_eof,
    output wire        px_sol,
    output wire        px_eol,
    output wire [15:0] frame_num,
    output wire        err_ecc,
    output wire        err_crc
);
    wire [31:0] pay_d;
    wire [3:0]  pay_b;
    wire        pay_v;
    wire [5:0]  pay_dt;

    csi2_pkt u_pkt (
        .clk(clk), .rst_n(rst_n), .bd(bd), .bd_en(bd_en), .sync(sync),
        .cfg_vc(cfg_vc),
        .pay_data(pay_d), .pay_ben(pay_b), .pay_vld(pay_v), .pay_dt(pay_dt),
        .frame_start(px_sof), .frame_end(px_eof),
        .line_start(px_sol),  .line_end(px_eol),
        .frame_num(frame_num),
        .err_ecc(err_ecc), .err_crc(err_crc)
    );

    wire is_img = (pay_dt == `CSI_DT_RAW10) || (pay_dt == `CSI_DT_RAW8);

    raw10_unpack u_unp (
        .clk(clk), .rst_n(rst_n), .flush(px_sol),
        .in_data(pay_d), .in_ben(pay_b), .in_vld(pay_v && is_img),
        .in_raw8(cfg_raw8),
        .px_data(px_data), .px_ben(px_ben), .px_vld(px_vld)
    );
endmodule

`default_nettype wire
