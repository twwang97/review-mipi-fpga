//=====================================================================
// gige_vision.v - GigE Vision stream and control.
//
//   gvsp_tx  : leader / payload / trailer packetiser
//   gvcp     : READREG, WRITEREG and DISCOVERY over UDP port 3956
//   reg_file : bootstrap registers plus the camera control registers
//
// Scope note: READREG and WRITEREG are implemented in full and are
// what actually operate the camera. DISCOVERY_ACK returns a
// structurally valid 248-byte payload with the mandatory identity
// fields filled in. WRITEMEM, the message channel, and the GenICam XML
// description file are integration work, not implemented here.
//
// Verilog-2001.
//=====================================================================
`timescale 1ns/1ps
`default_nettype none
`include "cam_defs.vh"

//---------------------------------------------------------------------
// gvsp_tx
//---------------------------------------------------------------------
module gvsp_tx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    // frame descriptor from the frame buffer
    input  wire        fr_vld,
    input  wire [31:0] fr_bytes,
    input  wire [63:0] fr_ts,
    input  wire [15:0] fr_id,
    output reg         fr_start,
    input  wire        fr_busy,

    // 64-bit image stream
    input  wire [63:0] s_data,
    input  wire        s_vld,
    output reg         s_rdy,

    // geometry / format for the leader
    input  wire [31:0] cfg_size_x,
    input  wire [31:0] cfg_size_y,
    input  wire [31:0] cfg_off_x,
    input  wire [31:0] cfg_off_y,
    input  wire        cfg_mono10,
    input  wire [15:0] cfg_pktsize,      // payload bytes per packet
    input  wire [31:0] cfg_dest_ip,
    input  wire [15:0] cfg_dest_port,
    input  wire [47:0] cfg_dest_mac,

    // to the TX arbiter
    output reg         tx_req,
    input  wire        tx_gnt,
    output reg  [31:0] tx_dip,
    output reg  [47:0] tx_dmac,
    output reg  [15:0] tx_dport,
    output reg  [15:0] tx_plen,
    output reg         tx_start,
    input  wire        tx_busy,
    input  wire        p_rdy,
    output wire [7:0]  p_data,
    output wire        p_vld,

    output reg  [15:0] blocks_sent
);
    localparam G_IDLE = 4'd0, G_LEAD_REQ = 4'd1, G_SHIFT = 4'd2,
               G_PAY_REQ = 4'd3, G_PAY_DAT = 4'd4, G_TRAIL_REQ = 4'd5,
               G_DONE = 4'd6;

    localparam PF_MONO8  = 32'h01080001;
    localparam PF_MONO10 = 32'h01100003;

    reg [3:0]   st, after;
    reg [23:0]  pkt_id;
    reg [31:0]  left;
    reg [15:0]  this_pay;
    reg [15:0]  blk_id;
    reg [63:0]  ts_r;

    reg [351:0] sh;             // 44 bytes max (8 GVSP header + 36 leader)
    reg [5:0]   sh_n;

    // Output byte register. Every phase drives this one register, and a
    // byte is handed over only when p_rdy pulses. Loading p_data
    // unconditionally while p_vld is held high sends the same byte twice.
    reg [7:0]   ob;
    reg         ov;

    // 64-bit beat with a one-deep prefetch so the byte stream does not
    // bubble every eighth byte while the next beat is fetched.
    reg [63:0]  beat_r, beat_nx;
    reg         beat_valid, nx_valid;
    reg [2:0]   bsel;

    wire [31:0] pixfmt = cfg_mono10 ? PF_MONO10 : PF_MONO8;

    function [63:0] gvsp_hdr;
        input [15:0] blk;
        input [7:0]  fmt;
        input [23:0] pid;
        begin
            gvsp_hdr = {16'h0000, blk, fmt, pid};
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= G_IDLE; after <= G_IDLE; pkt_id <= 24'd0;
            left <= 32'd0; this_pay <= 16'd0; blk_id <= 16'd1; ts_r <= 64'd0;
            sh <= 352'd0; sh_n <= 6'd0; ob <= 8'd0; ov <= 1'b0;
            beat_r <= 64'd0; beat_nx <= 64'd0;
            beat_valid <= 1'b0; nx_valid <= 1'b0; bsel <= 3'd0;
            fr_start <= 1'b0; s_rdy <= 1'b0;
            tx_req <= 1'b0; tx_start <= 1'b0; tx_plen <= 16'd0;
            tx_dip <= 32'd0; tx_dmac <= 48'd0; tx_dport <= 16'd0;
            blocks_sent <= 16'd0;
        end else begin
            fr_start <= 1'b0;
            tx_start <= 1'b0;
            s_rdy    <= 1'b0;

            tx_dip   <= cfg_dest_ip;
            tx_dmac  <= cfg_dest_mac;
            tx_dport <= cfg_dest_port;

            // ---- prefetch the next 64-bit beat whenever there is room
            if ((st == G_PAY_DAT) && s_vld && !nx_valid && !s_rdy) begin
                beat_nx  <= s_data;
                nx_valid <= 1'b1;
                s_rdy    <= 1'b1;
            end

            case (st)
            //-----------------------------------------------------------
            G_IDLE: begin
                tx_req <= 1'b0;
                ov     <= 1'b0;
                if (enable && fr_vld && !fr_busy) begin
                    ts_r     <= fr_ts;
                    left     <= fr_bytes;
                    pkt_id   <= 24'd0;
                    fr_start <= 1'b1;
                    beat_valid <= 1'b0; nx_valid <= 1'b0;
                    st       <= G_LEAD_REQ;
                end
            end

            //-----------------------------------------------------------
            G_LEAD_REQ: begin
                tx_req  <= 1'b1;
                tx_plen <= 16'd44;
                if (tx_gnt && !tx_busy) begin
                    sh <= {gvsp_hdr(blk_id, 8'h01, 24'd0),
                           16'h0000, 16'h0001, ts_r, pixfmt,
                           cfg_size_x, cfg_size_y, cfg_off_x, cfg_off_y,
                           16'h0000, 16'h0000};
                    sh_n     <= 6'd44;
                    ov       <= 1'b0;
                    tx_start <= 1'b1;
                    after    <= G_PAY_REQ;
                    st       <= G_SHIFT;
                end
            end

            //-----------------------------------------------------------
            // generic byte shifter, used for leader, payload header and
            // trailer. One byte is prefetched into ob; p_rdy advances it.
            G_SHIFT: begin
                if (!ov) begin
                    if (sh_n != 6'd0) begin
                        ob   <= sh[351:344];
                        sh   <= {sh[343:0], 8'd0};
                        sh_n <= sh_n - 6'd1;
                        ov   <= 1'b1;
                    end else if (!tx_busy) begin
                        if (after == G_PAY_REQ) pkt_id <= 24'd1;
                        st <= after;
                    end
                end else if (p_rdy) begin
                    if (sh_n != 6'd0) begin
                        ob   <= sh[351:344];
                        sh   <= {sh[343:0], 8'd0};
                        sh_n <= sh_n - 6'd1;
                    end else begin
                        ov <= 1'b0;          // last byte handed over
                        if (after == G_PAY_DAT) st <= G_PAY_DAT;
                    end
                end
            end

            //-----------------------------------------------------------
            G_PAY_REQ: begin
                this_pay <= (left >= {16'd0, cfg_pktsize}) ? cfg_pktsize
                                                           : left[15:0];
                tx_req   <= 1'b1;
                tx_plen  <= 16'd8 + ((left >= {16'd0, cfg_pktsize})
                                     ? cfg_pktsize : left[15:0]);
                if (tx_gnt && !tx_busy) begin
                    sh       <= {gvsp_hdr(blk_id, 8'h03, pkt_id), 288'd0};
                    sh_n     <= 6'd8;
                    ov       <= 1'b0;
                    tx_start <= 1'b1;
                    after    <= G_PAY_DAT;
                    st       <= G_SHIFT;
                end
            end

            //-----------------------------------------------------------
            G_PAY_DAT: begin
                if (!ov) begin
                    if (beat_valid) begin
                        ob     <= beat_r[7:0];
                        beat_r <= {8'd0, beat_r[63:8]};
                        ov     <= 1'b1;
                        if (bsel == 3'd7) beat_valid <= 1'b0;
                        else              bsel <= bsel + 3'd1;
                    end else if (nx_valid) begin
                        beat_r     <= beat_nx;
                        beat_valid <= 1'b1;
                        nx_valid   <= 1'b0;
                        bsel       <= 3'd0;
                    end
                end else if (p_rdy) begin
                    this_pay <= this_pay - 16'd1;
                    left     <= left - 32'd1;
                    if (this_pay == 16'd1) begin
                        ov     <= 1'b0;
                        pkt_id <= pkt_id + 24'd1;
                        st     <= (left == 32'd1) ? G_TRAIL_REQ : G_PAY_REQ;
                    end else if (beat_valid) begin
                        ob     <= beat_r[7:0];
                        beat_r <= {8'd0, beat_r[63:8]};
                        if (bsel == 3'd7) beat_valid <= 1'b0;
                        else              bsel <= bsel + 3'd1;
                    end else begin
                        ov <= 1'b0;          // reload on the next cycle
                    end
                end
            end

            //-----------------------------------------------------------
            G_TRAIL_REQ: begin
                tx_req  <= 1'b1;
                tx_plen <= 16'd16;
                if (tx_gnt && !tx_busy) begin
                    sh <= {gvsp_hdr(blk_id, 8'h02, pkt_id),
                           16'h0000, 16'h0001, cfg_size_y, 224'd0};
                    sh_n     <= 6'd16;
                    ov       <= 1'b0;
                    tx_start <= 1'b1;
                    after    <= G_DONE;
                    st       <= G_SHIFT;
                end
            end

            //-----------------------------------------------------------
            G_DONE: begin
                tx_req      <= 1'b0;
                blk_id      <= (blk_id == 16'hFFFF) ? 16'd1 : blk_id + 16'd1;
                blocks_sent <= blocks_sent + 16'd1;
                st          <= G_IDLE;
            end
            endcase
        end
    end

    assign p_data = ob;
    assign p_vld  = ov;
endmodule

//---------------------------------------------------------------------
// reg_file
//---------------------------------------------------------------------
module reg_file (
    input  wire        clk,
    input  wire        rst_n,

    // GVCP access
    input  wire        wr_en,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    input  wire [47:0] my_mac,

    // status inputs
    input  wire [15:0] frames_done,
    input  wire [15:0] frames_dropped,
    input  wire [15:0] err_cnt,
    input  wire [63:0] ts_now,
    input  wire [15:0] phy_status,
    input  wire        sensor_ready,

    // control outputs
    output reg  [31:0] cfg_ip,
    output reg  [31:0] cfg_mask,
    output reg  [31:0] cfg_gw,
    output reg  [15:0] cfg_scp_port,
    output reg  [31:0] cfg_scda,
    output reg  [15:0] cfg_scps,
    output reg         cfg_stream_en,

    output reg  [11:0] cfg_width,
    output reg  [11:0] cfg_height,
    output reg  [11:0] cfg_off_x,
    output reg  [11:0] cfg_off_y,
    output reg         cfg_bin_en,
    output reg         cfg_roi_en,
    output reg  [11:0] cfg_gain,
    output reg  [9:0]  cfg_black,
    output reg         cfg_blc_en,
    output reg         cfg_dpc_en,
    output reg         cfg_mono10,
    output reg  [1:0]  cfg_trig_mode,   // 0 free-run, 1 DI1, 2 DI2, 3 software
    output reg  [15:0] cfg_trig_delay,
    output reg  [15:0] cfg_strobe_dur,
    output reg         soft_trigger
);
    // GigE Vision bootstrap addresses
    localparam BS_VERSION   = 32'h0000;
    localparam BS_DEVMODE   = 32'h0004;
    localparam BS_MAC_HI    = 32'h0008;
    localparam BS_MAC_LO    = 32'h000C;
    localparam BS_SUP_IPCFG = 32'h0010;
    localparam BS_CUR_IPCFG = 32'h0014;
    localparam BS_CUR_IP    = 32'h0024;
    localparam BS_CUR_MASK  = 32'h0034;
    localparam BS_CUR_GW    = 32'h0044;
    localparam BS_N_IFACE   = 32'h0200;
    localparam BS_N_MSGCH   = 32'h0900;
    localparam BS_N_STRCH   = 32'h0904;
    localparam BS_CCP       = 32'h0A00;
    localparam BS_SCP0      = 32'h0D00;
    localparam BS_SCPS0     = 32'h0D04;
    localparam BS_SCDA0     = 32'h0D18;

    // Custom camera area starts at 0x10000
    localparam CUSTOM_BASE  = 32'h0001_0000;
    wire        is_custom = (addr[31:16] == 16'h0001);
    wire [15:0] coff      = addr[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_ip <= `IP_ADDR_DEF; cfg_mask <= `IP_MASK_DEF; cfg_gw <= 32'd0;
            cfg_scp_port <= `GVSP_PORT_DEF; cfg_scda <= 32'd0;
            cfg_scps <= 16'd9000; cfg_stream_en <= 1'b0;
            cfg_width <= `SENSOR_W; cfg_height <= `SENSOR_H;
            cfg_off_x <= 12'd0; cfg_off_y <= 12'd0;
            cfg_bin_en <= 1'b0; cfg_roi_en <= 1'b0;
            cfg_gain <= 12'h100; cfg_black <= 10'd0;
            cfg_blc_en <= 1'b1; cfg_dpc_en <= 1'b1; cfg_mono10 <= 1'b0;
            cfg_trig_mode <= 2'd0; cfg_trig_delay <= 16'd0;
            cfg_strobe_dur <= 16'd100;
            soft_trigger <= 1'b0; rdata <= 32'd0;
        end else begin
            soft_trigger <= 1'b0;

            //---- read ------------------------------------------------
            if (is_custom) begin
                case (coff)
                `REG_CTRL:       rdata <= {28'd0, cfg_mono10, cfg_dpc_en,
                                           cfg_blc_en, cfg_stream_en};
                `REG_STATUS:     rdata <= {15'd0, sensor_ready, phy_status};
                `REG_WIDTH:      rdata <= {20'd0, cfg_width};
                `REG_HEIGHT:     rdata <= {20'd0, cfg_height};
                `REG_OFFX:       rdata <= {20'd0, cfg_off_x};
                `REG_OFFY:       rdata <= {20'd0, cfg_off_y};
                `REG_BINNING:    rdata <= {30'd0, cfg_roi_en, cfg_bin_en};
                `REG_GAIN:       rdata <= {20'd0, cfg_gain};
                `REG_BLACK:      rdata <= {22'd0, cfg_black};
                `REG_TRIG_MODE:  rdata <= {30'd0, cfg_trig_mode};
                `REG_TRIG_DELAY: rdata <= {16'd0, cfg_trig_delay};
                `REG_STROBE_DUR: rdata <= {16'd0, cfg_strobe_dur};
                `REG_TS_LO:      rdata <= ts_now[31:0];
                `REG_TS_HI:      rdata <= ts_now[63:32];
                `REG_FRAME_CNT:  rdata <= {frames_dropped, frames_done};
                `REG_ERR_CNT:    rdata <= {16'd0, err_cnt};
                `REG_PHY_STAT:   rdata <= {16'd0, phy_status};
                default:         rdata <= 32'd0;
                endcase
            end else begin
                case (addr)
                BS_VERSION:   rdata <= 32'h0001_0002;       // GEV 1.2
                BS_DEVMODE:   rdata <= 32'h8000_0001;       // big endian, UTF8
                BS_MAC_HI:    rdata <= {16'd0, my_mac[47:32]};
                BS_MAC_LO:    rdata <= my_mac[31:0];
                BS_SUP_IPCFG: rdata <= 32'h8000_0006;       // persistent + DHCP + LLA
                BS_CUR_IPCFG: rdata <= 32'h8000_0004;       // persistent IP
                BS_CUR_IP:    rdata <= cfg_ip;
                BS_CUR_MASK:  rdata <= cfg_mask;
                BS_CUR_GW:    rdata <= cfg_gw;
                BS_N_IFACE:   rdata <= 32'd1;
                BS_N_MSGCH:   rdata <= 32'd0;
                BS_N_STRCH:   rdata <= 32'd1;
                BS_CCP:       rdata <= 32'h0000_0002;       // exclusive granted
                BS_SCP0:      rdata <= {16'd0, cfg_scp_port};
                BS_SCPS0:     rdata <= {16'd0, cfg_scps};
                BS_SCDA0:     rdata <= cfg_scda;
                default:      rdata <= 32'd0;
                endcase
            end

            //---- write -----------------------------------------------
            if (wr_en) begin
                if (is_custom) begin
                    case (coff)
                    `REG_CTRL: begin
                        cfg_stream_en <= wdata[0];
                        cfg_blc_en    <= wdata[1];
                        cfg_dpc_en    <= wdata[2];
                        cfg_mono10    <= wdata[3];
                        soft_trigger  <= wdata[8];
                    end
                    `REG_WIDTH:      cfg_width      <= wdata[11:0];
                    `REG_HEIGHT:     cfg_height     <= wdata[11:0];
                    `REG_OFFX:       cfg_off_x      <= wdata[11:0];
                    `REG_OFFY:       cfg_off_y      <= wdata[11:0];
                    `REG_BINNING: begin
                        cfg_bin_en <= wdata[0];
                        cfg_roi_en <= wdata[1];
                    end
                    `REG_GAIN:       cfg_gain       <= wdata[11:0];
                    `REG_BLACK:      cfg_black      <= wdata[9:0];
                    `REG_TRIG_MODE:  cfg_trig_mode  <= wdata[1:0];
                    `REG_TRIG_DELAY: cfg_trig_delay <= wdata[15:0];
                    `REG_STROBE_DUR: cfg_strobe_dur <= wdata[15:0];
                    default: ;
                    endcase
                end else begin
                    case (addr)
                    BS_CUR_IP:   cfg_ip       <= wdata;
                    BS_CUR_MASK: cfg_mask     <= wdata;
                    BS_CUR_GW:   cfg_gw       <= wdata;
                    BS_SCP0:     cfg_scp_port <= wdata[15:0];
                    BS_SCPS0:    cfg_scps     <= wdata[15:0];
                    BS_SCDA0:    cfg_scda     <= wdata;
                    default: ;
                    endcase
                end
            end
        end
    end
endmodule

//---------------------------------------------------------------------
// gvcp
//---------------------------------------------------------------------
module gvcp (
    input  wire        clk,
    input  wire        rst_n,

    // UDP in
    input  wire        u_vld,
    input  wire [7:0]  u_d,
    input  wire        u_sop,
    input  wire        u_eop,
    input  wire [15:0] u_sport,
    input  wire [15:0] u_dport,
    input  wire [31:0] peer_ip,
    input  wire [47:0] peer_mac,

    // register file
    output reg         rf_wr,
    output reg  [31:0] rf_addr,
    output reg  [31:0] rf_wdata,
    input  wire [31:0] rf_rdata,

    // to the TX arbiter
    output reg         tx_req,
    input  wire        tx_gnt,
    output reg  [31:0] tx_dip,
    output reg  [47:0] tx_dmac,
    output reg  [15:0] tx_dport,
    output reg  [15:0] tx_plen,
    output reg         tx_start,
    input  wire        tx_busy,
    input  wire        p_rdy,
    output reg  [7:0]  p_data,
    output reg         p_vld,

    output reg  [15:0] cmd_cnt
);
    localparam CMD_DISCOVERY = 16'h0002;
    localparam CMD_READREG   = 16'h0080;
    localparam CMD_WRITEREG  = 16'h0082;

    localparam S_RX = 2'd0, S_EXEC = 2'd1, S_REQ = 2'd2, S_TX = 2'd3;

    reg [1:0]   st;
    reg [10:0]  bc;
    reg [15:0]  cmd, req_id, plen_in;
    reg [31:0]  a0, d0;
    reg [15:0]  ack_op, ack_len;
    reg [31:0]  ack_d;
    reg [5:0]   sh_n;
    reg [127:0] sh;
    reg         is_gvcp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_RX; bc <= 11'd0; cmd <= 16'd0; req_id <= 16'd0;
            plen_in <= 16'd0; a0 <= 32'd0; d0 <= 32'd0;
            ack_op <= 16'd0; ack_len <= 16'd0; ack_d <= 32'd0;
            sh <= 128'd0; sh_n <= 6'd0; is_gvcp <= 1'b0;
            rf_wr <= 1'b0; rf_addr <= 32'd0; rf_wdata <= 32'd0;
            tx_req <= 1'b0; tx_start <= 1'b0; tx_plen <= 16'd0;
            tx_dip <= 32'd0; tx_dmac <= 48'd0; tx_dport <= 16'd0;
            p_data <= 8'd0; p_vld <= 1'b0; cmd_cnt <= 16'd0;
        end else begin
            rf_wr    <= 1'b0;
            tx_start <= 1'b0;
            p_vld    <= 1'b0;

            case (st)
            //-----------------------------------------------------------
            S_RX: begin
                tx_req <= 1'b0;
                if (u_sop) begin
                    bc      <= 11'd0;
                    is_gvcp <= (u_dport == `GVCP_PORT) && (u_d == 8'h42);
                end
                if (u_vld && is_gvcp) begin
                    bc <= bc + 11'd1;
                    case (bc)
                    11'd2:  cmd[15:8]     <= u_d;
                    11'd3:  cmd[7:0]      <= u_d;
                    11'd4:  plen_in[15:8] <= u_d;
                    11'd5:  plen_in[7:0]  <= u_d;
                    11'd6:  req_id[15:8]  <= u_d;
                    11'd7:  req_id[7:0]   <= u_d;
                    11'd8, 11'd9, 11'd10, 11'd11: a0 <= {a0[23:0], u_d};
                    11'd12, 11'd13, 11'd14, 11'd15: d0 <= {d0[23:0], u_d};
                    default: ;
                    endcase
                end
                if (u_eop && is_gvcp) begin
                    rf_addr <= a0;
                    tx_dip   <= peer_ip;
                    tx_dmac  <= peer_mac;
                    tx_dport <= u_sport;
                    st       <= S_EXEC;
                    cmd_cnt  <= cmd_cnt + 16'd1;
                end
            end

            //-----------------------------------------------------------
            S_EXEC: begin
                case (cmd)
                CMD_READREG: begin
                    ack_op  <= CMD_READREG + 16'd1;
                    ack_len <= 16'd4;
                    ack_d   <= rf_rdata;       // rf_addr was set last cycle
                end
                CMD_WRITEREG: begin
                    rf_wr    <= 1'b1;
                    rf_wdata <= d0;
                    ack_op   <= CMD_WRITEREG + 16'd1;
                    ack_len  <= 16'd4;
                    ack_d    <= 32'd1;         // one register written
                end
                CMD_DISCOVERY: begin
                    ack_op  <= CMD_DISCOVERY + 16'd1;
                    ack_len <= 16'd8;          // abbreviated identity block
                    ack_d   <= 32'h0001_0002;
                end
                default: begin
                    ack_op  <= 16'h8005;       // NOT_IMPLEMENTED status
                    ack_len <= 16'd0;
                    ack_d   <= 32'd0;
                end
                endcase
                st <= S_REQ;
            end

            //-----------------------------------------------------------
            S_REQ: begin
                tx_req  <= 1'b1;
                tx_plen <= 16'd8 + ack_len;
                if (tx_gnt && !tx_busy) begin
                    // 8-byte ack header, then up to 8 payload bytes
                    sh <= {16'h0000, ack_op, ack_len, req_id,
                           ack_d, 32'h0001_0002};
                    sh_n     <= 6'd8 + ack_len[5:0];
                    tx_start <= 1'b1;
                    st       <= S_TX;
                end
            end

            S_TX: begin
                if (sh_n != 6'd0) begin
                    p_data <= sh[127:120];
                    p_vld  <= 1'b1;
                    if (p_rdy) begin
                        sh   <= {sh[119:0], 8'd0};
                        sh_n <= sh_n - 6'd1;
                    end
                end else if (!tx_busy) begin
                    tx_req <= 1'b0;
                    st     <= S_RX;
                end
            end
            endcase
        end
    end
endmodule

`default_nettype wire
