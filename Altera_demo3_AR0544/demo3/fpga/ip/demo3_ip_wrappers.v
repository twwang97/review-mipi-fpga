//=====================================================================
// demo3_ip_wrappers.v
//
// Black-box declarations for every Altera/Intel vendor IP this design
// instantiates. Each one must be regenerated for your build with the
// Quartus II MegaWizard / Qsys and the parameters listed in the header
// comment. These stubs exist so the RTL elaborates for lint and for
// simulation against behavioural models.
//
// Device : Arria II GX  EP2AGX45DF25C4N
// Tool   : Quartus II 13.0sp1 / 13.1  (Arria II GX support ends at 13.1)
//=====================================================================
`timescale 1ns/1ps

//---------------------------------------------------------------------
// ALTPLL  (megafunction: altpll, library altera_mf)
//   operation_mode   = "NORMAL"
//   inclk0_frequency = 20000 ps (50 MHz)
//   c0 150 MHz, c1 100 MHz, c2 200 MHz, c3 74.25 MHz
//---------------------------------------------------------------------
module altpll_core (
   input  wire inclk0, input wire areset,
   output wire c0, output wire c1, output wire c2, output wire c3,
   output wire locked
);
   // synthesis translate_off
   reg c0r=0,c1r=0,c2r=0,c3r=0; reg lk=0;
   always #3.333 c0r = ~c0r;   always #5.000 c1r = ~c1r;
   always #2.500 c2r = ~c2r;   always #6.734 c3r = ~c3r;
   always @(posedge areset or negedge areset) lk <= 1'b0;
   initial begin #200; lk = 1'b1; end
   assign c0=c0r; assign c1=c1r; assign c2=c2r; assign c3=c3r; assign locked=lk;
   // synthesis translate_on
endmodule

//---------------------------------------------------------------------
// ALTLVDS_RX  (megafunction: altlvds_rx, library altera_mf)
//
// One instance per receiver family. Parameters that matter:
//   number_of_channels      = 4          (MIPI/HiSPi) or 1 (CCP)
//   deserialization_factor  = 8
//   registered_output       = "ON"
//   use_external_pll        = "OFF"
//   data_rate               = "768.0 Mbps" (MIPI) / "1000.0 Mbps" (HiSPi)
//   enable_dpa_mode         = "ON"        <-- the 768 Mbps/lane ceiling
//   enable_dpa_align_to_rising_edge_only = "OFF"
//   dpa_initial_phase_value = 0
//   input_data_rate         = matches data_rate
//   common_rx_tx_pll        = "ON"
//
// [INF] The documented Demo3 MIPI limit of 768 Mbps/lane is consistent
// with what ALTLVDS_RX + DPA sustains on this device family. Treat the
// causal link as an inference, not an onsemi statement.
//---------------------------------------------------------------------
module altlvds_rx_wrap #(
   parameter CHANNELS = 4,
   parameter J        = 8
) (
   input  wire                    rx_inclock,      // link clock lane
   input  wire                    rx_enable,
   input  wire                    rx_reset,
   input  wire                    rx_dpll_reset,
   input  wire [CHANNELS-1:0]     rx_in,           // LVDS pairs (P side; N inferred)
   input  wire [CHANNELS-1:0]     rx_channel_data_align,
   output wire [CHANNELS*J-1:0]   rx_out,
   output wire                    rx_outclock,     // = bitrate / J
   output wire                    rx_locked,
   output wire [CHANNELS-1:0]     rx_dpa_locked
);
   // synthesis translate_off
   assign rx_out       = {CHANNELS*J{1'b0}};
   assign rx_outclock  = rx_inclock;
   assign rx_locked    = 1'b1;
   assign rx_dpa_locked= {CHANNELS{1'b1}};
   // synthesis translate_on
endmodule

//---------------------------------------------------------------------
// DDR3 SDRAM Controller with UniPHY  (Altera External Memory Interface)
//   Memory : 64M x 16, 1 Gb, DDR3-800 or faster
//   Local interface : Avalon-MM slave, 128-bit data, burst up to 16
//   Generated instance name is user-chosen; rename to match your Qsys.
//---------------------------------------------------------------------
module ddr3_uniphy (
   input  wire         pll_ref_clk,
   input  wire         global_reset_n,
   input  wire         soft_reset_n,
   output wire         afi_clk,           // half-rate user clock
   output wire         afi_half_clk,
   output wire         afi_reset_n,
   output wire         local_init_done,
   output wire         local_cal_success,
   output wire         local_cal_fail,
   // Avalon-MM slave
   input  wire [26:0]  avl_addr,
   input  wire         avl_read_req,
   input  wire         avl_write_req,
   input  wire [4:0]   avl_burstbegin,
   input  wire [127:0] avl_wdata,
   input  wire [15:0]  avl_be,
   input  wire [4:0]   avl_size,
   output wire         avl_ready,
   output wire [127:0] avl_rdata,
   output wire         avl_rdata_valid,
   // memory pins
   output wire [13:0]  mem_a,     output wire [2:0]  mem_ba,
   output wire         mem_ck,    output wire        mem_ck_n,
   output wire         mem_cke,   output wire        mem_cs_n,
   output wire         mem_ras_n, output wire        mem_cas_n,
   output wire         mem_we_n,  output wire        mem_reset_n,
   output wire [1:0]   mem_dm,    inout  wire [15:0] mem_dq,
   inout  wire [1:0]   mem_dqs,   inout  wire [1:0]  mem_dqs_n,
   output wire         mem_odt
);
   // synthesis translate_off
   assign avl_ready = 1'b1; assign avl_rdata = 128'd0;
   assign avl_rdata_valid = 1'b0;
   assign local_init_done = 1'b1; assign local_cal_success = 1'b1;
   assign local_cal_fail = 1'b0;  assign afi_reset_n = 1'b1;
   // synthesis translate_on
endmodule

//---------------------------------------------------------------------
// DCFIFO  (megafunction: dcfifo, library altera_mf)
//   lpm_widthu sized by DEPTH, overflow/underflow checking ON,
//   rdsync_delaypipe = wrsync_delaypipe = 4
//---------------------------------------------------------------------
module dcfifo_wrap #(
   parameter W = 32, parameter DEPTH_LOG2 = 9
) (
   input  wire         aclr,
   input  wire         wrclk, input wire wrreq, input wire [W-1:0] data,
   output wire         wrfull, output wire [DEPTH_LOG2-1:0] wrusedw,
   input  wire         rdclk, input wire rdreq,
   output wire [W-1:0] q,     output wire rdempty,
   output wire [DEPTH_LOG2-1:0] rdusedw
);
   // Behavioural model good enough for block-level simulation.
   // synthesis translate_off
   reg [W-1:0] mem [0:(1<<DEPTH_LOG2)-1];
   reg [DEPTH_LOG2:0] wp = 0, rp = 0;
   reg [W-1:0] qr = 0;
   always @(posedge wrclk) if (wrreq && !wrfull) begin mem[wp[DEPTH_LOG2-1:0]] <= data; wp <= wp + 1; end
   always @(posedge rdclk) if (rdreq && !rdempty) begin qr <= mem[rp[DEPTH_LOG2-1:0]]; rp <= rp + 1; end
   assign wrfull  = ((wp - rp) >= (1<<DEPTH_LOG2)-2);
   assign rdempty = (wp == rp);
   assign wrusedw = wp[DEPTH_LOG2-1:0] - rp[DEPTH_LOG2-1:0];
   assign rdusedw = wrusedw;
   assign q = qr;
   // synthesis translate_on
endmodule

//---------------------------------------------------------------------
// ALTSYNCRAM  (megafunction: altsyncram, library altera_mf)
//   Simple dual-port, single clock, read-during-write = DONT_CARE.
//   Used for: DPCM decode table, I2C script RAM, HDMI init ROM.
//---------------------------------------------------------------------
module altsyncram_sdp #(
   parameter W = 16, parameter AW = 8
) (
   input  wire          clk,
   input  wire          we,
   input  wire [AW-1:0] waddr,
   input  wire [W-1:0]  wdata,
   input  wire [AW-1:0] raddr,
   output reg  [W-1:0]  rdata
);
   reg [W-1:0] mem [0:(1<<AW)-1];
   always @(posedge clk) begin
      if (we) mem[waddr] <= wdata;
      rdata <= mem[raddr];
   end
endmodule

//---------------------------------------------------------------------
// ALTDDIO_OUT  (megafunction: altddio_out, library altera_mf)
//   Used to forward the HDMI pixel clock and to drive DDR-clocked pins.
//---------------------------------------------------------------------
module altddio_out_wrap #(parameter W = 1) (
   input  wire         outclock,
   input  wire [W-1:0] datain_h,
   input  wire [W-1:0] datain_l,
   output wire [W-1:0] dataout
);
   // synthesis translate_off
   assign dataout = outclock ? datain_h : datain_l;
   // synthesis translate_on
endmodule

//---------------------------------------------------------------------
// ALTDDIO_IN  (megafunction: altddio_in, library altera_mf)
//   Optional: DDR capture of a parallel sensor interface.
//---------------------------------------------------------------------
module altddio_in_wrap #(parameter W = 1) (
   input  wire         inclock,
   input  wire [W-1:0] datain,
   output wire [W-1:0] dataout_h,
   output wire [W-1:0] dataout_l
);
   // synthesis translate_off
   reg [W-1:0] h, l;
   always @(posedge inclock) h <= datain;
   always @(negedge inclock) l <= datain;
   assign dataout_h = h; assign dataout_l = l;
   // synthesis translate_on
endmodule
