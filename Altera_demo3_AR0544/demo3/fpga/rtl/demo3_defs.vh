//=====================================================================
// demo3_defs.vh  -- global parameters and register map
// Target : Altera Arria II GX  EP2AGX45DF25C4N  (onsemi Demo3, AGB1N0CS-GEVK)
// Lang   : Verilog-2001
//=====================================================================
`ifndef DEMO3_DEFS_VH
`define DEMO3_DEFS_VH

`define D3_ID_CODE        32'hD3_00_01_00   // board id / rtl version

// ---- clocking -------------------------------------------------------
`define CORE_HZ           150_000_000       // FPGA core clock  [EVBUM2310/D]
`define MIPI_MAX_BPS      768_000_000       // per lane          [EVBUM2310/D]
`define HISPI_MAX_BPS    1000_000_000       // per lane          [EVBUM2310/D]
`define DESER_FACTOR      8                 // ALTLVDS_RX J factor

// ---- datapath widths ------------------------------------------------
`define BYTE_W            8
`define LANE_MAX          4
`define RXW              32                 // merged receiver byte-lane width
`define RXBE              4                 // byte enables for RXW
`define PIXW             16                 // pixel container (8/10/12/14/16 bit)
`define DDRW            128                 // DDR3 controller data width
`define AVL_AW            27                // Avalon-MM byte address width (1 Gb)

// ---- receiver source select ----------------------------------------
`define SRC_MIPI          2'd0
`define SRC_HISPI         2'd1
`define SRC_CCP           2'd2
`define SRC_PAR           2'd3

// ---- CSI-2 data types we decode ------------------------------------
`define DT_FS             6'h00
`define DT_FE             6'h01
`define DT_LS             6'h02
`define DT_LE             6'h03
`define DT_EMBEDDED       6'h12
`define DT_RAW8           6'h2A
`define DT_RAW10          6'h2B
`define DT_RAW12          6'h2C
`define DT_RAW14          6'h2D

// ---- register map (32-bit registers, word addressed) ----------------
`define R_ID              16'h0000  // RO  id / version
`define R_SCRATCH         16'h0001  // RW
`define R_GLOBAL_CTRL     16'h0002  // RW  [0]core_en [1]soft_rst [2]hb_pwr_en [3]capture_mode
`define R_GLOBAL_STAT     16'h0003  // RO
`define R_IRQ_STAT        16'h0004  // W1C
`define R_IRQ_ENA         16'h0005  // RW
`define R_IRQ_FORCE       16'h0006  // RW  test injection

`define R_RX_SEL          16'h0010  // RW  [1:0] source
`define R_RX_CTRL         16'h0011  // RW  [2:0]lanes-1 [7:4]bitdepth [8]dpcm_en [9]align_req
`define R_RX_STAT         16'h0012  // RO  lane lock / fifo flags
`define R_RX_FRAME_CNT    16'h0013  // RO
`define R_RX_LINE_CNT     16'h0014  // RO
`define R_RX_ERR_CNT      16'h0015  // RO  [7:0]ecc_corr [15:8]ecc_unc [31:16]crc_err
`define R_RX_FILTER       16'h0016  // RW  [1:0]vc [7:2]dt  [8]filter_en
`define R_HISPI_SYNC0     16'h0017  // RW  SOF / SOL codes
`define R_HISPI_SYNC1     16'h0018  // RW  EOF / EOL codes
`define R_PAR_CFG         16'h0019  // RW  [0]pixclk_edge [1]fv_pol [2]lv_pol [7:4]bitdepth
`define R_DPCM_ADDR       16'h001A  // RW  table write pointer
`define R_DPCM_DATA       16'h001B  // RW  table write data (auto-increments)

`define R_FB_CTRL         16'h0020  // RW  [0]en [1]capture [2]flush
`define R_FB_BASE0        16'h0021
`define R_FB_BASE1        16'h0022
`define R_FB_BASE2        16'h0023
`define R_FB_FRAME_BYTES  16'h0024
`define R_FB_STAT         16'h0025  // RO  [1:0]wr_buf [3:2]rd_buf [4]ready [5]ovf
`define R_FB_WR_CNT       16'h0026  // RO
`define R_FB_RD_CNT       16'h0027  // RO

`define R_VTG_CTRL        16'h0030  // RW  [0]en [1]mode(0=720p60,1=1080p60) [2]ext_timing
`define R_VTG_H0          16'h0031  // RW  {hactive, htotal}
`define R_VTG_H1          16'h0032  // RW  {hfront,  hsync }
`define R_VTG_V0          16'h0033  // RW  {vactive, vtotal}
`define R_VTG_V1          16'h0034  // RW  {vfront,  vsync }
`define R_HDMI_CTRL       16'h0035  // RW  [0]out_en [1]hs_pol [2]vs_pol [5:4]fmt

`define R_FX3_CTRL        16'h0040  // RW  [0]en [15:4]burst_len
`define R_FX3_STAT        16'h0041  // RO  [0]flaga [1]flagb [2]busy
`define R_FX3_XFER_CNT    16'h0042  // RO
`define R_FX3_PKTEND_TO   16'h0043  // RW  short-packet timeout, core clocks

`define R_I2C_CTRL        16'h0050  // RW  [0]en [2:1]speed [4:3]bus_sel
`define R_I2C_CMD         16'h0051  // WO  [0]go [1]rw [2]stop [3]start [15:8]dev_addr
`define R_I2C_WDATA       16'h0052  // RW
`define R_I2C_RDATA       16'h0053  // RO
`define R_I2C_STAT        16'h0054  // RO  [0]busy [1]ack_n [2]arb_lost [3]done
`define R_I2C_SEQ_CTRL    16'h0055  // RW  [0]run [15:8]len
`define R_I2C_SEQ_ADDR    16'h0056  // RW  script RAM pointer
`define R_I2C_SEQ_DATA    16'h0057  // RW  script RAM data (auto-increments)

`define R_SPI_CTRL        16'h0060  // RW  [0]cs_n [1]go [7:4]clk_div
`define R_SPI_TX          16'h0061  // RW
`define R_SPI_RX          16'h0062  // RO
`define R_SPI_STAT        16'h0063  // RO  [0]busy

`define R_HEAD_CTRL       16'h0070  // RW  [0]rst_n [1]rst_pulse [2]mclk_en [3]pwr_en
`define R_HEAD_SP_OUT     16'h0071  // RW  [5:0] SP drive values
`define R_HEAD_SP_OE      16'h0072  // RW  [5:0] SP output enables
`define R_HEAD_SP_IN      16'h0073  // RO  [5:0] SP readback
`define R_HEAD_MCLK_DIV   16'h0074  // RW  MCLK = CORE_HZ / (2*(div+1))
`define R_HEAD_RST_LEN    16'h0075  // RW  reset pulse length in core clocks
`define R_HEAD_TRIG       16'h0076  // RW  [2:0]sp_index [3]fire [31:16]width
`define R_HEAD_EVT_CNT    16'h0077  // RO  [15:0]flash edges [31:16]shutter edges

// ---- interrupt bit positions ---------------------------------------
`define IRQ_FRAME_START   0
`define IRQ_FRAME_END     1
`define IRQ_LINE_END      2
`define IRQ_FIFO_OVF      3
`define IRQ_FIFO_UNF      4
`define IRQ_ECC_CORR      5
`define IRQ_ECC_UNC       6
`define IRQ_CRC_ERR       7
`define IRQ_FB_READY      8
`define IRQ_FB_OVF        9
`define IRQ_I2C_DONE     10
`define IRQ_SPI_DONE     11
`define IRQ_HEAD_FLASH   12
`define IRQ_HEAD_SHUTTER 13
`define IRQ_VTG_VSYNC    14
`define IRQ_LANE_LOCK    15

`endif
