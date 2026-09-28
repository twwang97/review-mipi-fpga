//=====================================================================
// control.v - management and synchronisation.
//
//   mdio_master  : clause 22 plus MMD indirect for extended registers
//   phy_init     : DP83867 bring-up sequencer and link monitor
//   i2c_master   : two-wire master for the AR0234CS
//   sensor_init  : ROM-driven AR0234CS register script
//   ptp_clock    : 64-bit nanosecond timestamp with rate adjust
//   trigger_unit : isolated input capture -> sensor TRIGGER -> strobe
//   led_status   : link and streaming indicators
//
// Verilog-2001.
//=====================================================================
`timescale 1ns/1ps
`default_nettype none
`include "cam_defs.vh"

//---------------------------------------------------------------------
// mdio_master
//
// Clause 22 frame: ST(01) OP(10 rd / 01 wr) PHYAD(5) REGAD(5) TA(2)
// DATA(16). MDC is derived from clk by a programmable divider; the
// DP83867 accepts up to 25 MHz, and 2.5 MHz is used here for margin.
//---------------------------------------------------------------------
module mdio_master #(parameter DIV = 20) (      // 125 MHz / (2*20) ~ 3.1 MHz
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        op_rd,               // 1 = read, 0 = write
    input  wire [4:0]  phy_ad,
    input  wire [4:0]  reg_ad,
    input  wire [15:0] wdata,
    output reg  [15:0] rdata,
    output reg         busy,
    output reg         done,

    output reg         mdc,
    output wire        mdio_o,
    output wire        mdio_oe,
    input  wire        mdio_i
);
    reg [7:0]  div;
    reg        tick;                        // one clk pulse per MDC edge
    reg [6:0]  bit_i;
    reg [63:0] sh;
    reg        drive;
    reg        running;

    assign mdio_o  = sh[63];
    assign mdio_oe = drive;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin div <= 8'd0; tick <= 1'b0; mdc <= 1'b0; end
        else if (div == (DIV - 1)) begin
            div  <= 8'd0;
            mdc  <= ~mdc;
            tick <= 1'b1;
        end else begin
            div  <= div + 8'd1;
            tick <= 1'b0;
        end

    wire mdc_rise = tick && !mdc;           // mdc about to go high
    wire mdc_fall = tick &&  mdc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_i <= 7'd0; sh <= 64'd0; drive <= 1'b0; running <= 1'b0;
            busy <= 1'b0; done <= 1'b0; rdata <= 16'd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                // 32 preamble ones, then the 32-bit frame
                sh    <= {32'hFFFFFFFF, 2'b01, op_rd ? 2'b10 : 2'b01,
                          phy_ad, reg_ad, op_rd ? 2'b11 : 2'b10, wdata};
                bit_i   <= 7'd0;
                drive   <= 1'b1;
                busy    <= 1'b1;
                running <= 1'b1;
            end

            if (running && mdc_fall) begin
                // shift out on the falling edge so the PHY samples cleanly
                sh    <= {sh[62:0], 1'b1};
                bit_i <= bit_i + 7'd1;

                // release the bus for the turnaround of a read
                if (op_rd && (bit_i == 7'd46)) drive <= 1'b0;

                if (bit_i == 7'd63) begin
                    running <= 1'b0;
                    busy    <= 1'b0;
                    drive   <= 1'b0;
                    done    <= 1'b1;
                end
            end

            if (running && mdc_rise && op_rd && (bit_i >= 7'd48))
                rdata <= {rdata[14:0], mdio_i};
        end
    end
endmodule

//---------------------------------------------------------------------
// phy_init - DP83867 bring-up.
//
// Timing that must be respected and is easy to get wrong:
//   200 ms after power-up before the first MDC preamble
//   195 us after a hardware reset
// The 200 ms window starts when the rails come up, not when the FPGA
// finishes loading from flash, so the counter runs from the earliest
// reset release this design can observe.
//---------------------------------------------------------------------
module phy_init #(
    parameter CLK_HZ     = 125_000_000,
    parameter PHY_ADDR   = 5'd0,
    parameter TX_DELAY   = 4'd7,          // RGMIIDCTL: 0.25 ns steps
    parameter RX_DELAY   = 4'd7
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        phy_int_n,         // open drain from the PHY

    output reg         phy_reset_n,
    output reg         ready,
    output reg         link_up,
    output reg         speed_1g,
    output reg  [1:0]  speed,             // 00 = 10, 01 = 100, 10 = 1000
    output reg         full_duplex,
    output reg  [15:0] phy_status,

    output reg         md_start,
    output reg         md_op_rd,
    output reg  [4:0]  md_phy_ad,
    output reg  [4:0]  md_reg_ad,
    output reg  [15:0] md_wdata,
    input  wire [15:0] md_rdata,
    input  wire        md_busy,
    input  wire        md_done
);
    localparam T200MS = CLK_HZ / 5;                 // 200 ms
    localparam T195US = (CLK_HZ / 1_000_000) * 200; // 200 us, a little margin

    // DP83867 register addresses
    localparam R_BMCR   = 5'h00;
    localparam R_BMSR   = 5'h01;
    localparam R_PHYSTS = 5'h11;
    localparam R_MICR   = 5'h12;
    localparam R_ISR    = 5'h13;
    localparam R_REGCR  = 5'h0D;
    localparam R_ADDAR  = 5'h0E;

    localparam E_RGMIICTL  = 16'h0032;
    localparam E_RGMIIDCTL = 16'h0086;

    localparam P_WAIT = 5'd0,  P_RST_LO = 5'd1, P_RST_WAIT = 5'd2,
               P_A0 = 5'd3,  P_A1 = 5'd4,  P_A2 = 5'd5,  P_A3 = 5'd6,
               P_B0 = 5'd7,  P_B1 = 5'd8,  P_B2 = 5'd9,  P_B3 = 5'd10,
               P_MICR = 5'd11, P_ISR = 5'd12,
               P_IDLE = 5'd13, P_RD_STS = 5'd14, P_RD_ISR = 5'd15,
               P_ISSUE = 5'd16;

    reg [4:0]  st, st_after;
    reg [31:0] tmr;
    reg        int_q;
    wire       int_n_s;

    bit_sync #(.W(1), .INIT(1)) u_is (.clk(clk), .rst_n(rst_n),
                                      .d(phy_int_n), .q(int_n_s));

    // poll link every ~10 ms even if the interrupt is not wired
    localparam TPOLL = CLK_HZ / 100;

    task issue;
        input       rd;
        input [4:0] ra;
        input [15:0] wd;
        begin
            md_op_rd  <= rd;
            md_reg_ad <= ra;
            md_wdata  <= wd;
            md_start  <= 1'b1;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= P_WAIT; st_after <= P_WAIT; tmr <= 32'd0;
            phy_reset_n <= 1'b1; ready <= 1'b0;
            link_up <= 1'b0; speed_1g <= 1'b0; speed <= 2'd0;
            full_duplex <= 1'b0; phy_status <= 16'd0;
            md_start <= 1'b0; md_op_rd <= 1'b0; md_phy_ad <= PHY_ADDR;
            md_reg_ad <= 5'd0; md_wdata <= 16'd0; int_q <= 1'b1;
        end else begin
            md_start  <= 1'b0;
            md_phy_ad <= PHY_ADDR;
            int_q     <= int_n_s;

            case (st)
            //---- power-up window -------------------------------------
            P_WAIT: begin
                phy_reset_n <= 1'b1;
                if (tmr == T200MS) begin tmr <= 32'd0; st <= P_RST_LO; end
                else tmr <= tmr + 32'd1;
            end

            //---- optional hardware reset, >= 1 us --------------------
            P_RST_LO: begin
                phy_reset_n <= 1'b0;
                if (tmr == (CLK_HZ / 100_000)) begin   // 10 us
                    tmr <= 32'd0; st <= P_RST_WAIT;
                end else tmr <= tmr + 32'd1;
            end

            P_RST_WAIT: begin
                phy_reset_n <= 1'b1;
                if (tmr == T195US) begin tmr <= 32'd0; st <= P_A0; end
                else tmr <= tmr + 32'd1;
            end

            //---- RGMIICTL: enable TX and RX clock shift --------------
            // MMD indirect: REGCR=0x001F, ADDAR=reg, REGCR=0x401F, ADDAR=data
            P_A0: if (!md_busy) begin issue(1'b0, R_REGCR, 16'h001F);
                                      st_after <= P_A1; st <= P_ISSUE; end
            P_A1: if (!md_busy) begin issue(1'b0, R_ADDAR, E_RGMIICTL);
                                      st_after <= P_A2; st <= P_ISSUE; end
            P_A2: if (!md_busy) begin issue(1'b0, R_REGCR, 16'h401F);
                                      st_after <= P_A3; st <= P_ISSUE; end
            // bit 1 = RX clock delay enable, bit 0 = TX clock delay enable
            P_A3: if (!md_busy) begin issue(1'b0, R_ADDAR, 16'h0003);
                                      st_after <= P_B0; st <= P_ISSUE; end

            //---- RGMIIDCTL: delay magnitude, 0.25 ns per step --------
            P_B0: if (!md_busy) begin issue(1'b0, R_REGCR, 16'h001F);
                                      st_after <= P_B1; st <= P_ISSUE; end
            P_B1: if (!md_busy) begin issue(1'b0, R_ADDAR, E_RGMIIDCTL);
                                      st_after <= P_B2; st <= P_ISSUE; end
            P_B2: if (!md_busy) begin issue(1'b0, R_REGCR, 16'h401F);
                                      st_after <= P_B3; st <= P_ISSUE; end
            P_B3: if (!md_busy) begin
                      issue(1'b0, R_ADDAR, {8'd0, RX_DELAY, TX_DELAY});
                      st_after <= P_MICR; st <= P_ISSUE;
                  end

            //---- interrupt mask: link change + autoneg complete ------
            P_MICR: if (!md_busy) begin issue(1'b0, R_MICR, 16'h0C00);
                                        st_after <= P_ISR; st <= P_ISSUE; end

            //---- clear anything latched during bring-up --------------
            P_ISR: if (!md_busy) begin issue(1'b1, R_ISR, 16'd0);
                                       st_after <= P_IDLE; st <= P_ISSUE; end

            //---- steady state ---------------------------------------
            P_IDLE: begin
                ready <= 1'b1;
                if (!md_busy) begin
                    if (!int_n_s && int_q) begin          // falling edge
                        issue(1'b1, R_ISR, 16'd0);
                        st_after <= P_RD_STS; st <= P_ISSUE;
                    end else if (tmr == TPOLL) begin
                        tmr <= 32'd0;
                        issue(1'b1, R_PHYSTS, 16'd0);
                        st_after <= P_RD_STS; st <= P_ISSUE;
                    end else tmr <= tmr + 32'd1;
                end
            end

            P_RD_STS: if (!md_busy) begin
                          issue(1'b1, R_PHYSTS, 16'd0);
                          st_after <= P_RD_ISR; st <= P_ISSUE;
                      end

            P_RD_ISR: begin
                // DP83867 PHYSTS 0x0011: [15:14] speed, [13] duplex,
                // [10] link. Verify against the datasheet revision in use.
                phy_status  <= md_rdata;
                speed       <= md_rdata[15:14];
                speed_1g    <= (md_rdata[15:14] == 2'b10);
                full_duplex <= md_rdata[13];
                link_up     <= md_rdata[10];
                st          <= P_IDLE;
            end

            //---- wait for the MDIO transaction to finish ------------
            P_ISSUE: if (md_done) st <= st_after;
            endcase
        end
    end
endmodule

//---------------------------------------------------------------------
// i2c_master - single-master, 7-bit address, no clock stretching
// detection beyond releasing SCL. 400 kHz by default.
//---------------------------------------------------------------------
module i2c_master #(parameter DIV = 78) (      // 125 MHz / (4*78) ~ 400 kHz
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        rw,                 // 0 = write, 1 = read
    input  wire [6:0]  dev,
    input  wire [15:0] reg_addr,
    input  wire [15:0] wdata,
    output reg  [15:0] rdata,
    output reg         busy,
    output reg         done,
    output reg         nack,

    output reg         scl_oe,             // 1 = drive low
    output reg         sda_oe,
    input  wire        sda_i
);
    reg [7:0]  div;
    reg [1:0]  ph;                         // quarter-bit phase
    reg        tick;
    reg [6:0]  step;
    reg [8:0]  sh;                         // 8 data bits + ack slot
    reg [3:0]  bit_i;
    reg [5:0]  st;
    reg [2:0]  byte_i;
    reg        rd_phase;

    localparam I_IDLE = 6'd0, I_START = 6'd1, I_BYTE = 6'd2,
               I_ACK = 6'd3, I_RESTART = 6'd4, I_RBYTE = 6'd5,
               I_MACK = 6'd6, I_STOP = 6'd7;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin div <= 8'd0; tick <= 1'b0; end
        else if (div == (DIV - 1)) begin div <= 8'd0; tick <= 1'b1; end
        else begin div <= div + 8'd1; tick <= 1'b0; end

    reg [7:0] tx_byte;
    always @(*) begin
        case (byte_i)
        3'd0: tx_byte = {dev, rw && rd_phase};
        3'd1: tx_byte = reg_addr[15:8];
        3'd2: tx_byte = reg_addr[7:0];
        3'd3: tx_byte = wdata[15:8];
        3'd4: tx_byte = wdata[7:0];
        default: tx_byte = 8'hFF;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= I_IDLE; ph <= 2'd0; step <= 7'd0; sh <= 9'd0;
            bit_i <= 4'd0; byte_i <= 3'd0; rd_phase <= 1'b0;
            scl_oe <= 1'b0; sda_oe <= 1'b0;
            rdata <= 16'd0; busy <= 1'b0; done <= 1'b0; nack <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                busy <= 1'b1; nack <= 1'b0;
                byte_i <= 3'd0; rd_phase <= 1'b0;
                ph <= 2'd0; st <= I_START;
            end

            if (busy && tick) begin
                ph <= ph + 2'd1;

                case (st)
                //---- START: SDA falls while SCL is high ---------------
                I_START: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b0; sda_oe <= 1'b0; end
                    2'd1: sda_oe <= 1'b1;                  // SDA low
                    2'd3: begin
                        scl_oe <= 1'b1;                    // SCL low
                        sh     <= {tx_byte, 1'b1};
                        bit_i  <= 4'd0;
                        st     <= I_BYTE;
                    end
                    default: ;
                    endcase
                end

                //---- transmit one byte -------------------------------
                I_BYTE: begin
                    case (ph)
                    2'd0: sda_oe <= ~sh[8];                // drive the bit
                    2'd1: scl_oe <= 1'b0;                  // SCL high
                    2'd3: begin
                        scl_oe <= 1'b1;
                        sh     <= {sh[7:0], 1'b1};
                        if (bit_i == 4'd7) st <= I_ACK;
                        else bit_i <= bit_i + 4'd1;
                    end
                    default: ;
                    endcase
                end

                //---- read the slave ACK ------------------------------
                I_ACK: begin
                    case (ph)
                    2'd0: sda_oe <= 1'b0;                  // release SDA
                    2'd1: scl_oe <= 1'b0;
                    2'd2: if (sda_i) nack <= 1'b1;
                    2'd3: begin
                        scl_oe <= 1'b1;
                        if (rw && !rd_phase && (byte_i == 3'd2)) begin
                            rd_phase <= 1'b1;
                            byte_i   <= 3'd0;
                            st       <= I_RESTART;
                        end else if (!rw && (byte_i == 3'd4)) begin
                            st <= I_STOP;
                        end else if (rw && rd_phase && (byte_i == 3'd0)) begin
                            bit_i  <= 4'd0;
                            byte_i <= 3'd1;
                            st     <= I_RBYTE;
                        end else begin
                            byte_i <= byte_i + 3'd1;
                            sh     <= {tx_byte, 1'b1};
                            bit_i  <= 4'd0;
                            st     <= I_BYTE;
                        end
                    end
                    default: ;
                    endcase
                end

                //---- repeated START for the read phase ---------------
                I_RESTART: begin
                    case (ph)
                    2'd0: sda_oe <= 1'b0;
                    2'd1: scl_oe <= 1'b0;
                    2'd2: sda_oe <= 1'b1;
                    2'd3: begin
                        scl_oe <= 1'b1;
                        sh     <= {tx_byte, 1'b1};
                        bit_i  <= 4'd0;
                        st     <= I_BYTE;
                    end
                    default: ;
                    endcase
                end

                //---- receive one byte --------------------------------
                I_RBYTE: begin
                    case (ph)
                    2'd0: sda_oe <= 1'b0;
                    2'd1: scl_oe <= 1'b0;
                    2'd2: rdata <= {rdata[14:0], sda_i};
                    2'd3: begin
                        scl_oe <= 1'b1;
                        if (bit_i == 4'd7) st <= I_MACK;
                        else bit_i <= bit_i + 4'd1;
                    end
                    default: ;
                    endcase
                end

                //---- master ACK for byte 1, NACK for byte 2 ----------
                I_MACK: begin
                    case (ph)
                    2'd0: sda_oe <= (byte_i == 3'd1);      // ACK low
                    2'd1: scl_oe <= 1'b0;
                    2'd3: begin
                        scl_oe <= 1'b1;
                        if (byte_i == 3'd1) begin
                            byte_i <= 3'd2;
                            bit_i  <= 4'd0;
                            st     <= I_RBYTE;
                        end else st <= I_STOP;
                    end
                    default: ;
                    endcase
                end

                //---- STOP: SDA rises while SCL is high ---------------
                I_STOP: begin
                    case (ph)
                    2'd0: sda_oe <= 1'b1;
                    2'd1: scl_oe <= 1'b0;
                    2'd2: sda_oe <= 1'b0;
                    2'd3: begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        st   <= I_IDLE;
                    end
                    default: ;
                    endcase
                end

                default: st <= I_IDLE;
                endcase
            end
        end
    end
endmodule

//---------------------------------------------------------------------
// sensor_init
//
// IMPORTANT: this is a structurally correct but deliberately minimal
// register script. The register ADDRESSES below are from the standard
// onsemi/Aptina map and are widely published, but the full power-up
// sequence for the AR0234CS - analogue trim, PLL programming, sequencer
// patch - comes from onsemi's register reference and initialisation
// file, which is distributed under NDA. Drop those writes into the ROM
// below; nothing else in this design needs to change.
//---------------------------------------------------------------------
module sensor_init #(parameter N_ENTRIES = 16) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        go,
    output reg         ready,
    output reg         error,

    output reg         i2c_start,
    output reg         i2c_rw,
    output reg  [6:0]  i2c_dev,
    output reg  [15:0] i2c_addr,
    output reg  [15:0] i2c_wdata,
    input  wire        i2c_busy,
    input  wire        i2c_done,
    input  wire        i2c_nack,

    // geometry pushed in from the register file
    input  wire [11:0] cfg_width,
    input  wire [11:0] cfg_height,
    input  wire [11:0] cfg_off_x,
    input  wire [11:0] cfg_off_y
);
    localparam DEV = 7'h10;                 // AR0234CS default, 0x20 >> 1

    // AR0234CS / Aptina register addresses
    localparam A_RESET      = 16'h301A;
    localparam A_Y_START    = 16'h3002;
    localparam A_X_START    = 16'h3004;
    localparam A_Y_END      = 16'h3006;
    localparam A_X_END      = 16'h3008;
    localparam A_FRAME_LEN  = 16'h300A;
    localparam A_LINE_LEN   = 16'h300C;
    localparam A_COARSE_INT = 16'h3012;
    localparam A_TEST_PATT  = 16'h3070;
    localparam A_SERIAL_FMT = 16'h31AE;
    localparam A_DATA_FMT   = 16'h31AC;
    localparam A_MODE_SEL   = 16'h301C;

    reg [4:0] idx;
    reg [1:0] st;
    localparam S_IDLE = 2'd0, S_ISSUE = 2'd1, S_WAIT = 2'd2, S_DONE = 2'd3;

    reg [15:0] a, d;
    always @(*) begin
        case (idx)
        5'd0:  begin a = A_RESET;      d = 16'h0001; end // software reset
        5'd1:  begin a = A_RESET;      d = 16'h10D8; end // release, streaming off
        5'd2:  begin a = A_SERIAL_FMT; d = 16'h0204; end // MIPI, 4 lanes
        5'd3:  begin a = A_DATA_FMT;   d = 16'h0A0A; end // RAW10 in / RAW10 out
        5'd4:  begin a = A_X_START;    d = {4'd0, cfg_off_x}; end
        5'd5:  begin a = A_Y_START;    d = {4'd0, cfg_off_y}; end
        5'd6:  begin a = A_X_END;      d = {4'd0, cfg_off_x + cfg_width  - 12'd1}; end
        5'd7:  begin a = A_Y_END;      d = {4'd0, cfg_off_y + cfg_height - 12'd1}; end
        5'd8:  begin a = A_LINE_LEN;   d = 16'h0AA0; end // verify against onsemi
        5'd9:  begin a = A_FRAME_LEN;  d = 16'h04C4; end // verify against onsemi
        5'd10: begin a = A_COARSE_INT; d = 16'h0400; end // exposure, lines
        5'd11: begin a = A_TEST_PATT;  d = 16'h0000; end // normal imaging
        5'd12: begin a = A_MODE_SEL;   d = 16'h0000; end // trigger / mode select
        5'd13: begin a = A_RESET;      d = 16'h10DC; end // streaming on
        default: begin a = 16'h0000;   d = 16'h0000; end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx <= 5'd0; st <= S_IDLE; ready <= 1'b0; error <= 1'b0;
            i2c_start <= 1'b0; i2c_rw <= 1'b0; i2c_dev <= DEV;
            i2c_addr <= 16'd0; i2c_wdata <= 16'd0;
        end else begin
            i2c_start <= 1'b0;
            i2c_dev   <= DEV;

            case (st)
            S_IDLE: if (go) begin
                idx <= 5'd0; ready <= 1'b0; error <= 1'b0; st <= S_ISSUE;
            end

            S_ISSUE: if (!i2c_busy) begin
                i2c_rw    <= 1'b0;
                i2c_addr  <= a;
                i2c_wdata <= d;
                i2c_start <= 1'b1;
                st        <= S_WAIT;
            end

            S_WAIT: if (i2c_done) begin
                if (i2c_nack) begin
                    error <= 1'b1;
                    st    <= S_DONE;
                end else if (idx == (N_ENTRIES[4:0] - 5'd3)) begin
                    st <= S_DONE;
                end else begin
                    idx <= idx + 5'd1;
                    st  <= S_ISSUE;
                end
            end

            S_DONE: begin
                ready <= ~error;
                if (go == 1'b0) st <= S_IDLE;
            end
            endcase
        end
    end
endmodule

//---------------------------------------------------------------------
// ptp_clock - free-running 64-bit nanosecond counter. INC is the
// nominal period in 1/256 ns units; adj trims it for servo control.
//---------------------------------------------------------------------
module ptp_clock #(parameter INC = 2048) (      // 8 ns at 125 MHz
    input  wire        clk,
    input  wire        rst_n,
    input  wire signed [15:0] adj,
    output reg  [63:0] ts
);
    reg [7:0] frac;
    wire [16:0] step = $unsigned(INC[15:0]) + {{1{adj[15]}}, adj};

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin ts <= 64'd0; frac <= 8'd0; end
        else begin
            {ts, frac} <= {ts, frac} + {56'd0, step[16:0]};
        end
endmodule

//---------------------------------------------------------------------
// trigger_unit
//
// Path: isolated input on J4 -> ISO1212 -> debounce -> programmable
// delay -> sensor TRIGGER pin. The timestamp is captured at the input
// edge, not at the TRIGGER pin, so the delay does not corrupt it.
//---------------------------------------------------------------------
module trigger_unit #(parameter CLK_HZ = 125_000_000) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [1:0]  di_raw,            // In1, In2 from the ISO1212
    input  wire        flash_in,          // FLASH from the sensor
    input  wire [63:0] ts,
    input  wire [1:0]  cfg_mode,          // 0 free-run, 1 DI1, 2 DI2, 3 soft
    input  wire [15:0] cfg_delay,         // in clocks
    input  wire [15:0] cfg_strobe,        // in clocks
    input  wire        soft_trigger,
    input  wire        frame_period_tick, // free-run pacing

    output reg         sensor_trigger,
    output reg         strobe_out,        // to the isolated output
    output reg         di_enable,
    output reg  [63:0] trig_ts,
    output reg  [15:0] trig_count
);
    // --- debounce, about 1 us -----------------------------------------
    localparam DBW = 7;
    reg [DBW-1:0] cnt0, cnt1;
    wire [1:0]    di_s;
    reg  [1:0]    di_clean, di_q;

    bit_sync #(.W(2)) u_s (.clk(clk), .rst_n(rst_n), .d(di_raw), .q(di_s));

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            cnt0 <= 0; cnt1 <= 0; di_clean <= 2'd0; di_q <= 2'd0;
        end else begin
            di_q <= di_clean;
            if (di_s[0] != di_clean[0]) begin
                if (&cnt0) begin di_clean[0] <= di_s[0]; cnt0 <= 0; end
                else cnt0 <= cnt0 + 1'b1;
            end else cnt0 <= 0;
            if (di_s[1] != di_clean[1]) begin
                if (&cnt1) begin di_clean[1] <= di_s[1]; cnt1 <= 0; end
                else cnt1 <= cnt1 + 1'b1;
            end else cnt1 <= 0;
        end

    wire edge0 = di_clean[0] & ~di_q[0];
    wire edge1 = di_clean[1] & ~di_q[1];

    wire fire = (cfg_mode == 2'd0) ? frame_period_tick :
                (cfg_mode == 2'd1) ? edge0 :
                (cfg_mode == 2'd2) ? edge1 : soft_trigger;

    // --- delay and pulse ----------------------------------------------
    reg        pend;
    reg [15:0] dly, wid;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            pend <= 1'b0; dly <= 16'd0; wid <= 16'd0;
            sensor_trigger <= 1'b0; trig_ts <= 64'd0; trig_count <= 16'd0;
            di_enable <= 1'b1;
        end else begin
            di_enable <= 1'b1;               // ISO1212 EN held asserted

            if (fire && !pend) begin
                trig_ts    <= ts;             // capture at the input edge
                trig_count <= trig_count + 16'd1;
                pend       <= 1'b1;
                dly        <= cfg_delay;
            end

            if (pend) begin
                if (dly != 16'd0) dly <= dly - 16'd1;
                else begin
                    sensor_trigger <= 1'b1;
                    wid  <= 16'd16;           // >= 100 ns at 125 MHz
                    pend <= 1'b0;
                end
            end

            if (sensor_trigger) begin
                if (wid != 16'd0) wid <= wid - 16'd1;
                else sensor_trigger <= 1'b0;
            end
        end

    // --- strobe, driven from the sensor FLASH pin ---------------------
    wire flash_s;
    bit_sync #(.W(1)) u_f (.clk(clk), .rst_n(rst_n), .d(flash_in), .q(flash_s));

    reg [15:0] scnt;
    reg        flash_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin strobe_out <= 1'b0; scnt <= 16'd0; flash_q <= 1'b0; end
        else begin
            flash_q <= flash_s;
            if (flash_s & ~flash_q) begin
                strobe_out <= 1'b1;
                scnt       <= cfg_strobe;
            end else if (strobe_out) begin
                if (scnt != 16'd0) scnt <= scnt - 16'd1;
                else strobe_out <= 1'b0;
            end
        end
endmodule

//---------------------------------------------------------------------
// led_status
//---------------------------------------------------------------------
module led_status #(parameter CLK_HZ = 125_000_000) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       link_up,
    input  wire       speed_1g,
    input  wire       streaming,
    input  wire       err,
    output reg  [3:0] led
);
    reg [26:0] div;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin div <= 27'd0; led <= 4'd0; end
        else begin
            div <= div + 27'd1;
            led[0] <= link_up;
            led[1] <= speed_1g;
            led[2] <= streaming ? div[23] : 1'b0;      // blink while streaming
            led[3] <= err;
        end
endmodule

`default_nettype wire
