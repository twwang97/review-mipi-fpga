//=====================================================================
// rgmii_mac.v - RGMII physical interface and a tri-speed MAC.
//
//   crc32_comb : reflected Ethernet FCS, one byte per call
//   ddr_in_x1  : IDDRX1F shim
//   ddr_out_x1 : ODDRX1F shim
//   rgmii_rx   : DDR capture, nibble assembly, 10/100/1000
//   rgmii_tx   : DDR launch, nibble split, 10/100/1000
//   mac_rx     : preamble strip, FCS check, byte stream out
//   mac_tx     : preamble insert, FCS append, inter-frame gap
//
// DDR I/O: compile with -DLATTICE_PRIM to instantiate the Nexus
// IDDRX1F / ODDRX1F primitives. Without it a behavioural model is used
// that simulates correctly but must NOT be synthesised - a
// combinational mux on the clock will glitch. Check the primitive port
// names against the Lattice Nexus library for your Radiant version.
//
// RGMII clock skew: this design assumes the DP83867 is placed in Shift
// mode over MDIO (RGMIICTL 0x0032, RGMIIDCTL 0x0086) and supplies the
// quarter-cycle skew itself. Do NOT also lengthen the clock trace by
// 1.5 ns on the carrier. Doing both double-shifts the clock; gigabit
// then fails while 100 Mb/s keeps working, which is a miserable bug to
// chase on a board you cannot probe.
//
// Verilog-2001.
//=====================================================================
`timescale 1ns/1ps
`default_nettype none

//---------------------------------------------------------------------
module crc32_comb (
    input  wire [31:0] crc_in,
    input  wire [7:0]  data,
    output wire [31:0] crc_out
);
    function [31:0] step;
        input [31:0] c;
        input [7:0]  d;
        integer i;
        reg [31:0] t;
        begin
            t = c ^ {24'd0, d};
            for (i = 0; i < 8; i = i + 1)
                t = t[0] ? ((t >> 1) ^ 32'hEDB88320) : (t >> 1);
            step = t;
        end
    endfunction
    assign crc_out = step(crc_in, data);
endmodule

//---------------------------------------------------------------------
module ddr_in_x1 (
    input  wire sclk, input wire rst, input wire d,
    output wire q_rise, output wire q_fall
);
`ifdef LATTICE_PRIM
    IDDRX1F u_i (.D(d), .SCLK(sclk), .RST(rst), .Q0(q_rise), .Q1(q_fall));
`else
    reg qr, qf;
    always @(posedge sclk) qr <= d;
    always @(negedge sclk) qf <= d;
    assign q_rise = qr;
    assign q_fall = qf;
`endif
endmodule

module ddr_out_x1 (
    input  wire sclk, input wire rst,
    input  wire d_rise, input wire d_fall,
    output wire q
);
`ifdef LATTICE_PRIM
    ODDRX1F u_o (.D0(d_rise), .D1(d_fall), .SCLK(sclk), .RST(rst), .Q(q));
`else
    assign q = sclk ? d_rise : d_fall;   // simulation only
`endif
endmodule

//---------------------------------------------------------------------
// rgmii_rx
//---------------------------------------------------------------------
module rgmii_rx (
    input  wire       rx_clk,
    input  wire       rst_n,
    input  wire [3:0] rgmii_rxd,
    input  wire       rgmii_rx_ctl,
    input  wire       speed_1g,

    output reg  [7:0] rx_data,
    output reg        rx_vld,
    output reg        rx_err
);
    wire rst = ~rst_n;
    wire [3:0] d_rise, d_fall;
    wire       c_rise, c_fall;

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_rxd
            ddr_in_x1 u_d (.sclk(rx_clk), .rst(rst), .d(rgmii_rxd[i]),
                           .q_rise(d_rise[i]), .q_fall(d_fall[i]));
        end
    endgenerate
    ddr_in_x1 u_ctl (.sclk(rx_clk), .rst(rst), .d(rgmii_rx_ctl),
                     .q_rise(c_rise), .q_fall(c_fall));

    // RX_CTL: rising edge = RX_DV, falling edge = RX_DV ^ RX_ER
    wire dv  = c_rise;
    wire err = c_rise ^ c_fall;

    reg       phase;
    reg [3:0] nib_lo;

    always @(posedge rx_clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_data <= 8'd0; rx_vld <= 1'b0; rx_err <= 1'b0;
            phase <= 1'b0; nib_lo <= 4'd0;
        end else if (speed_1g) begin
            rx_data <= {d_fall, d_rise};    // low nibble on the rising edge
            rx_vld  <= dv;
            rx_err  <= err;
            phase   <= 1'b0;
        end else begin
            rx_err <= err;
            if (!dv) begin
                phase <= 1'b0; rx_vld <= 1'b0;
            end else if (!phase) begin
                nib_lo <= d_rise; phase <= 1'b1; rx_vld <= 1'b0;
            end else begin
                rx_data <= {d_rise, nib_lo};
                rx_vld  <= 1'b1;
                phase   <= 1'b0;
            end
        end
    end
endmodule

//---------------------------------------------------------------------
// rgmii_tx
//---------------------------------------------------------------------
module rgmii_tx (
    input  wire       tx_clk,
    input  wire       rst_n,
    input  wire       speed_1g,

    input  wire [7:0] tx_data,
    input  wire       tx_en,
    input  wire       tx_er,
    output reg        tx_gate,          // 1 = a byte slot is open

    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_gtx_clk
);
    wire rst = ~rst_n;
    reg [3:0] d_rise, d_fall;
    reg       c_rise, c_fall;
    reg       phase;
    reg [7:0] hold;

    always @(posedge tx_clk or negedge rst_n) begin
        if (!rst_n) begin
            d_rise <= 4'd0; d_fall <= 4'd0;
            c_rise <= 1'b0; c_fall <= 1'b0;
            phase  <= 1'b0; hold   <= 8'd0; tx_gate <= 1'b1;
        end else if (speed_1g) begin
            d_rise  <= tx_data[3:0];
            d_fall  <= tx_data[7:4];
            c_rise  <= tx_en;
            c_fall  <= tx_en ^ tx_er;
            tx_gate <= 1'b1;
            phase   <= 1'b0;
        end else begin
            c_rise <= tx_en;
            c_fall <= tx_en ^ tx_er;
            if (!phase) begin
                hold    <= tx_data;
                d_rise  <= tx_data[3:0];
                d_fall  <= tx_data[3:0];   // duplicated on both edges
                phase   <= 1'b1;
                tx_gate <= 1'b0;
            end else begin
                d_rise  <= hold[7:4];
                d_fall  <= hold[7:4];
                phase   <= 1'b0;
                tx_gate <= 1'b1;
            end
        end
    end

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_txd
            ddr_out_x1 u_d (.sclk(tx_clk), .rst(rst),
                            .d_rise(d_rise[i]), .d_fall(d_fall[i]),
                            .q(rgmii_txd[i]));
        end
    endgenerate
    ddr_out_x1 u_ctl (.sclk(tx_clk), .rst(rst),
                      .d_rise(c_rise), .d_fall(c_fall), .q(rgmii_tx_ctl));
    ddr_out_x1 u_clk (.sclk(tx_clk), .rst(rst),
                      .d_rise(1'b1), .d_fall(1'b0), .q(rgmii_gtx_clk));
endmodule

//---------------------------------------------------------------------
// mac_rx - bytes pass through a 4-deep delay so the trailing FCS is
// never forwarded to the network stack.
//---------------------------------------------------------------------
module mac_rx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  rx_data,
    input  wire        rx_vld,
    input  wire        rx_err,

    output reg  [7:0]  f_data,
    output reg         f_vld,
    output reg         f_sof,
    output reg         f_eof,
    output reg         f_crc_ok,
    output reg  [15:0] err_cnt
);
    localparam M_IDLE = 2'd0, M_PRE = 2'd1, M_DATA = 2'd2;

    reg [1:0]  st;
    reg [31:0] crc;
    reg        errored, started;
    reg [2:0]  fill;
    reg [7:0]  d0, d1, d2, d3;

    wire [31:0] crc_nxt;
    crc32_comb u_c (.crc_in(crc), .data(rx_data), .crc_out(crc_nxt));

    wire good = (crc == 32'hDEBB20E3) && !errored;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= M_IDLE; crc <= 32'hFFFFFFFF;
            errored <= 1'b0; started <= 1'b0; fill <= 3'd0;
            d0 <= 8'd0; d1 <= 8'd0; d2 <= 8'd0; d3 <= 8'd0;
            f_data <= 8'd0; f_vld <= 1'b0; f_sof <= 1'b0; f_eof <= 1'b0;
            f_crc_ok <= 1'b0; err_cnt <= 16'd0;
        end else begin
            f_vld <= 1'b0; f_sof <= 1'b0; f_eof <= 1'b0;

            case (st)
            M_IDLE: begin
                crc     <= 32'hFFFFFFFF;
                errored <= 1'b0;
                started <= 1'b0;
                fill    <= 3'd0;
                if (rx_vld && (rx_data == 8'h55)) st <= M_PRE;
            end

            M_PRE: begin
                if (!rx_vld)               st <= M_IDLE;
                else if (rx_data == 8'hD5) st <= M_DATA;
                else if (rx_data != 8'h55) st <= M_IDLE;
            end

            M_DATA: begin
                if (rx_vld) begin
                    crc <= crc_nxt;
                    if (rx_err) errored <= 1'b1;
                    d3 <= d2; d2 <= d1; d1 <= d0; d0 <= rx_data;
                    if (fill != 3'd4) fill <= fill + 3'd1;
                    else begin
                        f_data  <= d3;
                        f_vld   <= 1'b1;
                        f_sof   <= ~started;
                        started <= 1'b1;
                    end
                end else begin
                    f_eof    <= started;
                    f_crc_ok <= good;
                    if (!good) err_cnt <= err_cnt + 16'd1;
                    st <= M_IDLE;
                end
            end
            endcase
        end
    end
endmodule

//---------------------------------------------------------------------
// mac_tx
//---------------------------------------------------------------------
module mac_tx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       gate,

    input  wire [7:0] f_data,
    input  wire       f_vld,
    input  wire       f_eof,
    output wire       f_rdy,

    output reg  [7:0] tx_data,
    output reg        tx_en,
    output reg        tx_er
);
    localparam T_IDLE = 3'd0, T_PRE = 3'd1, T_SFD = 3'd2,
               T_DATA = 3'd3, T_FCS = 3'd4, T_IFG = 3'd5;

    reg [2:0]  st;
    reg [3:0]  cnt;
    reg [31:0] crc;
    reg [31:0] fcs;

    wire [31:0] crc_nxt;
    crc32_comb u_c (.crc_in(crc), .data(f_data), .crc_out(crc_nxt));

    assign f_rdy = (st == T_DATA) && gate && f_vld;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= T_IDLE; cnt <= 4'd0; crc <= 32'hFFFFFFFF; fcs <= 32'd0;
            tx_data <= 8'd0; tx_en <= 1'b0; tx_er <= 1'b0;
        end else if (gate) begin
            case (st)
            T_IDLE: begin
                tx_en <= 1'b0; tx_er <= 1'b0;
                crc   <= 32'hFFFFFFFF;
                cnt   <= 4'd0;
                if (f_vld) st <= T_PRE;
            end

            T_PRE: begin
                tx_data <= 8'h55;
                tx_en   <= 1'b1;
                if (cnt == 4'd6) begin cnt <= 4'd0; st <= T_SFD; end
                else cnt <= cnt + 4'd1;
            end

            T_SFD: begin
                tx_data <= 8'hD5;
                st      <= T_DATA;
            end

            T_DATA: if (f_vld) begin
                tx_data <= f_data;
                tx_en   <= 1'b1;
                crc     <= crc_nxt;
                if (f_eof) begin
                    fcs <= ~crc_nxt;
                    cnt <= 4'd0;
                    st  <= T_FCS;
                end
            end

            T_FCS: begin
                tx_data <= fcs[7:0];
                fcs     <= {8'd0, fcs[31:8]};
                tx_en   <= 1'b1;
                if (cnt == 4'd3) begin cnt <= 4'd0; st <= T_IFG; end
                else cnt <= cnt + 4'd1;
            end

            T_IFG: begin
                tx_en   <= 1'b0;
                tx_data <= 8'd0;
                if (cnt == 4'd11) begin cnt <= 4'd0; st <= T_IDLE; end
                else cnt <= cnt + 4'd1;
            end
            endcase
        end
    end
endmodule

`default_nettype wire
