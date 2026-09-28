//=====================================================================
// demo3_top.v -- onsemi Demo3 baseboard FPGA top level
//
// Device : Altera Arria II GX  EP2AGX45DF25C4N
// Board  : AGB1N0CS-GEVK
// Lang   : Verilog-2001
//
// Brings up every peripheral on the board:
//   * MIPI D-PHY (4 lane), HiSPi (4 lane), CCP (1 lane), parallel 10/12b
//   * DDR3 frame buffer, triple buffered, capture or self-timed
//   * FX3 GPIF II slave FIFO -> USB 3.0
//   * ADV7526 HDMI transmitter (720p60 / 1080p60)
//   * I2C master (sensor, HDMI 0x72, clock generator 0xD2, EEPROM 0xA0)
//   * SPI master (config EPROM / headboard SPI)
//   * headboard control: power switch, HEAD_RESET_L, SP[5:0], MCLK
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module demo3_top (
   // ---- board clock and reset ----------------------------------------
   input  wire        REF_CLK,
   input  wire        POR_N,

   // ---- P5 headboard: serial image data ------------------------------
   input  wire [3:0]  MH_DATA_P,
   input  wire [3:0]  MH_DATA_N,
   input  wire        MH_CLK_P,
   input  wire        MH_CLK_N,

   // ---- P5 headboard: parallel image data ----------------------------
   input  wire [15:0] S_DATA,
   input  wire        S_FRAME_VALID,
   input  wire        S_LINE_VALID,
   input  wire        S_PIXCLK,

   // ---- P5 headboard: control ----------------------------------------
   output wire        HEAD_RESET_L,     // pin 31
   inout  wire        HEAD_SCL,         // pin 43
   inout  wire        HEAD_SDA,         // pin 37
   output wire        MCLK,             // pin 44
   input  wire        HEAD_DCLK,        // pin 45
   input  wire        HEAD_FB_CLK,      // pin 5  (S_RESERVED1 in EVBUM2310/D)
   inout  wire [5:0]  SP,               // pins 27,28,33,30,32,26
   output wire        HEAD_MOSI,        // pin 7
   input  wire        HEAD_MISO,        // pin 41
   output wire        HEAD_SSN,         // pin 34
   output wire        HEAD_PWR_EN,      // headboard power switch

   // ---- on-board I2C (ADV7526 0x72, clock gen 0xD2, EEPROM 0xA0) -----
   inout  wire        BRD_SCL,
   inout  wire        BRD_SDA,

   // ---- Cypress FX3 GPIF II ------------------------------------------
   output wire        FX3_PCLK,
   inout  wire [31:0] FX3_DQ,
   output wire [1:0]  FX3_ADDR,
   output wire        FX3_SLCS_N,
   output wire        FX3_SLWR_N,
   output wire        FX3_SLRD_N,
   output wire        FX3_SLOE_N,
   output wire        FX3_PKTEND_N,
   input  wire        FX3_FLAGA,
   input  wire        FX3_FLAGB,

   // ---- ADV7526 HDMI transmitter -------------------------------------
   output wire [35:0] HDMI_D,
   output wire        HDMI_CLK,
   output wire        HDMI_HS,
   output wire        HDMI_VS,
   output wire        HDMI_DE,
   input  wire        HDMI_INT_N,

   // ---- SPI configuration EPROM --------------------------------------
   output wire        SPI_SCLK,
   output wire        SPI_MOSI,
   input  wire        SPI_MISO,
   output wire        SPI_CS_N,

   // ---- DDR3 SDRAM, 64M x 16 -----------------------------------------
   output wire [13:0] DDR3_A,
   output wire [2:0]  DDR3_BA,
   output wire        DDR3_CK_P, output wire DDR3_CK_N,
   output wire        DDR3_CKE,  output wire DDR3_CS_N,
   output wire        DDR3_RAS_N,output wire DDR3_CAS_N,
   output wire        DDR3_WE_N, output wire DDR3_RESET_N,
   output wire [1:0]  DDR3_DM,
   inout  wire [15:0] DDR3_DQ,
   inout  wire [1:0]  DDR3_DQS_P,
   inout  wire [1:0]  DDR3_DQS_N,
   output wire        DDR3_ODT
);

   //==================================================================
   // 1. Clocks and resets
   //==================================================================
   wire clk_core, clk_ctrl, clk_ddr_ref, clk_pix, pll_locked;
   wire rst_core_n, rst_ctrl_n, rst_pix_n;
   wire o_mclk_en; wire [15:0] o_mclk_div;

   demo3_clk_rst u_clk (
      .ref_clk(REF_CLK), .por_n(POR_N),
      .clk_core(clk_core), .clk_ctrl(clk_ctrl),
      .clk_ddr_ref(clk_ddr_ref), .clk_pix(clk_pix),
      .pll_locked(pll_locked),
      .rst_core_n(rst_core_n), .rst_ctrl_n(rst_ctrl_n), .rst_pix_n(rst_pix_n),
      .mclk_en(o_mclk_en), .mclk_div(o_mclk_div), .head_mclk(MCLK));

   //==================================================================
   // 2. LVDS SERDES -- one instance on the shared MH_* pin group
   //==================================================================
   wire [31:0] lvds_byte;                 // 4 lanes x 8 bits
   wire        rx_byte_clk, lvds_locked;
   wire [3:0]  dpa_locked;
   wire [3:0]  chan_align_mipi;
   wire        rst_rx_n;

   altlvds_rx_wrap #(.CHANNELS(4), .J(`DESER_FACTOR)) u_lvds (
      .rx_inclock           (MH_CLK_P),
      .rx_enable            (1'b1),
      .rx_reset             (~rst_core_n),
      .rx_dpll_reset        (~rst_core_n),
      .rx_in                (MH_DATA_P),
      .rx_channel_data_align(chan_align_mipi),
      .rx_out               (lvds_byte),
      .rx_outclock          (rx_byte_clk),
      .rx_locked            (lvds_locked),
      .rx_dpa_locked        (dpa_locked));

   rst_sync u_rs_rx (.clk(rx_byte_clk), .arst_n(POR_N & pll_locked), .srst_n(rst_rx_n));

   //==================================================================
   // 3. Receivers
   //==================================================================
   wire [1:0] o_rx_sel;  wire [2:0] o_rx_lanes_m1;  wire [3:0] o_rx_bitdepth;
   wire o_rx_dpcm_en, o_rx_align_req;
   wire o_filter_en; wire [1:0] o_filter_vc; wire [5:0] o_filter_dt;

   // ---- MIPI D-PHY ---------------------------------------------------
   wire [`RXW-1:0]  mipi_d;  wire [`RXBE-1:0] mipi_be;
   wire mipi_v, mipi_sot, mipi_eot;
   wire [3:0] lane_aligned;  wire clk_lane_stop;

   mipi_dphy_rx #(.LANES(4)) u_dphy (
      .rx_byte_clk(rx_byte_clk), .rst_n(rst_rx_n),
      .clk_lp_p(MH_CLK_P), .clk_lp_n(MH_CLK_N),
      .lp_p(MH_DATA_P), .lp_n(MH_DATA_N),
      .lvds_word(lvds_byte), .dpa_locked(dpa_locked),
      .chan_data_align(chan_align_mipi),
      .num_lanes_m1(o_rx_lanes_m1), .align_req(o_rx_align_req),
      .m_data(mipi_d), .m_be(mipi_be), .m_valid(mipi_v),
      .m_sot(mipi_sot), .m_eot(mipi_eot),
      .lane_aligned(lane_aligned), .clk_lane_stop(clk_lane_stop));

   wire [`RXW-1:0] csi_d; wire [`RXBE-1:0] csi_be; wire csi_v;
   wire csi_fs, csi_fe, csi_ls, csi_le;
   wire [15:0] csi_frame_num;
   wire ecc_corr, ecc_unc, crc_err;

   csi2_decoder u_csi2 (
      .clk(rx_byte_clk), .rst_n(rst_rx_n),
      .s_data(mipi_d), .s_be(mipi_be), .s_valid(mipi_v),
      .s_sot(mipi_sot), .s_eot(mipi_eot), .num_lanes_m1(o_rx_lanes_m1),
      .filter_en(o_filter_en), .filter_vc(o_filter_vc), .filter_dt(o_filter_dt),
      .m_data(csi_d), .m_be(csi_be), .m_valid(csi_v), .m_dt(), .m_vc(),
      .ev_frame_start(csi_fs), .ev_frame_end(csi_fe),
      .ev_line_start(csi_ls), .ev_line_end(csi_le),
      .frame_number(csi_frame_num),
      .err_ecc_corrected(ecc_corr), .err_ecc_uncorrectable(ecc_unc),
      .err_crc(crc_err));

   // ---- CCP ----------------------------------------------------------
   wire [`RXW-1:0] ccp_d; wire [`RXBE-1:0] ccp_be; wire ccp_v;
   wire ccp_fs, ccp_fe, ccp_ls, ccp_le, ccp_align;

   ccp_rx u_ccp (
      .rx_byte_clk(rx_byte_clk), .rst_n(rst_rx_n),
      .lvds_byte(lvds_byte[7:0]), .dpa_locked(dpa_locked[0]),
      .chan_data_align(), .align_req(o_rx_align_req),
      .m_data(ccp_d), .m_be(ccp_be), .m_valid(ccp_v),
      .ev_frame_start(ccp_fs), .ev_frame_end(ccp_fe),
      .ev_line_start(ccp_ls), .ev_line_end(ccp_le), .aligned(ccp_align));

   wire use_ccp = (o_rx_sel == `SRC_CCP);
   wire [`RXW-1:0]  mc_byte_d  = use_ccp ? ccp_d  : csi_d;
   wire [`RXBE-1:0] mc_byte_be = use_ccp ? ccp_be : csi_be;
   wire             mc_byte_v  = use_ccp ? ccp_v  : csi_v;
   wire mc_fs = use_ccp ? ccp_fs : csi_fs;
   wire mc_fe = use_ccp ? ccp_fe : csi_fe;
   wire mc_ls = use_ccp ? ccp_ls : csi_ls;
   wire mc_le = use_ccp ? ccp_le : csi_le;

   wire [4*`PIXW-1:0] mc_px; wire [3:0] mc_pxv;
   raw_unpack u_unpack (
      .clk(rx_byte_clk), .rst_n(rst_rx_n), .bitdepth(o_rx_bitdepth),
      .s_data(mc_byte_d), .s_be(mc_byte_be), .s_valid(mc_byte_v),
      .s_flush(mc_fe | mc_fs),
      .m_px(mc_px), .m_valid(mc_pxv));

   // ---- HiSPi ---------------------------------------------------------
   wire [11:0] o_hispi_sof, o_hispi_sol, o_hispi_eof, o_hispi_eol;
   wire [3:0]  hispi_slip;
   wire [47:0] hispi_word;                // 4 lanes x 12 bits
   wire        hispi_word_v;

   hispi_word_asm #(.LANES(4), .J(12)) u_hasm (
      .clk(rx_byte_clk), .rst_n(rst_rx_n),
      .s_byte(lvds_byte), .s_valid(1'b1), .slip(hispi_slip),
      .m_word(hispi_word), .m_valid(hispi_word_v));

   wire [4*`PIXW-1:0] hs_px; wire [3:0] hs_pxv;
   wire hs_fs, hs_fe, hs_ls, hs_le; wire [3:0] hs_aligned;

   hispi_rx #(.LANES(4), .J(12)) u_hispi (
      .rx_word_clk(rx_byte_clk), .rst_n(rst_rx_n),
      .lvds_word(hispi_word), .dpa_locked(dpa_locked),
      .chan_data_align(hispi_slip),
      .align_req(o_rx_align_req), .bitdepth(o_rx_bitdepth),
      .sync_sof(o_hispi_sof), .sync_sol(o_hispi_sol),
      .sync_eof(o_hispi_eof), .sync_eol(o_hispi_eol),
      .m_px(hs_px), .m_valid(hs_pxv),
      .ev_frame_start(hs_fs), .ev_frame_end(hs_fe),
      .ev_line_start(hs_ls), .ev_line_end(hs_le),
      .lane_aligned(hs_aligned));

   // ---- parallel --------------------------------------------------------
   wire o_par_fv_pol, o_par_lv_pol; wire [3:0] o_par_bitdepth;
   wire [4*`PIXW-1:0] pr_px; wire [3:0] pr_pxv;
   wire pr_fs, pr_fe, pr_ls, pr_le;
   wire rst_par_n;

   rst_sync u_rs_par (.clk(S_PIXCLK), .arst_n(POR_N & pll_locked), .srst_n(rst_par_n));

   parallel_rx u_par (
      .pixclk(S_PIXCLK), .rst_n(rst_par_n),
      .s_data(S_DATA), .s_fv(S_FRAME_VALID), .s_lv(S_LINE_VALID),
      .cfg_fv_pol(o_par_fv_pol), .cfg_lv_pol(o_par_lv_pol),
      .cfg_bitdepth(o_par_bitdepth),
      .m_px(pr_px), .m_valid(pr_pxv),
      .ev_frame_start(pr_fs), .ev_frame_end(pr_fe),
      .ev_line_start(pr_ls), .ev_line_end(pr_le));

   //==================================================================
   // 4. Source select + CDC into the 150 MHz core
   //==================================================================
   wire [4*`PIXW-1:0] rx_px; wire [3:0] rx_pxv;
   wire rx_sof, rx_eof, rx_sol, rx_eol;
   wire fifo_ovf, fifo_unf;
   wire fmt_s_ready;

   rx_arbiter u_arb (
      .clk_core(clk_core), .rst_core_n(rst_core_n), .rx_sel(o_rx_sel),
      .mc_clk(rx_byte_clk), .mc_rst_n(rst_rx_n),
      .mc_px(mc_px), .mc_valid(mc_pxv),
      .mc_sof(mc_fs), .mc_eof(mc_fe), .mc_sol(mc_ls), .mc_eol(mc_le),
      .hs_clk(rx_byte_clk), .hs_rst_n(rst_rx_n),
      .hs_px(hs_px), .hs_valid(hs_pxv),
      .hs_sof(hs_fs), .hs_eof(hs_fe), .hs_sol(hs_ls), .hs_eol(hs_le),
      .pr_clk(S_PIXCLK), .pr_rst_n(rst_par_n),
      .pr_px(pr_px), .pr_valid(pr_pxv),
      .pr_sof(pr_fs), .pr_eof(pr_fe), .pr_sol(pr_ls), .pr_eol(pr_le),
      .m_ready(fmt_s_ready),
      .m_px(rx_px), .m_valid(rx_pxv),
      .m_sof(rx_sof), .m_eof(rx_eof), .m_sol(rx_sol), .m_eol(rx_eol),
      .fifo_overflow(fifo_ovf), .fifo_underflow(fifo_unf));

   //==================================================================
   // 5. DPCM decode + formatter
   //==================================================================
   wire [7:0] o_dpcm_addr; wire [15:0] o_dpcm_data; wire o_dpcm_we;
   wire [4*`PIXW-1:0] dp_px; wire [3:0] dp_pxv;

   dpcm_decode u_dpcm (
      .clk(clk_core), .rst_n(rst_core_n),
      .bypass(~o_rx_dpcm_en), .line_start(rx_sol),
      .tbl_we(o_dpcm_we), .tbl_addr(o_dpcm_addr), .tbl_data(o_dpcm_data),
      .s_px(rx_px), .s_valid(rx_pxv), .m_px(dp_px), .m_valid(dp_pxv));

   wire o_core_en;
   wire [`DDRW-1:0] fmt_d; wire fmt_v, fmt_sof, fmt_eof;
   wire fb_w_ready;
   wire [31:0] fmt_pixel_cnt; wire [15:0] fmt_line_cnt;

   formatter u_fmt (
      .clk(clk_core), .rst_n(rst_core_n), .enable(o_core_en),
      .s_px(dp_px), .s_valid(dp_pxv),
      .s_sof(rx_sof), .s_eof(rx_eof), .s_sol(rx_sol), .s_eol(rx_eol),
      .s_ready(fmt_s_ready),
      .m_data(fmt_d), .m_valid(fmt_v), .m_sof(fmt_sof), .m_eof(fmt_eof),
      .m_ready(fb_w_ready),
      .pixel_count(fmt_pixel_cnt), .line_count(fmt_line_cnt));

   //==================================================================
   // 6. DDR3 frame buffer
   //==================================================================
   wire o_fb_en, o_fb_flush, o_capture_mode;
   wire [`AVL_AW-1:0] o_fb_base0, o_fb_base1, o_fb_base2;
   wire [31:0] o_fb_frame_bytes;

   wire [`AVL_AW-1:0] avl_addr; wire avl_rd, avl_wr;
   wire [4:0] avl_bb, avl_size;
   wire [`DDRW-1:0] avl_wdata, avl_rdata;
   wire [15:0] avl_be; wire avl_ready, avl_rdvalid;
   wire ddr_init_done, ddr_cal_ok, ddr_cal_fail;

   ddr3_uniphy u_ddr3 (
      .pll_ref_clk(clk_ddr_ref), .global_reset_n(POR_N), .soft_reset_n(rst_core_n),
      .afi_clk(), .afi_half_clk(), .afi_reset_n(),
      .local_init_done(ddr_init_done), .local_cal_success(ddr_cal_ok),
      .local_cal_fail(ddr_cal_fail),
      .avl_addr(avl_addr), .avl_read_req(avl_rd), .avl_write_req(avl_wr),
      .avl_burstbegin(avl_bb), .avl_wdata(avl_wdata), .avl_be(avl_be),
      .avl_size(avl_size), .avl_ready(avl_ready),
      .avl_rdata(avl_rdata), .avl_rdata_valid(avl_rdvalid),
      .mem_a(DDR3_A), .mem_ba(DDR3_BA), .mem_ck(DDR3_CK_P), .mem_ck_n(DDR3_CK_N),
      .mem_cke(DDR3_CKE), .mem_cs_n(DDR3_CS_N), .mem_ras_n(DDR3_RAS_N),
      .mem_cas_n(DDR3_CAS_N), .mem_we_n(DDR3_WE_N), .mem_reset_n(DDR3_RESET_N),
      .mem_dm(DDR3_DM), .mem_dq(DDR3_DQ),
      .mem_dqs(DDR3_DQS_P), .mem_dqs_n(DDR3_DQS_N), .mem_odt(DDR3_ODT));

   wire [`DDRW-1:0] fb_r_data; wire fb_r_valid, fb_r_frame_done;
   wire fb_r_ready, fb_r_req;
   wire [1:0] fb_wr_buf, fb_rd_buf;
   wire fb_ready, fb_ovf, fb_frame_ready;
   wire [31:0] fb_wr_cnt, fb_rd_cnt;

   frame_buffer_ctrl #(.BURST(16)) u_fb (
      .clk(clk_core), .rst_n(rst_core_n),
      .cfg_en(o_fb_en), .cfg_capture_mode(o_capture_mode), .cfg_flush(o_fb_flush),
      .cfg_base0(o_fb_base0), .cfg_base1(o_fb_base1), .cfg_base2(o_fb_base2),
      .cfg_frame_bytes(o_fb_frame_bytes),
      .w_data(fmt_d), .w_valid(fmt_v), .w_sof(fmt_sof), .w_eof(fmt_eof),
      .w_ready(fb_w_ready),
      .r_req(fb_r_req), .r_data(fb_r_data), .r_valid(fb_r_valid),
      .r_ready(fb_r_ready), .r_frame_done(fb_r_frame_done),
      .avl_addr(avl_addr), .avl_read_req(avl_rd), .avl_write_req(avl_wr),
      .avl_burstbegin(avl_bb), .avl_wdata(avl_wdata), .avl_be(avl_be),
      .avl_size(avl_size), .avl_ready(avl_ready),
      .avl_rdata(avl_rdata), .avl_rdata_valid(avl_rdvalid),
      .st_wr_buf(fb_wr_buf), .st_rd_buf(fb_rd_buf),
      .st_ready(fb_ready), .st_overflow(fb_ovf),
      .st_wr_cnt(fb_wr_cnt), .st_rd_cnt(fb_rd_cnt),
      .ev_frame_ready(fb_frame_ready));

   //==================================================================
   // 7. Egress: FX3 and HDMI both drain the frame buffer read port
   //==================================================================
   wire o_fx3_en; wire [11:0] o_fx3_burst; wire [15:0] o_fx3_pktend_to;
   wire o_hdmi_en; wire [1:0] o_hdmi_fmt;

   // 128-bit beats -> 32-bit words for FX3
   reg  [`DDRW-1:0] fx_beat; reg [1:0] fx_word; reg fx_have;
   wire fx_v_ready;
   wire [31:0] fx_v_data = fx_beat[fx_word*32 +: 32];
   wire        fx_v_valid = fx_have;

   assign fb_r_req   = o_fx3_en | o_hdmi_en;
   assign fb_r_ready = (!fx_have) | (fx_v_ready & (fx_word == 2'd3));

   always @(posedge clk_core or negedge rst_core_n) begin
      if (!rst_core_n) begin
         fx_beat <= {`DDRW{1'b0}}; fx_word <= 2'd0; fx_have <= 1'b0;
      end else begin
         if (!fx_have && fb_r_valid) begin
            fx_beat <= fb_r_data; fx_word <= 2'd0; fx_have <= 1'b1;
         end else if (fx_have && fx_v_ready) begin
            if (fx_word == 2'd3) fx_have <= 1'b0;
            else                 fx_word <= fx_word + 1'b1;
         end
      end
   end

   wire [15:0] reg_a_fx; wire [31:0] reg_wd_fx, reg_rd;
   wire reg_we_fx, reg_re_fx, reg_ready;
   wire [31:0] fx3_xfer_cnt; wire fx3_busy;

   fx3_slave_fifo u_fx3 (
      .clk(clk_core), .rst_n(rst_core_n),
      .cfg_en(o_fx3_en), .cfg_burst(o_fx3_burst), .cfg_pktend_to(o_fx3_pktend_to),
      .fx3_pclk(FX3_PCLK), .fx3_dq(FX3_DQ), .fx3_addr(FX3_ADDR),
      .fx3_slcs_n(FX3_SLCS_N), .fx3_slwr_n(FX3_SLWR_N), .fx3_slrd_n(FX3_SLRD_N),
      .fx3_sloe_n(FX3_SLOE_N), .fx3_pktend_n(FX3_PKTEND_N),
      .fx3_flaga(FX3_FLAGA), .fx3_flagb(FX3_FLAGB),
      .v_data(fx_v_data), .v_valid(fx_v_valid), .v_ready(fx_v_ready),
      .v_frame_done(fb_r_frame_done),
      .reg_addr(reg_a_fx), .reg_wdata(reg_wd_fx),
      .reg_we(reg_we_fx), .reg_re(reg_re_fx),
      .reg_rdata(reg_rd), .reg_ready(reg_ready),
      .st_xfer_cnt(fx3_xfer_cnt), .st_busy(fx3_busy));

   // ---- HDMI path -------------------------------------------------------
   wire o_vtg_en, o_vtg_mode, o_vtg_ext, o_hs_pol, o_vs_pol;
   wire [15:0] o_htotal,o_hactive,o_hfront,o_hsync,o_vtotal,o_vactive,o_vfront,o_vsync;
   wire t_hs, t_vs, t_de, vtg_fs, vtg_ls;

   video_timing_gen u_vtg (
      .clk_pix(clk_pix), .rst_n(rst_pix_n),
      .cfg_en(o_vtg_en), .cfg_mode(o_vtg_mode), .cfg_ext(o_vtg_ext),
      .cfg_htotal(o_htotal), .cfg_hactive(o_hactive),
      .cfg_hfront(o_hfront), .cfg_hsync(o_hsync),
      .cfg_vtotal(o_vtotal), .cfg_vactive(o_vactive),
      .cfg_vfront(o_vfront), .cfg_vsync(o_vsync),
      .cfg_hs_pol(o_hs_pol), .cfg_vs_pol(o_vs_pol),
      .hsync(t_hs), .vsync(t_vs), .de(t_de),
      .hpos(), .vpos(), .frame_start(vtg_fs), .line_start(vtg_ls));

   // frame-buffer beats crossed into the pixel clock for HDMI
   wire [`DDRW-1:0] hd_q; wire hd_empty; wire hd_ready;
   dcfifo_wrap #(.W(`DDRW), .DEPTH_LOG2(8)) u_hdfifo (
      .aclr(~rst_core_n),
      .wrclk(clk_core), .wrreq(fb_r_valid & o_hdmi_en), .data(fb_r_data),
      .wrfull(), .wrusedw(),
      .rdclk(clk_pix), .rdreq(hd_ready & ~hd_empty), .q(hd_q),
      .rdempty(hd_empty), .rdusedw());

   hdmi_out u_hdmi (
      .clk_pix(clk_pix), .rst_n(rst_pix_n),
      .cfg_out_en(o_hdmi_en), .cfg_fmt(o_hdmi_fmt),
      .t_hsync(t_hs), .t_vsync(t_vs), .t_de(t_de),
      .s_data(hd_q), .s_valid(~hd_empty), .s_ready(hd_ready),
      .hdmi_d(HDMI_D), .hdmi_hs(HDMI_HS), .hdmi_vs(HDMI_VS),
      .hdmi_de(HDMI_DE), .hdmi_clk(HDMI_CLK));

   //==================================================================
   // 8. I2C: one master, two physical buses (board / headboard)
   //==================================================================
   wire o_i2c_en; wire [1:0] o_i2c_speed;
   wire o_i2c_go, o_i2c_rw, o_i2c_start, o_i2c_stop;
   wire [7:0] o_i2c_addr, o_i2c_wdata, i2c_rdata;
   wire i2c_busy, i2c_ack_n, i2c_arb_lost, i2c_done;
   wire scl_oe, sda_oe;

   wire o_i2c_seq_run, o_i2c_seq_we;
   wire [7:0] o_i2c_seq_len, o_i2c_seq_addr;
   wire [31:0] o_i2c_seq_data;
   wire sq_go, sq_rw, sq_start, sq_stop, sq_busy, sq_err;
   wire [7:0] sq_addr, sq_wdata;

   i2c_seq u_i2cseq (
      .clk(clk_core), .rst_n(rst_core_n),
      .ld_we(o_i2c_seq_we), .ld_addr(o_i2c_seq_addr), .ld_data(o_i2c_seq_data),
      .run(o_i2c_seq_run), .len(o_i2c_seq_len), .busy(sq_busy), .err(sq_err),
      .c_go(sq_go), .c_rw(sq_rw), .c_start(sq_start), .c_stop(sq_stop),
      .c_addr(sq_addr), .c_wdata(sq_wdata),
      .c_busy(i2c_busy), .c_ack_n(i2c_ack_n), .c_done(i2c_done));

   // sequencer wins the bus while it is running
   wire       m_go    = sq_busy ? sq_go    : o_i2c_go;
   wire       m_rw    = sq_busy ? sq_rw    : o_i2c_rw;
   wire       m_start = sq_busy ? sq_start : o_i2c_start;
   wire       m_stop  = sq_busy ? sq_stop  : o_i2c_stop;
   wire [7:0] m_addr  = sq_busy ? sq_addr  : o_i2c_addr;
   wire [7:0] m_wdata = sq_busy ? sq_wdata : o_i2c_wdata;

   // bus select: 0 = on-board (ADV7526/clkgen/EEPROM), 1 = headboard
   wire bus_head = m_addr[7:1] != 7'h39 &&      // 0x72 ADV7526
                   m_addr[7:1] != 7'h69 &&      // 0xD2 clock generator
                   m_addr[7:1] != 7'h50;        // 0xA0 system EEPROM
   wire scl_in = bus_head ? HEAD_SCL : BRD_SCL;
   wire sda_in = bus_head ? HEAD_SDA : BRD_SDA;

   assign HEAD_SCL = (bus_head && scl_oe) ? 1'b0 : 1'bz;
   assign HEAD_SDA = (bus_head && sda_oe) ? 1'b0 : 1'bz;
   assign BRD_SCL  = (!bus_head && scl_oe) ? 1'b0 : 1'bz;
   assign BRD_SDA  = (!bus_head && sda_oe) ? 1'b0 : 1'bz;

   i2c_master #(.CLK_HZ(`CORE_HZ)) u_i2c (
      .clk(clk_core), .rst_n(rst_core_n),
      .cfg_en(o_i2c_en), .cfg_speed(o_i2c_speed),
      .scl_in(scl_in), .scl_oe(scl_oe), .sda_in(sda_in), .sda_oe(sda_oe),
      .c_go(m_go), .c_rw(m_rw), .c_start(m_start), .c_stop(m_stop),
      .c_addr(m_addr), .c_wdata(m_wdata), .c_rdata(i2c_rdata),
      .c_busy(i2c_busy), .c_ack_n(i2c_ack_n), .c_arb_lost(i2c_arb_lost),
      .c_done(i2c_done));

   //==================================================================
   // 9. SPI
   //==================================================================
   wire o_spi_cs_n, o_spi_go; wire [3:0] o_spi_div; wire [7:0] o_spi_tx, spi_rx;
   wire spi_busy, spi_done;

   spi_master u_spi (
      .clk(clk_core), .rst_n(rst_core_n),
      .cfg_div(o_spi_div), .cfg_cs_n(o_spi_cs_n),
      .go(o_spi_go), .tx(o_spi_tx), .rx(spi_rx),
      .busy(spi_busy), .done(spi_done),
      .spi_sclk(SPI_SCLK), .spi_mosi(SPI_MOSI), .spi_miso(SPI_MISO),
      .spi_cs_n(SPI_CS_N));

   assign HEAD_MOSI = SPI_MOSI;
   assign HEAD_SSN  = SPI_CS_N;

   //==================================================================
   // 10. Headboard control
   //==================================================================
   wire o_head_rst_n, o_head_rst_pulse, o_head_pwr_en;
   wire [5:0] o_sp_out, o_sp_oe; wire [31:0] o_head_rst_len;
   wire [2:0] o_trig_idx; wire o_trig_fire; wire [15:0] o_trig_width;
   wire [5:0] sp_drv, sp_oen, sp_rd;
   wire [15:0] flash_cnt, shutter_cnt;
   wire ev_flash, ev_shutter, head_rst_busy;

   genvar s;
   generate
      for (s = 0; s < 6; s = s + 1) begin : G_SP
         assign SP[s] = sp_oen[s] ? sp_drv[s] : 1'bz;
      end
   endgenerate
   assign sp_rd = SP;

   head_ctrl u_head (
      .clk(clk_core), .rst_n(rst_core_n),
      .cfg_rst_n(o_head_rst_n), .cfg_rst_pulse(o_head_rst_pulse),
      .cfg_rst_len(o_head_rst_len), .cfg_pwr_en(o_head_pwr_en),
      .cfg_sp_out(o_sp_out), .cfg_sp_oe(o_sp_oe),
      .cfg_trig_idx(o_trig_idx), .cfg_trig_fire(o_trig_fire),
      .cfg_trig_width(o_trig_width),
      .head_reset_l(HEAD_RESET_L), .sp_out(sp_drv), .sp_oe(sp_oen), .sp_in(sp_rd),
      .head_pwr_en(HEAD_PWR_EN),
      .st_sp_in(), .st_flash_cnt(flash_cnt), .st_shutter_cnt(shutter_cnt),
      .ev_flash(ev_flash), .ev_shutter(ev_shutter), .st_rst_busy(head_rst_busy));

   //==================================================================
   // 11. Events / interrupts
   //==================================================================
   wire fs_core, fe_core, le_core, ecc_c_core, ecc_u_core, crc_core;
   pulse_sync u_p0 (.src_clk(rx_byte_clk), .src_rst_n(rst_rx_n), .src_pulse(mc_fs),
                    .dst_clk(clk_core), .dst_rst_n(rst_core_n), .dst_pulse(fs_core));
   pulse_sync u_p1 (.src_clk(rx_byte_clk), .src_rst_n(rst_rx_n), .src_pulse(mc_fe),
                    .dst_clk(clk_core), .dst_rst_n(rst_core_n), .dst_pulse(fe_core));
   pulse_sync u_p2 (.src_clk(rx_byte_clk), .src_rst_n(rst_rx_n), .src_pulse(mc_le),
                    .dst_clk(clk_core), .dst_rst_n(rst_core_n), .dst_pulse(le_core));
   pulse_sync u_p3 (.src_clk(rx_byte_clk), .src_rst_n(rst_rx_n), .src_pulse(ecc_corr),
                    .dst_clk(clk_core), .dst_rst_n(rst_core_n), .dst_pulse(ecc_c_core));
   pulse_sync u_p4 (.src_clk(rx_byte_clk), .src_rst_n(rst_rx_n), .src_pulse(ecc_unc),
                    .dst_clk(clk_core), .dst_rst_n(rst_core_n), .dst_pulse(ecc_u_core));
   pulse_sync u_p5 (.src_clk(rx_byte_clk), .src_rst_n(rst_rx_n), .src_pulse(crc_err),
                    .dst_clk(clk_core), .dst_rst_n(rst_core_n), .dst_pulse(crc_core));
   wire vtg_vs_core;
   pulse_sync u_p6 (.src_clk(clk_pix), .src_rst_n(rst_pix_n), .src_pulse(vtg_fs),
                    .dst_clk(clk_core), .dst_rst_n(rst_core_n), .dst_pulse(vtg_vs_core));

   wire [31:0] ev_vec;
   assign ev_vec[`IRQ_FRAME_START]   = fs_core;
   assign ev_vec[`IRQ_FRAME_END]     = fe_core;
   assign ev_vec[`IRQ_LINE_END]      = le_core;
   assign ev_vec[`IRQ_FIFO_OVF]      = fifo_ovf;
   assign ev_vec[`IRQ_FIFO_UNF]      = fifo_unf;
   assign ev_vec[`IRQ_ECC_CORR]      = ecc_c_core;
   assign ev_vec[`IRQ_ECC_UNC]       = ecc_u_core;
   assign ev_vec[`IRQ_CRC_ERR]       = crc_core;
   assign ev_vec[`IRQ_FB_READY]      = fb_frame_ready;
   assign ev_vec[`IRQ_FB_OVF]        = fb_ovf;
   assign ev_vec[`IRQ_I2C_DONE]      = i2c_done;
   assign ev_vec[`IRQ_SPI_DONE]      = spi_done;
   assign ev_vec[`IRQ_HEAD_FLASH]    = ev_flash;
   assign ev_vec[`IRQ_HEAD_SHUTTER]  = ev_shutter;
   assign ev_vec[`IRQ_VTG_VSYNC]     = vtg_vs_core;
   assign ev_vec[`IRQ_LANE_LOCK]     = &lane_aligned;
   assign ev_vec[31:16]              = 16'd0;

   wire [31:0] irq_stat, o_irq_ena, o_irq_force, o_irq_clr;
   wire o_irq_clr_stb, irq_any;

   event_ctrl u_evt (
      .clk(clk_core), .rst_n(rst_core_n),
      .ev(ev_vec), .ena(o_irq_ena), .force_set(o_irq_force),
      .clr(o_irq_clr), .clr_stb(o_irq_clr_stb),
      .status(irq_stat), .irq(irq_any));

   //==================================================================
   // 12. Counters and status aggregation
   //==================================================================
   wire [15:0] cnt_frames, cnt_lines;
   wire [7:0]  cnt_ecc_c, cnt_ecc_u;
   wire [15:0] cnt_crc;

   evt_counter #(16) u_cf (.clk(clk_core), .rst_n(rst_core_n), .clr(o_fb_flush),
                           .inc(fs_core), .cnt(cnt_frames));
   evt_counter #(16) u_cl (.clk(clk_core), .rst_n(rst_core_n), .clr(fs_core),
                           .inc(le_core), .cnt(cnt_lines));
   evt_counter #(8)  u_ce (.clk(clk_core), .rst_n(rst_core_n), .clr(o_fb_flush),
                           .inc(ecc_c_core), .cnt(cnt_ecc_c));
   evt_counter #(8)  u_cu (.clk(clk_core), .rst_n(rst_core_n), .clr(o_fb_flush),
                           .inc(ecc_u_core), .cnt(cnt_ecc_u));
   evt_counter #(16) u_cc (.clk(clk_core), .rst_n(rst_core_n), .clr(o_fb_flush),
                           .inc(crc_core), .cnt(cnt_crc));

   wire [3:0] lane_lock_sync;
   cdc_sync #(4) u_ll (.clk(clk_core), .rst_n(rst_core_n),
                       .d(lane_aligned), .q(lane_lock_sync));

   wire [31:0] global_stat = {16'd0, irq_any, head_rst_busy, sq_err, sq_busy,
                              ddr_cal_fail, ddr_cal_ok, ddr_init_done,
                              HDMI_INT_N, clk_lane_stop, lvds_locked,
                              ccp_align, fx3_busy, hs_aligned[0],
                              pll_locked, 1'b0, o_core_en};
   wire [31:0] rx_stat  = {16'd0, 4'd0, hs_aligned, fifo_unf, fifo_ovf,
                           2'd0, lane_lock_sync};
   wire [31:0] fb_stat  = {26'd0, fb_ovf, fb_ready, fb_rd_buf, fb_wr_buf};
   wire [31:0] i2c_stat = {28'd0, i2c_done, i2c_arb_lost, i2c_ack_n, i2c_busy};
   wire [31:0] fx3_stat = {29'd0, fx3_busy, FX3_FLAGB, FX3_FLAGA};

   //==================================================================
   // 13. Register file
   //==================================================================
   reg_file u_regs (
      .clk(clk_core), .rst_n(rst_core_n),
      .a(reg_a_fx), .wd(reg_wd_fx), .we(reg_we_fx), .re(reg_re_fx),
      .rd(reg_rd), .ready(reg_ready),
      .o_core_en(o_core_en), .o_soft_rst(), .o_capture_mode(o_capture_mode),
      .i_global_stat(global_stat),
      .o_irq_ena(o_irq_ena), .o_irq_force(o_irq_force),
      .o_irq_clr(o_irq_clr), .o_irq_clr_stb(o_irq_clr_stb), .i_irq_stat(irq_stat),
      .o_rx_sel(o_rx_sel), .o_rx_lanes_m1(o_rx_lanes_m1),
      .o_rx_bitdepth(o_rx_bitdepth), .o_rx_dpcm_en(o_rx_dpcm_en),
      .o_rx_align_req(o_rx_align_req), .i_rx_stat(rx_stat),
      .i_rx_frame_cnt({16'd0, cnt_frames}), .i_rx_line_cnt({16'd0, cnt_lines}),
      .i_rx_err_cnt({cnt_crc, cnt_ecc_u, cnt_ecc_c}),
      .o_filter_en(o_filter_en), .o_filter_vc(o_filter_vc), .o_filter_dt(o_filter_dt),
      .o_hispi_sof(o_hispi_sof), .o_hispi_sol(o_hispi_sol),
      .o_hispi_eof(o_hispi_eof), .o_hispi_eol(o_hispi_eol),
      .o_par_fv_pol(o_par_fv_pol), .o_par_lv_pol(o_par_lv_pol),
      .o_par_bitdepth(o_par_bitdepth),
      .o_dpcm_addr(o_dpcm_addr), .o_dpcm_data(o_dpcm_data), .o_dpcm_we(o_dpcm_we),
      .o_fb_en(o_fb_en), .o_fb_flush(o_fb_flush),
      .o_fb_base0(o_fb_base0), .o_fb_base1(o_fb_base1), .o_fb_base2(o_fb_base2),
      .o_fb_frame_bytes(o_fb_frame_bytes),
      .i_fb_stat(fb_stat), .i_fb_wr_cnt(fb_wr_cnt), .i_fb_rd_cnt(fb_rd_cnt),
      .o_vtg_en(o_vtg_en), .o_vtg_mode(o_vtg_mode), .o_vtg_ext(o_vtg_ext),
      .o_htotal(o_htotal), .o_hactive(o_hactive),
      .o_hfront(o_hfront), .o_hsync(o_hsync),
      .o_vtotal(o_vtotal), .o_vactive(o_vactive),
      .o_vfront(o_vfront), .o_vsync(o_vsync),
      .o_hdmi_en(o_hdmi_en), .o_hs_pol(o_hs_pol), .o_vs_pol(o_vs_pol),
      .o_hdmi_fmt(o_hdmi_fmt),
      .o_fx3_en(o_fx3_en), .o_fx3_burst(o_fx3_burst),
      .o_fx3_pktend_to(o_fx3_pktend_to),
      .i_fx3_stat(fx3_stat), .i_fx3_xfer_cnt(fx3_xfer_cnt),
      .o_i2c_en(o_i2c_en), .o_i2c_speed(o_i2c_speed),
      .o_i2c_go(o_i2c_go), .o_i2c_rw(o_i2c_rw),
      .o_i2c_start(o_i2c_start), .o_i2c_stop(o_i2c_stop),
      .o_i2c_addr(o_i2c_addr), .o_i2c_wdata(o_i2c_wdata),
      .i_i2c_stat(i2c_stat), .i_i2c_rdata(i2c_rdata),
      .o_i2c_seq_run(o_i2c_seq_run), .o_i2c_seq_len(o_i2c_seq_len),
      .o_i2c_seq_addr(o_i2c_seq_addr), .o_i2c_seq_data(o_i2c_seq_data),
      .o_i2c_seq_we(o_i2c_seq_we),
      .o_spi_cs_n(o_spi_cs_n), .o_spi_go(o_spi_go), .o_spi_div(o_spi_div),
      .o_spi_tx(o_spi_tx), .i_spi_rx(spi_rx), .i_spi_stat({31'd0, spi_busy}),
      .o_head_rst_n(o_head_rst_n), .o_head_rst_pulse(o_head_rst_pulse),
      .o_mclk_en(o_mclk_en), .o_head_pwr_en(o_head_pwr_en),
      .o_sp_out(o_sp_out), .o_sp_oe(o_sp_oe),
      .o_mclk_div(o_mclk_div), .o_head_rst_len(o_head_rst_len),
      .o_trig_idx(o_trig_idx), .o_trig_fire(o_trig_fire),
      .o_trig_width(o_trig_width),
      .i_sp_in(sp_rd), .i_head_evt_cnt({shutter_cnt, flash_cnt}));

   wire _unused = |{HEAD_DCLK, HEAD_FB_CLK, csi_frame_num,
                    fmt_pixel_cnt, fmt_line_cnt, hispi_word_v, vtg_ls};
endmodule
