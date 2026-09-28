//=====================================================================
// cam_top.v - top level of the camera FPGA design.
//
// Target: Lattice CrossLink-NX LIFCL-40-9MG289I (or -9BG400I).
//
// Clock domains
//   clk_cam  ~94 MHz  D-PHY byte clock   : csi2_rx, isp
//   clk_sys  125 MHz  from PLL on clk_ref: frame buffer, network stack,
//                                          GigE Vision, control, mac_tx
//   clk_rx   125/25/2.5 MHz from the PHY : rgmii_rx, mac_rx
//
// Crossings
//   isp -> frame buffer : async_fifo, 43 bits
//   mac_rx -> net_rx    : async_fifo, 11 bits
//   config -> isp       : bit_sync, quasi-static
//
// Hierarchy note: this module is synthesisable on its own and exposes
// the DDR3L user port and the D-PHY byte interface as ports. The
// Radiant project top instantiates this module alongside three pieces
// of vendor IP - the DDR3L controller, the hardened MIPI D-PHY, and
// the configuration/JTAG blocks - and wires them to the balls.
//
// Verilog-2001.
//=====================================================================
`timescale 1ns/1ps
`default_nettype none
`include "cam_defs.vh"

//---------------------------------------------------------------------
// sys_pll - shim over the CrossLink-NX GPLL. 25 MHz in, 125 MHz out.
// Generate the real PLL in Radiant and swap the instance in.
//---------------------------------------------------------------------
module sys_pll (
    input  wire clk_ref,
    input  wire rst_n,
    output wire clk_sys,        // 125 MHz
    output wire clk_sens,       // 24 MHz  -> sensor EXTCLK
    output wire locked
);
`ifdef LATTICE_PRIM
    // Replace with the Radiant-generated PLL wrapper.
    pll_25_to_125 u_pll (.clki_i(clk_ref), .rstn_i(rst_n),
                         .clkop_o(clk_sys), .clkos_o(clk_sens),
                         .lock_o(locked));
`else
    // Simulation only: the testbench drives these directly.
    assign clk_sys  = clk_ref;
    assign clk_sens = clk_ref;
    assign locked   = rst_n;
`endif
endmodule

//---------------------------------------------------------------------
// tx_arbiter - fixed priority into the single frame composer.
// ARP and GVCP outrank the image stream so the camera stays reachable
// while it is saturating the link. GVSP requests per packet, not per
// frame, so control traffic interleaves without stalling a block.
//---------------------------------------------------------------------
module tx_arbiter (
    input  wire       arp_req,
    input  wire       gvcp_req,
    input  wire       icmp_req,
    input  wire       gvsp_req,
    output wire [3:0] gnt
);
    assign gnt[0] = arp_req;                                   // highest
    assign gnt[1] = gvcp_req & ~arp_req;
    assign gnt[2] = icmp_req & ~arp_req & ~gvcp_req;
    assign gnt[3] = gvsp_req & ~arp_req & ~gvcp_req & ~icmp_req;
endmodule

//---------------------------------------------------------------------
// cam_top
//---------------------------------------------------------------------
module cam_top #(
    parameter CLK_HZ   = 125_000_000,
    parameter PHY_ADDR = 5'd0,
    parameter FB_AW    = `FB_ADDR_W
)(
    // ---- clocks and reset -------------------------------------------
    input  wire        clk_ref,          // 25 MHz, DP83867 CLK_OUT
    input  wire        por_n,            // power-on / configuration reset

    // ---- RGMII to TIDA-010083 ---------------------------------------
    input  wire        rgmii_rx_clk,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    output wire        rgmii_gtx_clk,

    // ---- PHY management ---------------------------------------------
    output wire        phy_mdc,
    output wire        phy_mdio_o,
    output wire        phy_mdio_oe,
    input  wire        phy_mdio_i,
    output wire        phy_reset_n,
    input  wire        phy_int_n,

    // ---- isolated field I/O on TIDA J4 ------------------------------
    input  wire [1:0]  iso_in,
    output wire        iso_in_en,
    output wire        iso_out,

    // ---- hardened MIPI D-PHY byte interface -------------------------
    input  wire        dphy_byte_clk,
    input  wire [31:0] dphy_byte_data,
    input  wire        dphy_byte_valid,
    input  wire        dphy_sync,
    output wire        dphy_pd,

    // ---- AR0234CS control -------------------------------------------
    output wire        cam_scl_oe,
    output wire        cam_sda_oe,
    input  wire        cam_sda_i,
    output wire        cam_reset_n,
    output wire        cam_extclk,
    output wire        cam_trigger,
    input  wire        cam_flash,

    // ---- DDR3L user port --------------------------------------------
    output wire            ddr_cmd_valid,
    input  wire            ddr_cmd_ready,
    output wire            ddr_cmd_we,
    output wire [FB_AW-1:0] ddr_cmd_addr,
    output wire [7:0]      ddr_cmd_len,
    output wire            ddr_wr_valid,
    input  wire            ddr_wr_ready,
    output wire [63:0]     ddr_wr_data,
    output wire [7:0]      ddr_wr_be,
    input  wire            ddr_rd_valid,
    input  wire [63:0]     ddr_rd_data,

    // ---- indicators --------------------------------------------------
    output wire [3:0]  led
);
    //=================================================================
    // clocks and resets
    //=================================================================
    wire clk_sys, clk_sens, pll_locked;
    sys_pll u_pll (.clk_ref(clk_ref), .rst_n(por_n),
                   .clk_sys(clk_sys), .clk_sens(clk_sens),
                   .locked(pll_locked));

    wire clk_cam = dphy_byte_clk;
    wire clk_rx  = rgmii_rx_clk;

    wire rst_sys_n, rst_cam_n, rst_rx_n;
    rst_sync u_rs (.clk(clk_sys), .arst_n(por_n & pll_locked), .rst_n(rst_sys_n));
    rst_sync u_rc (.clk(clk_cam), .arst_n(por_n & pll_locked), .rst_n(rst_cam_n));
    rst_sync u_rr (.clk(clk_rx),  .arst_n(por_n & pll_locked), .rst_n(rst_rx_n));

    assign cam_extclk = clk_sens;

    //=================================================================
    // register file and configuration
    //=================================================================
    wire [47:0] my_mac = `MAC_ADDR_DEF;

    wire        rf_wr;
    wire [31:0] rf_addr, rf_wdata, rf_rdata;

    wire [31:0] cfg_ip, cfg_mask, cfg_gw, cfg_scda;
    wire [15:0] cfg_scp_port, cfg_scps;
    wire        cfg_stream_en;
    wire [11:0] cfg_width, cfg_height, cfg_off_x, cfg_off_y, cfg_gain;
    wire        cfg_bin_en, cfg_roi_en, cfg_blc_en, cfg_dpc_en, cfg_mono10;
    wire [9:0]  cfg_black;
    wire [1:0]  cfg_trig_mode;
    wire [15:0] cfg_trig_delay, cfg_strobe_dur;
    wire        soft_trigger;

    wire [15:0] frames_done, frames_dropped, mac_err_cnt;
    wire [63:0] ts_now;
    wire [15:0] phy_status;
    wire        sensor_ready;

    reg_file u_rf (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .wr_en(rf_wr), .addr(rf_addr), .wdata(rf_wdata), .rdata(rf_rdata),
        .my_mac(my_mac),
        .frames_done(frames_done), .frames_dropped(frames_dropped),
        .err_cnt(mac_err_cnt), .ts_now(ts_now),
        .phy_status(phy_status), .sensor_ready(sensor_ready),
        .cfg_ip(cfg_ip), .cfg_mask(cfg_mask), .cfg_gw(cfg_gw),
        .cfg_scp_port(cfg_scp_port), .cfg_scda(cfg_scda), .cfg_scps(cfg_scps),
        .cfg_stream_en(cfg_stream_en),
        .cfg_width(cfg_width), .cfg_height(cfg_height),
        .cfg_off_x(cfg_off_x), .cfg_off_y(cfg_off_y),
        .cfg_bin_en(cfg_bin_en), .cfg_roi_en(cfg_roi_en),
        .cfg_gain(cfg_gain), .cfg_black(cfg_black),
        .cfg_blc_en(cfg_blc_en), .cfg_dpc_en(cfg_dpc_en),
        .cfg_mono10(cfg_mono10),
        .cfg_trig_mode(cfg_trig_mode), .cfg_trig_delay(cfg_trig_delay),
        .cfg_strobe_dur(cfg_strobe_dur), .soft_trigger(soft_trigger)
    );

    // quasi-static config into the camera byte-clock domain.
    // Every field is stable for many clocks before it is used, so a
    // two-flop synchroniser per bit is sufficient; there is no need for
    // a handshake and no field is read atomically against another.
    wire [74:0] ccfg;
    bit_sync #(.W(75)) u_cfgs (
        .clk(clk_cam), .rst_n(rst_cam_n),
        .d({cfg_mono10, cfg_bin_en, cfg_roi_en, cfg_dpc_en, cfg_blc_en,
            cfg_gain, cfg_black, cfg_off_y, cfg_off_x,
            cfg_height, cfg_width}),
        .q(ccfg)
    );
    wire [11:0] c_width  = ccfg[11:0];
    wire [11:0] c_height = ccfg[23:12];
    wire [11:0] c_off_x  = ccfg[35:24];
    wire [11:0] c_off_y  = ccfg[47:36];
    wire [9:0]  c_black  = ccfg[57:48];
    wire [11:0] cc_gain  = ccfg[69:58];
    wire        cc_blc_en = ccfg[70];
    wire        cc_dpc_en = ccfg[71];
    wire        cc_roi_en = ccfg[72];
    wire        cc_bin_en = ccfg[73];
    wire        cc_mono10 = ccfg[74];

    //=================================================================
    // CSI-2 receive and ISP  (clk_cam)
    //=================================================================
    wire [39:0] px_data;
    wire [3:0]  px_ben;
    wire        px_vld, px_sof, px_eof, px_sol, px_eol;
    wire [15:0] csi_frame_num;
    wire        err_ecc, err_crc;

    assign dphy_pd = ~rst_cam_n;

    csi2_rx u_csi (
        .clk(clk_cam), .rst_n(rst_cam_n),
        .bd(dphy_byte_data), .bd_en(dphy_byte_valid), .sync(dphy_sync),
        .cfg_vc(2'd0), .cfg_raw8(1'b0),
        .px_data(px_data), .px_ben(px_ben), .px_vld(px_vld),
        .px_sof(px_sof), .px_eof(px_eof),
        .px_sol(px_sol), .px_eol(px_eol),
        .frame_num(csi_frame_num), .err_ecc(err_ecc), .err_crc(err_crc)
    );

    wire [39:0] isp_d;
    wire        isp_v, isp_sof, isp_eol, isp_eof, isp_err;

    isp_pipeline u_isp (
        .clk(clk_cam), .rst_n(rst_cam_n),
        .cfg_groups((c_width[11:2] == 10'd0) ? 11'd480
                                             : {1'b0, c_width[11:2]}),
        .cfg_lines(c_height),
        .cfg_blc_en(cc_blc_en), .cfg_black(c_black),
        .cfg_dpc_en(cc_dpc_en), .cfg_gain(cc_gain),
        .cfg_roi_en(cc_roi_en),
        .cfg_off_xg({1'b0, c_off_x[11:2]}), .cfg_wid_g({1'b0, c_width[11:2]}),
        .cfg_off_y(c_off_y), .cfg_hgt(c_height),
        .cfg_bin_en(cc_bin_en),
        .px_data(px_data), .px_vld(px_vld),
        .px_sof(px_sof), .px_eof(px_eof), .px_sol(px_sol),
        .o_data(isp_d), .o_vld(isp_v),
        .o_sof(isp_sof), .o_eol(isp_eol), .o_eof(isp_eof),
        .err_short_line(isp_err)
    );

    //=================================================================
    // clk_cam -> clk_sys crossing
    //=================================================================
    wire        xf_full, xf_empty;
    wire [42:0] xf_dout;

    async_fifo #(.DW(43), .AW(9)) u_xf (
        .wclk(clk_cam), .wrst_n(rst_cam_n),
        .wr(isp_v), .din({isp_eof, isp_eol, isp_sof, isp_d}),
        .wfull(xf_full), .wlevel(),
        .rclk(clk_sys), .rrst_n(rst_sys_n),
        .rd(1'b1), .dout(xf_dout), .rempty(xf_empty)
    );

    reg xf_vld;
    always @(posedge clk_sys or negedge rst_sys_n)
        if (!rst_sys_n) xf_vld <= 1'b0; else xf_vld <= ~xf_empty;

    wire [39:0] fb_d   = xf_dout[39:0];
    wire        fb_sof = xf_dout[40] & xf_vld;
    wire        fb_eof = xf_dout[42] & xf_vld;

    //=================================================================
    // frame buffer  (clk_sys)
    //=================================================================
    wire        fr_vld, fr_busy, fr_done, fr_start;
    wire [31:0] fr_bytes;
    wire [63:0] fr_ts;
    wire [15:0] fr_id;
    wire [63:0] s_data;
    wire        s_vld, s_rdy;
    wire        fb_overflow;

    frame_buffer #(.AW(FB_AW)) u_fb (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .g_data(fb_d), .g_vld(xf_vld), .g_sof(fb_sof), .g_eof(fb_eof),
        .cfg_mono10(cfg_mono10), .ts_now(ts_now), .frame_id(frames_done),
        .fr_vld(fr_vld), .fr_bytes(fr_bytes), .fr_ts(fr_ts), .fr_id(fr_id),
        .fr_start(fr_start), .fr_busy(fr_busy), .fr_done(fr_done),
        .s_data(s_data), .s_vld(s_vld), .s_rdy(s_rdy),
        .cmd_valid(ddr_cmd_valid), .cmd_ready(ddr_cmd_ready),
        .cmd_we(ddr_cmd_we), .cmd_addr(ddr_cmd_addr), .cmd_len(ddr_cmd_len),
        .wr_valid(ddr_wr_valid), .wr_ready(ddr_wr_ready),
        .wr_data(ddr_wr_data), .wr_be(ddr_wr_be),
        .rd_valid(ddr_rd_valid), .rd_data(ddr_rd_data),
        .frames_done(frames_done), .frames_dropped(frames_dropped),
        .err_overflow(fb_overflow)
    );

    //=================================================================
    // RGMII and MAC
    //=================================================================
    wire        link_up, speed_1g, phy_ready, full_duplex;
    wire [1:0]  phy_speed;

    wire [7:0]  rx_byte;
    wire        rx_byte_v, rx_byte_e;

    rgmii_rx u_rrx (
        .rx_clk(clk_rx), .rst_n(rst_rx_n),
        .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .speed_1g(speed_1g),
        .rx_data(rx_byte), .rx_vld(rx_byte_v), .rx_err(rx_byte_e)
    );

    wire [7:0]  mrx_d;
    wire        mrx_v, mrx_sof, mrx_eof, mrx_ok;

    mac_rx u_mrx (
        .clk(clk_rx), .rst_n(rst_rx_n),
        .rx_data(rx_byte), .rx_vld(rx_byte_v), .rx_err(rx_byte_e),
        .f_data(mrx_d), .f_vld(mrx_v), .f_sof(mrx_sof), .f_eof(mrx_eof),
        .f_crc_ok(mrx_ok), .err_cnt(mac_err_cnt)
    );

    // clk_rx -> clk_sys
    wire [10:0] rf_dout;
    wire        rf_empty, rf_full;
    async_fifo #(.DW(11), .AW(11)) u_rxf (
        .wclk(clk_rx), .wrst_n(rst_rx_n),
        .wr(mrx_v || mrx_eof),
        .din({mrx_ok, mrx_eof, mrx_sof, mrx_d}),
        .wfull(rf_full), .wlevel(),
        .rclk(clk_sys), .rrst_n(rst_sys_n),
        .rd(1'b1), .dout(rf_dout), .rempty(rf_empty)
    );

    reg rxv;
    always @(posedge clk_sys or negedge rst_sys_n)
        if (!rst_sys_n) rxv <= 1'b0; else rxv <= ~rf_empty;

    wire [7:0] nrx_d   = rf_dout[7:0];
    wire       nrx_sof = rf_dout[8]  & rxv;
    wire       nrx_eof = rf_dout[9]  & rxv;
    wire       nrx_ok  = rf_dout[10];
    wire       nrx_v   = rxv & ~rf_dout[9];

    //=================================================================
    // network stack  (clk_sys)
    //=================================================================
    wire        arp_rq; wire [47:0] arp_sha; wire [31:0] arp_spa;
    wire        icmp_rq; wire [15:0] icmp_len_w, icmp_id_w, icmp_seq_w;
    wire [7:0]  icmp_d_w; wire icmp_dv;
    wire        udp_v, udp_sop, udp_eop; wire [7:0] udp_d;
    wire [15:0] udp_sp, udp_dp, udp_ln;
    wire [47:0] peer_mac; wire [31:0] peer_ip;
    wire [15:0] rx_frames;

    net_rx u_nrx (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .f_data(nrx_d), .f_vld(nrx_v), .f_sof(nrx_sof),
        .f_eof(nrx_eof), .f_crc_ok(nrx_ok),
        .my_mac(my_mac), .my_ip(cfg_ip),
        .arp_req(arp_rq), .arp_sha(arp_sha), .arp_spa(arp_spa),
        .icmp_req(icmp_rq), .icmp_len(icmp_len_w),
        .icmp_d(icmp_d_w), .icmp_d_vld(icmp_dv),
        .icmp_id(icmp_id_w), .icmp_seq(icmp_seq_w),
        .udp_vld(udp_v), .udp_d(udp_d), .udp_sop(udp_sop), .udp_eop(udp_eop),
        .udp_sport(udp_sp), .udp_dport(udp_dp), .udp_len(udp_ln),
        .peer_mac(peer_mac), .peer_ip(peer_ip), .rx_frames(rx_frames)
    );

    //---- TX requesters ----------------------------------------------
    wire [3:0] gnt;

    // ARP
    wire        a_req; wire [47:0] a_dmac;
    wire [7:0]  a_d;   wire a_v, a_last; wire [15:0] a_len;
    arp_reply u_arp (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .req(arp_rq), .sha(arp_sha), .spa(arp_spa),
        .my_mac(my_mac), .my_ip(cfg_ip),
        .tx_req(a_req), .tx_dmac(a_dmac), .tx_gnt(gnt[0]),
        .tx_d(a_d), .tx_vld(a_v), .tx_rdy(cp_rdy), .tx_last(a_last),
        .tx_len(a_len)
    );

    // ICMP
    wire        i_req; wire [31:0] i_dip; wire [47:0] i_dmac;
    wire [7:0]  i_d;   wire i_v, i_last; wire [15:0] i_len;
    icmp_echo u_icmp (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .req(icmp_rq), .len(icmp_len_w), .d(icmp_d_w), .d_vld(icmp_dv),
        .id(icmp_id_w), .seq(icmp_seq_w),
        .peer_ip(peer_ip), .peer_mac(peer_mac),
        .tx_req(i_req), .tx_dip(i_dip), .tx_dmac(i_dmac), .tx_gnt(gnt[2]),
        .tx_d(i_d), .tx_vld(i_v), .tx_rdy(cp_rdy), .tx_last(i_last),
        .tx_len(i_len)
    );

    // GVCP
    wire        c_req, c_start; wire [31:0] c_dip; wire [47:0] c_dmac;
    wire [15:0] c_dport, c_plen; wire [7:0] c_d; wire c_v;
    wire [15:0] gvcp_cmds;
    gvcp u_gvcp (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .u_vld(udp_v), .u_d(udp_d), .u_sop(udp_sop), .u_eop(udp_eop),
        .u_sport(udp_sp), .u_dport(udp_dp),
        .peer_ip(peer_ip), .peer_mac(peer_mac),
        .rf_wr(rf_wr), .rf_addr(rf_addr), .rf_wdata(rf_wdata),
        .rf_rdata(rf_rdata),
        .tx_req(c_req), .tx_gnt(gnt[1]), .tx_dip(c_dip), .tx_dmac(c_dmac),
        .tx_dport(c_dport), .tx_plen(c_plen), .tx_start(c_start),
        .tx_busy(cp_busy), .p_rdy(cp_rdy), .p_data(c_d), .p_vld(c_v),
        .cmd_cnt(gvcp_cmds)
    );

    // GVSP
    wire        g_req, g_start; wire [31:0] g_dip; wire [47:0] g_dmac;
    wire [15:0] g_dport, g_plen; wire [7:0] g_d; wire g_v;
    wire [15:0] blocks_sent;
    gvsp_tx u_gvsp (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .enable(cfg_stream_en && link_up),
        .fr_vld(fr_vld), .fr_bytes(fr_bytes), .fr_ts(fr_ts), .fr_id(fr_id),
        .fr_start(fr_start), .fr_busy(fr_busy),
        .s_data(s_data), .s_vld(s_vld), .s_rdy(s_rdy),
        .cfg_size_x({20'd0, cfg_width}), .cfg_size_y({20'd0, cfg_height}),
        .cfg_off_x({20'd0, cfg_off_x}), .cfg_off_y({20'd0, cfg_off_y}),
        .cfg_mono10(cfg_mono10), .cfg_pktsize(`GVSP_PAYLOAD),
        .cfg_dest_ip(cfg_scda), .cfg_dest_port(cfg_scp_port),
        .cfg_dest_mac(peer_mac),
        .tx_req(g_req), .tx_gnt(gnt[3]), .tx_dip(g_dip), .tx_dmac(g_dmac),
        .tx_dport(g_dport), .tx_plen(g_plen), .tx_start(g_start),
        .tx_busy(cp_busy), .p_rdy(cp_rdy), .p_data(g_d), .p_vld(g_v),
        .blocks_sent(blocks_sent)
    );

    tx_arbiter u_arb (
        .arp_req(a_req), .gvcp_req(c_req), .icmp_req(i_req),
        .gvsp_req(g_req), .gnt(gnt)
    );

    //---- mux into the composer --------------------------------------
    wire        cp_busy, cp_rdy;
    reg         cp_start;
    reg  [1:0]  cp_mode;
    reg  [47:0] cp_dmac;
    reg  [15:0] cp_etype, cp_dport, cp_plen;
    reg  [31:0] cp_dip;
    reg  [7:0]  cp_d;
    reg         cp_v;

    reg a_req_q, i_req_q, c_start_q, g_start_q;
    always @(posedge clk_sys or negedge rst_sys_n)
        if (!rst_sys_n) begin
            a_req_q <= 1'b0; i_req_q <= 1'b0;
            c_start_q <= 1'b0; g_start_q <= 1'b0;
        end else begin
            a_req_q <= a_req; i_req_q <= i_req;
            c_start_q <= c_start; g_start_q <= g_start;
        end

    always @(*) begin
        cp_start = 1'b0;
        cp_mode  = 2'd1;
        cp_dmac  = 48'd0; cp_etype = `ETH_TYPE_IPV4;
        cp_dip   = 32'd0; cp_dport = 16'd0; cp_plen = 16'd0;
        cp_d     = 8'd0;  cp_v     = 1'b0;

        if (gnt[0]) begin                       // ARP
            cp_start = a_req & ~a_req_q;
            cp_mode  = 2'd0;
            cp_dmac  = a_dmac; cp_etype = `ETH_TYPE_ARP;
            cp_plen  = a_len;
            cp_d     = a_d;    cp_v     = a_v;
        end else if (gnt[1]) begin              // GVCP
            cp_start = c_start;
            cp_mode  = 2'd1;
            cp_dmac  = c_dmac; cp_dip = c_dip;
            cp_dport = c_dport; cp_plen = c_plen;
            cp_d     = c_d;    cp_v   = c_v;
        end else if (gnt[2]) begin              // ICMP
            cp_start = i_req & ~i_req_q;
            cp_mode  = 2'd2;
            cp_dmac  = i_dmac; cp_dip = i_dip;
            cp_plen  = i_len;
            cp_d     = i_d;    cp_v   = i_v;
        end else if (gnt[3]) begin              // GVSP
            cp_start = g_start;
            cp_mode  = 2'd1;
            cp_dmac  = g_dmac; cp_dip = g_dip;
            cp_dport = g_dport; cp_plen = g_plen;
            cp_d     = g_d;    cp_v   = g_v;
        end
    end

    wire [7:0] mtx_d; wire mtx_v, mtx_eof, mtx_rdy;

    tx_compose u_cp (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .start(cp_start), .mode(cp_mode),
        .dmac(cp_dmac), .ethertype(cp_etype), .dip(cp_dip),
        .sport(`GVCP_PORT), .dport(cp_dport), .plen(cp_plen),
        .my_mac(my_mac), .my_ip(cfg_ip),
        .busy(cp_busy),
        .p_rdy(cp_rdy), .p_data(cp_d), .p_vld(cp_v),
        .f_data(mtx_d), .f_vld(mtx_v), .f_eof(mtx_eof), .f_rdy(mtx_rdy)
    );

    wire [7:0] phy_tx_d; wire phy_tx_en, phy_tx_er, tx_gate;

    mac_tx u_mtx (
        .clk(clk_sys), .rst_n(rst_sys_n), .gate(tx_gate),
        .f_data(mtx_d), .f_vld(mtx_v), .f_eof(mtx_eof), .f_rdy(mtx_rdy),
        .tx_data(phy_tx_d), .tx_en(phy_tx_en), .tx_er(phy_tx_er)
    );

    rgmii_tx u_rtx (
        .tx_clk(clk_sys), .rst_n(rst_sys_n), .speed_1g(speed_1g),
        .tx_data(phy_tx_d), .tx_en(phy_tx_en), .tx_er(phy_tx_er),
        .tx_gate(tx_gate),
        .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_gtx_clk(rgmii_gtx_clk)
    );

    //=================================================================
    // control plane
    //=================================================================
    wire        md_start, md_op_rd; wire [4:0] md_phy_ad, md_reg_ad;
    wire [15:0] md_wdata, md_rdata; wire md_busy, md_done;

    mdio_master u_md (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .start(md_start), .op_rd(md_op_rd),
        .phy_ad(md_phy_ad), .reg_ad(md_reg_ad), .wdata(md_wdata),
        .rdata(md_rdata), .busy(md_busy), .done(md_done),
        .mdc(phy_mdc), .mdio_o(phy_mdio_o), .mdio_oe(phy_mdio_oe),
        .mdio_i(phy_mdio_i)
    );

    phy_init #(.CLK_HZ(CLK_HZ), .PHY_ADDR(PHY_ADDR)) u_phy (
        .clk(clk_sys), .rst_n(rst_sys_n), .phy_int_n(phy_int_n),
        .phy_reset_n(phy_reset_n), .ready(phy_ready),
        .link_up(link_up), .speed_1g(speed_1g), .speed(phy_speed),
        .full_duplex(full_duplex), .phy_status(phy_status),
        .md_start(md_start), .md_op_rd(md_op_rd),
        .md_phy_ad(md_phy_ad), .md_reg_ad(md_reg_ad), .md_wdata(md_wdata),
        .md_rdata(md_rdata), .md_busy(md_busy), .md_done(md_done)
    );

    wire        i2_start, i2_rw; wire [6:0] i2_dev;
    wire [15:0] i2_addr, i2_wdata, i2_rdata;
    wire        i2_busy, i2_done, i2_nack;

    i2c_master u_i2c (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .start(i2_start), .rw(i2_rw), .dev(i2_dev),
        .reg_addr(i2_addr), .wdata(i2_wdata), .rdata(i2_rdata),
        .busy(i2_busy), .done(i2_done), .nack(i2_nack),
        .scl_oe(cam_scl_oe), .sda_oe(cam_sda_oe), .sda_i(cam_sda_i)
    );

    // Hold the sensor in reset until the PHY is up and the PLL is locked.
    reg [15:0] cam_rst_cnt;
    reg        cam_rst_n_r;
    always @(posedge clk_sys or negedge rst_sys_n)
        if (!rst_sys_n) begin cam_rst_cnt <= 16'd0; cam_rst_n_r <= 1'b0; end
        else if (!cam_rst_n_r) begin
            if (cam_rst_cnt == 16'hFFFF) cam_rst_n_r <= 1'b1;
            else cam_rst_cnt <= cam_rst_cnt + 16'd1;
        end
    assign cam_reset_n = cam_rst_n_r;

    wire sensor_err;
    sensor_init u_si (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .go(cam_rst_n_r && phy_ready), .ready(sensor_ready), .error(sensor_err),
        .i2c_start(i2_start), .i2c_rw(i2_rw), .i2c_dev(i2_dev),
        .i2c_addr(i2_addr), .i2c_wdata(i2_wdata),
        .i2c_busy(i2_busy), .i2c_done(i2_done), .i2c_nack(i2_nack),
        .cfg_width(cfg_width), .cfg_height(cfg_height),
        .cfg_off_x(cfg_off_x), .cfg_off_y(cfg_off_y)
    );

    ptp_clock #(.INC(2048)) u_ts (
        .clk(clk_sys), .rst_n(rst_sys_n), .adj(16'sd0), .ts(ts_now)
    );

    // free-run pacing: one trigger every 2^21 clocks (~60 fps at 125 MHz)
    reg [20:0] fr_div;
    always @(posedge clk_sys or negedge rst_sys_n)
        if (!rst_sys_n) fr_div <= 21'd0; else fr_div <= fr_div + 21'd1;
    wire frame_tick = (fr_div == 21'd0);

    wire [63:0] trig_ts; wire [15:0] trig_count;
    trigger_unit #(.CLK_HZ(CLK_HZ)) u_trig (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .di_raw(iso_in), .flash_in(cam_flash), .ts(ts_now),
        .cfg_mode(cfg_trig_mode), .cfg_delay(cfg_trig_delay),
        .cfg_strobe(cfg_strobe_dur), .soft_trigger(soft_trigger),
        .frame_period_tick(frame_tick),
        .sensor_trigger(cam_trigger), .strobe_out(iso_out),
        .di_enable(iso_in_en), .trig_ts(trig_ts), .trig_count(trig_count)
    );

    led_status #(.CLK_HZ(CLK_HZ)) u_led (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .link_up(link_up), .speed_1g(speed_1g),
        .streaming(cfg_stream_en),
        .err(fb_overflow | err_ecc | err_crc | sensor_err | isp_err),
        .led(led)
    );
endmodule

`default_nettype wire
