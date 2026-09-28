//=====================================================================
// fx3_slave_fifo.v -- Cypress FX3 GPIF II synchronous slave FIFO master
//
// The FPGA is the master: it drives PCLK, the address/thread select and
// the strobes; FX3 is the slave FIFO. 32-bit bus, <= 5 Gb/s
// [EVBUM2310/D], which is also where the "14 configurable control pins"
// on GPIF II go.
//
// Thread map (A[1:0]):
//   00  video   FPGA -> FX3 -> USB IN   (frame data)
//   01  resp    FPGA -> FX3 -> USB IN   (register read responses)
//   10  cmd     USB OUT -> FX3 -> FPGA  (register read/write commands)
//
// Command protocol on thread 10, two 32-bit words:
//   word0 = { 8'hA5, 7'b0, rw, 16'addr }   rw: 1 = write, 0 = read
//   word1 = write data (ignored for reads)
// Read responses come back on thread 01 as { 16'addr, 16'b0 } then data.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module fx3_slave_fifo (
   input  wire        clk,             // core clock, also forwarded as PCLK
   input  wire        rst_n,
   input  wire        cfg_en,
   input  wire [11:0] cfg_burst,
   input  wire [15:0] cfg_pktend_to,

   // FX3 pins
   output wire        fx3_pclk,
   inout  wire [31:0] fx3_dq,
   output reg  [1:0]  fx3_addr,
   output reg         fx3_slcs_n,
   output reg         fx3_slwr_n,
   output reg         fx3_slrd_n,
   output reg         fx3_sloe_n,
   output reg         fx3_pktend_n,
   input  wire        fx3_flaga,       // current thread ready / not full
   input  wire        fx3_flagb,       // current thread not empty (read thread)

   // video stream in
   input  wire [31:0] v_data,
   input  wire        v_valid,
   output reg         v_ready,
   input  wire        v_frame_done,

   // register bus out
   output reg  [15:0] reg_addr,
   output reg  [31:0] reg_wdata,
   output reg         reg_we,
   output reg         reg_re,
   input  wire [31:0] reg_rdata,
   input  wire        reg_ready,

   output reg  [31:0] st_xfer_cnt,
   output reg         st_busy
);
   altddio_out_wrap #(1) u_pclk (
      .outclock(clk), .datain_h(1'b1), .datain_l(1'b0), .dataout(fx3_pclk));

   reg        dq_oe;
   reg [31:0] dq_out;
   wire [31:0] dq_in = fx3_dq;
   assign fx3_dq = dq_oe ? dq_out : 32'bz;

   localparam T_VIDEO = 2'b00, T_RESP = 2'b01, T_CMD = 2'b10;

   localparam S_IDLE   = 4'd0,
              S_VSEL   = 4'd1,
              S_VWR    = 4'd2,
              S_PKTEND = 4'd3,
              S_CSEL   = 4'd4,
              S_CRD0   = 4'd5,
              S_CRD1   = 4'd6,
              S_EXEC   = 4'd7,
              S_RSEL   = 4'd8,
              S_RWR0   = 4'd9,
              S_RWR1   = 4'd10;

   reg [3:0]  st;
   reg [11:0] burst;
   reg [15:0] idle_cnt;
   reg [31:0] cmd0, cmd1;
   reg        pend_read;
   reg [1:0]  poll;

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         st <= S_IDLE; burst <= 12'd0; idle_cnt <= 16'd0;
         fx3_addr <= T_VIDEO;
         fx3_slcs_n <= 1'b1; fx3_slwr_n <= 1'b1;
         fx3_slrd_n <= 1'b1; fx3_sloe_n <= 1'b1; fx3_pktend_n <= 1'b1;
         dq_oe <= 1'b0; dq_out <= 32'd0;
         v_ready <= 1'b0;
         reg_addr <= 16'd0; reg_wdata <= 32'd0;
         reg_we <= 1'b0; reg_re <= 1'b0;
         cmd0 <= 32'd0; cmd1 <= 32'd0; pend_read <= 1'b0;
         st_xfer_cnt <= 32'd0; st_busy <= 1'b0; poll <= 2'd0;
      end else begin
         v_ready      <= 1'b0;
         reg_we       <= 1'b0;
         reg_re       <= 1'b0;
         fx3_pktend_n <= 1'b1;

         if (!cfg_en) begin
            st <= S_IDLE;
            fx3_slcs_n <= 1'b1; fx3_slwr_n <= 1'b1;
            fx3_slrd_n <= 1'b1; fx3_sloe_n <= 1'b1;
            dq_oe <= 1'b0; st_busy <= 1'b0;
         end else begin
         case (st)
         //--------------------------------------------------------------
         S_IDLE: begin
            fx3_slcs_n <= 1'b1; fx3_slwr_n <= 1'b1;
            fx3_slrd_n <= 1'b1; fx3_sloe_n <= 1'b1;
            dq_oe   <= 1'b0;
            st_busy <= 1'b0;
            poll    <= poll + 1'b1;

            // service host commands on every 4th idle turn so a stalled
            // video path can never lock the register plane out
            if (poll == 2'd3) begin
               fx3_addr <= T_CMD;
               st       <= S_CSEL;
            end else if (v_valid) begin
               fx3_addr <= T_VIDEO;
               st       <= S_VSEL;
            end else if (idle_cnt >= cfg_pktend_to && v_frame_done) begin
               fx3_addr <= T_VIDEO;
               st       <= S_PKTEND;
            end else begin
               idle_cnt <= idle_cnt + 1'b1;
            end
         end
         //--------------------------------------------------------------
         S_VSEL: begin
            fx3_slcs_n <= 1'b0;
            fx3_sloe_n <= 1'b1;
            dq_oe      <= 1'b1;
            burst      <= 12'd0;
            st_busy    <= 1'b1;
            idle_cnt   <= 16'd0;
            st         <= fx3_flaga ? S_VWR : S_IDLE;
         end
         //--------------------------------------------------------------
         S_VWR: begin
            if (fx3_flaga && v_valid) begin
               dq_out      <= v_data;
               fx3_slwr_n  <= 1'b0;
               v_ready     <= 1'b1;
               burst       <= burst + 1'b1;
               st_xfer_cnt <= st_xfer_cnt + 32'd4;
            end else begin
               fx3_slwr_n <= 1'b1;
            end
            if (!fx3_flaga || !v_valid || (burst >= cfg_burst)) begin
               fx3_slwr_n <= 1'b1;
               st <= v_frame_done ? S_PKTEND : S_IDLE;
            end
         end
         //--------------------------------------------------------------
         S_PKTEND: begin
            fx3_slcs_n   <= 1'b0;
            fx3_pktend_n <= 1'b0;
            idle_cnt     <= 16'd0;
            st           <= S_IDLE;
         end
         //--------------------------------------------------------------
         S_CSEL: begin
            dq_oe      <= 1'b0;
            fx3_slcs_n <= 1'b0;
            fx3_sloe_n <= 1'b0;
            st         <= fx3_flagb ? S_CRD0 : S_IDLE;
         end
         //--------------------------------------------------------------
         S_CRD0: begin
            fx3_slrd_n <= 1'b0;
            cmd0       <= dq_in;
            st         <= S_CRD1;
         end
         //--------------------------------------------------------------
         S_CRD1: begin
            cmd1       <= dq_in;
            fx3_slrd_n <= 1'b1;
            fx3_sloe_n <= 1'b1;
            fx3_slcs_n <= 1'b1;
            st         <= S_EXEC;
         end
         //--------------------------------------------------------------
         S_EXEC: begin
            if (cmd0[31:24] == 8'hA5) begin
               reg_addr  <= cmd0[15:0];
               reg_wdata <= cmd1;
               if (cmd0[16]) begin
                  reg_we    <= 1'b1;
                  pend_read <= 1'b0;
                  st        <= S_IDLE;
               end else begin
                  reg_re    <= 1'b1;
                  pend_read <= 1'b1;
                  st        <= S_RSEL;
               end
            end else begin
               st <= S_IDLE;                      // bad magic, drop it
            end
         end
         //--------------------------------------------------------------
         S_RSEL: if (reg_ready) begin
            fx3_addr   <= T_RESP;
            fx3_slcs_n <= 1'b0;
            dq_oe      <= 1'b1;
            dq_out     <= {16'd0, reg_addr};
            st         <= fx3_flaga ? S_RWR0 : S_IDLE;
         end
         //--------------------------------------------------------------
         S_RWR0: begin
            fx3_slwr_n <= 1'b0;
            dq_out     <= reg_rdata;
            st         <= S_RWR1;
         end
         //--------------------------------------------------------------
         S_RWR1: begin
            fx3_slwr_n   <= 1'b1;
            fx3_pktend_n <= 1'b0;
            fx3_slcs_n   <= 1'b1;
            dq_oe        <= 1'b0;
            pend_read    <= 1'b0;
            st           <= S_IDLE;
         end
         //--------------------------------------------------------------
         default: st <= S_IDLE;
         endcase
         end
      end
   end
endmodule
