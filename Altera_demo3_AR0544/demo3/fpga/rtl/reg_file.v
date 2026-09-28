//=====================================================================
// reg_file.v -- control/status register plane
// Single-cycle, core clock. Accessed from fx3_slave_fifo.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module reg_file (
   input  wire        clk,
   input  wire        rst_n,

   input  wire [15:0] a,
   input  wire [31:0] wd,
   input  wire        we,
   input  wire        re,
   output reg  [31:0] rd,
   output reg         ready,

   // ---- global ------------------------------------------------------
   output reg         o_core_en,
   output reg         o_soft_rst,
   output reg         o_capture_mode,
   input  wire [31:0] i_global_stat,

   // ---- interrupts --------------------------------------------------
   output reg  [31:0] o_irq_ena,
   output reg  [31:0] o_irq_force,
   output reg  [31:0] o_irq_clr,
   output reg         o_irq_clr_stb,
   input  wire [31:0] i_irq_stat,

   // ---- receivers ---------------------------------------------------
   output reg  [1:0]  o_rx_sel,
   output reg  [2:0]  o_rx_lanes_m1,
   output reg  [3:0]  o_rx_bitdepth,
   output reg         o_rx_dpcm_en,
   output reg         o_rx_align_req,
   input  wire [31:0] i_rx_stat,
   input  wire [31:0] i_rx_frame_cnt,
   input  wire [31:0] i_rx_line_cnt,
   input  wire [31:0] i_rx_err_cnt,
   output reg         o_filter_en,
   output reg  [1:0]  o_filter_vc,
   output reg  [5:0]  o_filter_dt,
   output reg  [11:0] o_hispi_sof, output reg [11:0] o_hispi_sol,
   output reg  [11:0] o_hispi_eof, output reg [11:0] o_hispi_eol,
   output reg         o_par_fv_pol, output reg o_par_lv_pol,
   output reg  [3:0]  o_par_bitdepth,
   output reg  [7:0]  o_dpcm_addr,
   output reg  [15:0] o_dpcm_data,
   output reg         o_dpcm_we,

   // ---- frame buffer ------------------------------------------------
   output reg         o_fb_en,
   output reg         o_fb_flush,
   output reg  [`AVL_AW-1:0] o_fb_base0,
   output reg  [`AVL_AW-1:0] o_fb_base1,
   output reg  [`AVL_AW-1:0] o_fb_base2,
   output reg  [31:0] o_fb_frame_bytes,
   input  wire [31:0] i_fb_stat,
   input  wire [31:0] i_fb_wr_cnt,
   input  wire [31:0] i_fb_rd_cnt,

   // ---- video / HDMI ------------------------------------------------
   output reg         o_vtg_en, output reg o_vtg_mode, output reg o_vtg_ext,
   output reg  [15:0] o_htotal, output reg [15:0] o_hactive,
   output reg  [15:0] o_hfront, output reg [15:0] o_hsync,
   output reg  [15:0] o_vtotal, output reg [15:0] o_vactive,
   output reg  [15:0] o_vfront, output reg [15:0] o_vsync,
   output reg         o_hdmi_en, output reg o_hs_pol, output reg o_vs_pol,
   output reg  [1:0]  o_hdmi_fmt,

   // ---- FX3 ---------------------------------------------------------
   output reg         o_fx3_en,
   output reg  [11:0] o_fx3_burst,
   output reg  [15:0] o_fx3_pktend_to,
   input  wire [31:0] i_fx3_stat,
   input  wire [31:0] i_fx3_xfer_cnt,

   // ---- I2C ---------------------------------------------------------
   output reg         o_i2c_en,
   output reg  [1:0]  o_i2c_speed,
   output reg         o_i2c_go, output reg o_i2c_rw,
   output reg         o_i2c_start, output reg o_i2c_stop,
   output reg  [7:0]  o_i2c_addr, output reg [7:0] o_i2c_wdata,
   input  wire [31:0] i_i2c_stat,
   input  wire [7:0]  i_i2c_rdata,
   output reg         o_i2c_seq_run,
   output reg  [7:0]  o_i2c_seq_len,
   output reg  [7:0]  o_i2c_seq_addr,
   output reg  [31:0] o_i2c_seq_data,
   output reg         o_i2c_seq_we,

   // ---- SPI ---------------------------------------------------------
   output reg         o_spi_cs_n, output reg o_spi_go,
   output reg  [3:0]  o_spi_div,
   output reg  [7:0]  o_spi_tx,
   input  wire [7:0]  i_spi_rx,
   input  wire [31:0] i_spi_stat,

   // ---- headboard ---------------------------------------------------
   output reg         o_head_rst_n, output reg o_head_rst_pulse,
   output reg         o_mclk_en,    output reg o_head_pwr_en,
   output reg  [5:0]  o_sp_out, output reg [5:0] o_sp_oe,
   output reg  [15:0] o_mclk_div,
   output reg  [31:0] o_head_rst_len,
   output reg  [2:0]  o_trig_idx, output reg o_trig_fire,
   output reg  [15:0] o_trig_width,
   input  wire [5:0]  i_sp_in,
   input  wire [31:0] i_head_evt_cnt
);
   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         o_core_en<=0; o_soft_rst<=0; o_capture_mode<=0;
         o_irq_ena<=0; o_irq_force<=0; o_irq_clr<=0; o_irq_clr_stb<=0;
         o_rx_sel<=`SRC_MIPI; o_rx_lanes_m1<=3'd1; o_rx_bitdepth<=4'd10;
         o_rx_dpcm_en<=0; o_rx_align_req<=0;
         o_filter_en<=0; o_filter_vc<=0; o_filter_dt<=`DT_RAW10;
         o_hispi_sof<=0; o_hispi_sol<=0; o_hispi_eof<=0; o_hispi_eol<=0;
         o_par_fv_pol<=0; o_par_lv_pol<=0; o_par_bitdepth<=4'd12;
         o_dpcm_addr<=0; o_dpcm_data<=0; o_dpcm_we<=0;
         o_fb_en<=0; o_fb_flush<=0;
         o_fb_base0<=0; o_fb_base1<=0; o_fb_base2<=0; o_fb_frame_bytes<=0;
         o_vtg_en<=0; o_vtg_mode<=0; o_vtg_ext<=0;
         o_htotal<=0; o_hactive<=0; o_hfront<=0; o_hsync<=0;
         o_vtotal<=0; o_vactive<=0; o_vfront<=0; o_vsync<=0;
         o_hdmi_en<=0; o_hs_pol<=0; o_vs_pol<=0; o_hdmi_fmt<=0;
         o_fx3_en<=0; o_fx3_burst<=12'd256; o_fx3_pktend_to<=16'd4096;
         o_i2c_en<=0; o_i2c_speed<=2'd1;
         o_i2c_go<=0; o_i2c_rw<=0; o_i2c_start<=0; o_i2c_stop<=0;
         o_i2c_addr<=0; o_i2c_wdata<=0;
         o_i2c_seq_run<=0; o_i2c_seq_len<=0;
         o_i2c_seq_addr<=0; o_i2c_seq_data<=0; o_i2c_seq_we<=0;
         o_spi_cs_n<=1; o_spi_go<=0; o_spi_div<=4'd3; o_spi_tx<=0;
         o_head_rst_n<=1; o_head_rst_pulse<=0; o_mclk_en<=0; o_head_pwr_en<=0;
         o_sp_out<=0; o_sp_oe<=0; o_mclk_div<=16'd2;
         o_head_rst_len<=32'd36_000_000;      // 240 ms at 150 MHz
         o_trig_idx<=0; o_trig_fire<=0; o_trig_width<=16'd150;
         rd<=0; ready<=0;
      end else begin
         // self-clearing strobes
         o_irq_clr_stb    <= 1'b0;
         o_dpcm_we        <= 1'b0;
         o_i2c_seq_we     <= 1'b0;
         o_i2c_go         <= 1'b0;
         o_spi_go         <= 1'b0;
         o_head_rst_pulse <= 1'b0;
         o_trig_fire      <= 1'b0;
         o_soft_rst       <= 1'b0;
         o_fb_flush       <= 1'b0;
         o_rx_align_req   <= 1'b0;
         o_i2c_seq_run    <= 1'b0;
         ready            <= 1'b0;

         //--------------------------------------------------------- write
         if (we) begin
            ready <= 1'b1;
            case (a)
            `R_SCRATCH:       rd <= wd;
            `R_GLOBAL_CTRL:   begin o_core_en<=wd[0]; o_soft_rst<=wd[1];
                                    o_head_pwr_en<=wd[2]; o_capture_mode<=wd[3]; end
            `R_IRQ_STAT:      begin o_irq_clr<=wd; o_irq_clr_stb<=1'b1; end
            `R_IRQ_ENA:       o_irq_ena<=wd;
            `R_IRQ_FORCE:     o_irq_force<=wd;

            `R_RX_SEL:        o_rx_sel<=wd[1:0];
            `R_RX_CTRL:       begin o_rx_lanes_m1<=wd[2:0]; o_rx_bitdepth<=wd[7:4];
                                    o_rx_dpcm_en<=wd[8]; o_rx_align_req<=wd[9]; end
            `R_RX_FILTER:     begin o_filter_vc<=wd[1:0]; o_filter_dt<=wd[7:2];
                                    o_filter_en<=wd[8]; end
            `R_HISPI_SYNC0:   begin o_hispi_sof<=wd[11:0]; o_hispi_sol<=wd[27:16]; end
            `R_HISPI_SYNC1:   begin o_hispi_eof<=wd[11:0]; o_hispi_eol<=wd[27:16]; end
            `R_PAR_CFG:       begin o_par_fv_pol<=wd[1]; o_par_lv_pol<=wd[2];
                                    o_par_bitdepth<=wd[7:4]; end
            `R_DPCM_ADDR:     o_dpcm_addr<=wd[7:0];
            `R_DPCM_DATA:     begin o_dpcm_data<=wd[15:0]; o_dpcm_we<=1'b1;
                                    o_dpcm_addr<=o_dpcm_addr+1'b1; end

            `R_FB_CTRL:       begin o_fb_en<=wd[0]; o_capture_mode<=wd[1];
                                    o_fb_flush<=wd[2]; end
            `R_FB_BASE0:      o_fb_base0<=wd[`AVL_AW-1:0];
            `R_FB_BASE1:      o_fb_base1<=wd[`AVL_AW-1:0];
            `R_FB_BASE2:      o_fb_base2<=wd[`AVL_AW-1:0];
            `R_FB_FRAME_BYTES:o_fb_frame_bytes<=wd;

            `R_VTG_CTRL:      begin o_vtg_en<=wd[0]; o_vtg_mode<=wd[1]; o_vtg_ext<=wd[2]; end
            `R_VTG_H0:        begin o_htotal<=wd[15:0];  o_hactive<=wd[31:16]; end
            `R_VTG_H1:        begin o_hsync <=wd[15:0];  o_hfront <=wd[31:16]; end
            `R_VTG_V0:        begin o_vtotal<=wd[15:0];  o_vactive<=wd[31:16]; end
            `R_VTG_V1:        begin o_vsync <=wd[15:0];  o_vfront <=wd[31:16]; end
            `R_HDMI_CTRL:     begin o_hdmi_en<=wd[0]; o_hs_pol<=wd[1];
                                    o_vs_pol<=wd[2]; o_hdmi_fmt<=wd[5:4]; end

            `R_FX3_CTRL:      begin o_fx3_en<=wd[0]; o_fx3_burst<=wd[15:4]; end
            `R_FX3_PKTEND_TO: o_fx3_pktend_to<=wd[15:0];

            `R_I2C_CTRL:      begin o_i2c_en<=wd[0]; o_i2c_speed<=wd[2:1]; end
            `R_I2C_CMD:       begin o_i2c_go<=wd[0]; o_i2c_rw<=wd[1];
                                    o_i2c_stop<=wd[2]; o_i2c_start<=wd[3];
                                    o_i2c_addr<=wd[15:8]; end
            `R_I2C_WDATA:     o_i2c_wdata<=wd[7:0];
            `R_I2C_SEQ_CTRL:  begin o_i2c_seq_run<=wd[0]; o_i2c_seq_len<=wd[15:8]; end
            `R_I2C_SEQ_ADDR:  o_i2c_seq_addr<=wd[7:0];
            `R_I2C_SEQ_DATA:  begin o_i2c_seq_data<=wd; o_i2c_seq_we<=1'b1;
                                    o_i2c_seq_addr<=o_i2c_seq_addr+1'b1; end

            `R_SPI_CTRL:      begin o_spi_cs_n<=wd[0]; o_spi_go<=wd[1];
                                    o_spi_div<=wd[7:4]; end
            `R_SPI_TX:        o_spi_tx<=wd[7:0];

            `R_HEAD_CTRL:     begin o_head_rst_n<=wd[0]; o_head_rst_pulse<=wd[1];
                                    o_mclk_en<=wd[2]; o_head_pwr_en<=wd[3]; end
            `R_HEAD_SP_OUT:   o_sp_out<=wd[5:0];
            `R_HEAD_SP_OE:    o_sp_oe<=wd[5:0];
            `R_HEAD_MCLK_DIV: o_mclk_div<=wd[15:0];
            `R_HEAD_RST_LEN:  o_head_rst_len<=wd;
            `R_HEAD_TRIG:     begin o_trig_idx<=wd[2:0]; o_trig_fire<=wd[3];
                                    o_trig_width<=wd[31:16]; end
            default: ;
            endcase
         end
         //---------------------------------------------------------- read
         else if (re) begin
            ready <= 1'b1;
            case (a)
            `R_ID:            rd <= `D3_ID_CODE;
            `R_GLOBAL_CTRL:   rd <= {28'd0, o_capture_mode, o_head_pwr_en, 1'b0, o_core_en};
            `R_GLOBAL_STAT:   rd <= i_global_stat;
            `R_IRQ_STAT:      rd <= i_irq_stat;
            `R_IRQ_ENA:       rd <= o_irq_ena;

            `R_RX_SEL:        rd <= {30'd0, o_rx_sel};
            `R_RX_CTRL:       rd <= {22'd0, o_rx_align_req, o_rx_dpcm_en,
                                     o_rx_bitdepth, 1'b0, o_rx_lanes_m1};
            `R_RX_STAT:       rd <= i_rx_stat;
            `R_RX_FRAME_CNT:  rd <= i_rx_frame_cnt;
            `R_RX_LINE_CNT:   rd <= i_rx_line_cnt;
            `R_RX_ERR_CNT:    rd <= i_rx_err_cnt;

            `R_FB_STAT:       rd <= i_fb_stat;
            `R_FB_WR_CNT:     rd <= i_fb_wr_cnt;
            `R_FB_RD_CNT:     rd <= i_fb_rd_cnt;
            `R_FB_FRAME_BYTES:rd <= o_fb_frame_bytes;

            `R_FX3_STAT:      rd <= i_fx3_stat;
            `R_FX3_XFER_CNT:  rd <= i_fx3_xfer_cnt;

            `R_I2C_STAT:      rd <= i_i2c_stat;
            `R_I2C_RDATA:     rd <= {24'd0, i_i2c_rdata};

            `R_SPI_RX:        rd <= {24'd0, i_spi_rx};
            `R_SPI_STAT:      rd <= i_spi_stat;

            `R_HEAD_SP_IN:    rd <= {26'd0, i_sp_in};
            `R_HEAD_EVT_CNT:  rd <= i_head_evt_cnt;
            `R_HEAD_MCLK_DIV: rd <= {16'd0, o_mclk_div};
            `R_HEAD_RST_LEN:  rd <= o_head_rst_len;
            default:          rd <= 32'hDEAD_0000 | {16'd0, a};
            endcase
         end
      end
   end
endmodule
