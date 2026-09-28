#=====================================================================
# demo3.sdc -- TimeQuest constraints for demo3_top
# Device: Altera Arria II GX EP2AGX45DF25C4N
#=====================================================================

# ---- primary clocks -------------------------------------------------
create_clock -name ref_clk   -period 20.000 [get_ports REF_CLK]
create_clock -name mh_clk    -period  2.604 [get_ports MH_CLK_P]   ;# 768 Mbps / 2 (DDR)
create_clock -name s_pixclk  -period  8.000 [get_ports S_PIXCLK]   ;# >= 125 MHz
create_clock -name head_dclk -period  8.000 [get_ports HEAD_DCLK]
create_clock -name head_fbclk -period 6.667 [get_ports HEAD_FB_CLK]

derive_pll_clocks
derive_clock_uncertainty

set core_clk [get_clocks {u_clk|*altpll*|*clk[0]}]
set ctrl_clk [get_clocks {u_clk|*altpll*|*clk[1]}]
set pix_clk  [get_clocks {u_clk|*altpll*|*clk[3]}]

# ---- generated output clocks ---------------------------------------
create_generated_clock -name fx3_pclk -source $core_clk [get_ports FX3_PCLK]
create_generated_clock -name hdmi_clk -source $pix_clk  [get_ports HDMI_CLK]

# ---- asynchronous clock groups -------------------------------------
# The sensor link, the parallel pixel clock and the FPGA core are
# independent sources. Every crossing between them goes through a
# DCFIFO or a two-flop synchroniser, so cut the paths.
set_clock_groups -asynchronous \
   -group {ref_clk} \
   -group [get_clocks {u_clk|*altpll*|*}] \
   -group {mh_clk} \
   -group {s_pixclk} \
   -group {head_dclk} \
   -group {head_fbclk}

# ---- CDC false paths ------------------------------------------------
set_false_path -to [get_pins -compatibility_mode {*cdc_sync*|s0*|d}]
set_false_path -to [get_pins -compatibility_mode {*rst_sync*|r0*|clrn}]

# ---- FX3 GPIF II, synchronous slave FIFO ----------------------------
# FPGA is the master and sources PCLK. Budget from the FX3 data sheet:
# tSU/tH on FLAGA/FLAGB and DQ inputs, tCO on DQ outputs.
set fx3_out [get_ports {FX3_DQ[*] FX3_ADDR[*] FX3_SLCS_N FX3_SLWR_N \
                        FX3_SLRD_N FX3_SLOE_N FX3_PKTEND_N}]
set_output_delay -clock fx3_pclk -max  2.0 $fx3_out
set_output_delay -clock fx3_pclk -min -0.5 $fx3_out

set fx3_in [get_ports {FX3_DQ[*] FX3_FLAGA FX3_FLAGB}]
set_input_delay -clock fx3_pclk -max  4.0 $fx3_in
set_input_delay -clock fx3_pclk -min  0.5 $fx3_in

# ---- ADV7526 HDMI bus ----------------------------------------------
set hdmi_out [get_ports {HDMI_D[*] HDMI_HS HDMI_VS HDMI_DE}]
set_output_delay -clock hdmi_clk -max  1.5 $hdmi_out
set_output_delay -clock hdmi_clk -min -0.5 $hdmi_out
set_false_path -from [get_ports HDMI_INT_N]

# ---- parallel sensor bus -------------------------------------------
set par_in [get_ports {S_DATA[*] S_FRAME_VALID S_LINE_VALID}]
set_input_delay -clock s_pixclk -max 3.0 $par_in
set_input_delay -clock s_pixclk -min 0.5 $par_in

# ---- slow / static pins: no timing requirement ----------------------
set_false_path -from [get_ports {POR_N SP[*] HEAD_MISO SPI_MISO}]
set_false_path -to   [get_ports {HEAD_RESET_L HEAD_PWR_EN MCLK SP[*] \
                                 HEAD_MOSI HEAD_SSN SPI_SCLK SPI_MOSI SPI_CS_N}]
set_false_path -from [get_ports {HEAD_SCL HEAD_SDA BRD_SCL BRD_SDA}]
set_false_path -to   [get_ports {HEAD_SCL HEAD_SDA BRD_SCL BRD_SDA}]

# ---- multicycle: register plane runs far slower than the datapath ---
set_multicycle_path -setup 4 -to [get_registers {*u_regs|o_*}]
set_multicycle_path -hold  3 -to [get_registers {*u_regs|o_*}]
