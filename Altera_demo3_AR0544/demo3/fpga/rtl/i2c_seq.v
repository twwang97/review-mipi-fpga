//=====================================================================
// i2c_seq.v -- scripted I2C initialisation sequencer
//
// Holds a host-loaded script in an ALTSYNCRAM and replays it against
// the i2c_master. This is how the ADV7526, the clock generator and the
// sensor register preset get programmed without hard-coding vendor
// register values into the RTL -- which matters here because the
// AR0544 register map is NDA-only and the ADV7526 init sequence is in
// Analog Devices' programming guide, not in EVBUM2310/D.
//
// Script word (32-bit):
//   [31:24] device address (8-bit, LSB = 0)
//   [23:16] register address
//   [15:8]  data
//   [7]     last entry
//   [6:0]   reserved
//=====================================================================
`timescale 1ns/1ps

module i2c_seq (
   input  wire        clk,
   input  wire        rst_n,

   // script RAM load port
   input  wire        ld_we,
   input  wire [7:0]  ld_addr,
   input  wire [31:0] ld_data,

   input  wire        run,
   input  wire [7:0]  len,
   output reg         busy,
   output reg         err,

   // to i2c_master (arbitrated upstream with the direct register path)
   output reg         c_go,
   output reg         c_rw,
   output reg         c_start,
   output reg         c_stop,
   output reg  [7:0]  c_addr,
   output reg  [7:0]  c_wdata,
   input  wire        c_busy,
   input  wire        c_ack_n,
   input  wire        c_done
);
   wire [31:0] ram_q;
   reg  [7:0]  ptr;

   altsyncram_sdp #(.W(32), .AW(8)) u_script (
      .clk(clk), .we(ld_we), .waddr(ld_addr), .wdata(ld_data),
      .raddr(ptr), .rdata(ram_q));

   localparam S_IDLE = 3'd0, S_FETCH = 3'd1, S_DEV = 3'd2,
              S_REG  = 3'd3, S_DAT   = 3'd4, S_NEXT = 3'd5;

   reg [2:0] st;

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         st <= S_IDLE; ptr <= 8'd0; busy <= 1'b0; err <= 1'b0;
         c_go <= 1'b0; c_rw <= 1'b0; c_start <= 1'b0; c_stop <= 1'b0;
         c_addr <= 8'd0; c_wdata <= 8'd0;
      end else begin
         c_go <= 1'b0;
         case (st)
         S_IDLE: begin
            busy <= 1'b0;
            if (run) begin ptr <= 8'd0; err <= 1'b0; busy <= 1'b1; st <= S_FETCH; end
         end
         S_FETCH: st <= S_DEV;                     // RAM read latency
         S_DEV: if (!c_busy) begin
            c_addr  <= ram_q[31:24];
            c_wdata <= ram_q[23:16];
            c_rw    <= 1'b0;
            c_start <= 1'b1;
            c_stop  <= 1'b0;
            c_go    <= 1'b1;
            st      <= S_REG;
         end
         S_REG: if (c_done) begin
            if (c_ack_n) begin err <= 1'b1; st <= S_IDLE; end
            else begin
               c_wdata <= ram_q[15:8];
               c_start <= 1'b0;
               c_stop  <= 1'b1;
               c_go    <= 1'b1;
               st      <= S_DAT;
            end
         end
         S_DAT: if (c_done) begin
            if (c_ack_n) err <= 1'b1;
            st <= S_NEXT;
         end
         S_NEXT: begin
            if (ram_q[7] || (ptr + 1'b1) >= len) begin
               st <= S_IDLE;
            end else begin
               ptr <= ptr + 1'b1;
               st  <= S_FETCH;
            end
         end
         default: st <= S_IDLE;
         endcase
      end
   end
endmodule
