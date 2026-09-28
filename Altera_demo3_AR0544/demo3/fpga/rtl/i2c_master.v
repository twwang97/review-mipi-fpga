//=====================================================================
// i2c_master.v -- I2C master with clock stretching and arbitration
//
// Demo3 runs 100 kHz, 400 kHz and 1 MHz [EVBUM2310/D]. Known targets:
//   0x72 ADV7526 HDMI      0xD2 clock generator
//   0xA0 system EEPROM     headboard sensor + 0xA8 LSC EEPROM
//
// Open-drain pins: drive 0 or release to Z. scl_oe/sda_oe are active
// high "pull the line low".
//=====================================================================
`timescale 1ns/1ps

module i2c_master #(
   parameter CLK_HZ = 100_000_000
) (
   input  wire        clk,
   input  wire        rst_n,
   input  wire        cfg_en,
   input  wire [1:0]  cfg_speed,       // 0=100k 1=400k 2=1M

   // open-drain bus
   input  wire        scl_in,
   output reg         scl_oe,
   input  wire        sda_in,
   output reg         sda_oe,

   // command interface
   input  wire        c_go,
   input  wire        c_rw,            // 1 = read
   input  wire        c_start,         // emit a START (or repeated START)
   input  wire        c_stop,          // emit a STOP when the byte is done
   input  wire [7:0]  c_addr,          // 8-bit device address, LSB ignored
   input  wire [7:0]  c_wdata,
   output reg  [7:0]  c_rdata,
   output reg         c_busy,
   output reg         c_ack_n,
   output reg         c_arb_lost,
   output reg         c_done
);
   function integer div_for;
      input [1:0] s;
      begin
         case (s)
            2'd0:    div_for = CLK_HZ / (100_000*4);
            2'd1:    div_for = CLK_HZ / (400_000*4);
            default: div_for = CLK_HZ / (1_000_000*4);
         endcase
      end
   endfunction

   reg [15:0] div_cnt;
   reg [15:0] div_top;
   reg [1:0]  phase;                    // quarter-bit phase
   wire       tick = (div_cnt == 16'd0);

   always @(*) div_top = div_for(cfg_speed);

   localparam S_IDLE  = 4'd0, S_START = 4'd1, S_ADDR  = 4'd2,
              S_AACK  = 4'd3, S_WR    = 4'd4, S_WACK  = 4'd5,
              S_RD    = 4'd6, S_RACK  = 4'd7, S_STOP  = 4'd8,
              S_DONE  = 4'd9;

   reg [3:0] st;
   reg [3:0] bit_i;
   reg [7:0] sh;
   reg       do_stop, do_rw;

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         div_cnt <= 16'd0; phase <= 2'd0; st <= S_IDLE;
         scl_oe <= 1'b0; sda_oe <= 1'b0;
         bit_i <= 4'd0; sh <= 8'd0;
         c_rdata <= 8'd0; c_busy <= 1'b0; c_ack_n <= 1'b0;
         c_arb_lost <= 1'b0; c_done <= 1'b0;
         do_stop <= 1'b0; do_rw <= 1'b0;
      end else begin
         c_done <= 1'b0;

         if (!cfg_en) begin
            st <= S_IDLE; scl_oe <= 1'b0; sda_oe <= 1'b0; c_busy <= 1'b0;
         end else begin
            // quarter-bit timebase with clock-stretch support
            if (div_cnt != 16'd0) begin
               div_cnt <= div_cnt - 1'b1;
            end else begin
               div_cnt <= div_top;
               // a target holding SCL low freezes the phase counter
               if (!(phase == 2'd1 && !scl_oe && !scl_in))
                  phase <= phase + 1'b1;
            end

            case (st)
            //----------------------------------------------------------
            S_IDLE: begin
               scl_oe <= 1'b0; sda_oe <= 1'b0; c_busy <= 1'b0;
               c_arb_lost <= 1'b0;
               if (c_go) begin
                  c_busy  <= 1'b1;
                  sh      <= {c_addr[7:1], c_rw};
                  do_stop <= c_stop;
                  do_rw   <= c_rw;
                  bit_i   <= 4'd0;
                  phase   <= 2'd0;
                  div_cnt <= div_top;
                  st      <= c_start ? S_START : (c_rw ? S_RD : S_WR);
                  if (!c_start) sh <= c_wdata;
               end
            end
            //----------------------------------------------------------
            S_START: if (tick) case (phase)
               2'd0: begin sda_oe <= 1'b0; scl_oe <= 1'b0; end
               2'd1: sda_oe <= 1'b1;                 // SDA low while SCL high
               2'd3: begin scl_oe <= 1'b1; st <= S_ADDR; bit_i <= 4'd0; end
               default: ;
            endcase
            //----------------------------------------------------------
            S_ADDR, S_WR: if (tick) case (phase)
               2'd0: begin sda_oe <= ~sh[7]; scl_oe <= 1'b1; end
               2'd1: scl_oe <= 1'b0;
               2'd2: begin
                  // arbitration: we released SDA but someone pulled it low
                  if (!sda_oe && !sda_in) c_arb_lost <= 1'b1;
               end
               2'd3: begin
                  scl_oe <= 1'b1;
                  sh     <= {sh[6:0], 1'b0};
                  if (bit_i == 4'd7) begin
                     bit_i <= 4'd0;
                     st    <= (st == S_ADDR) ? S_AACK : S_WACK;
                  end else begin
                     bit_i <= bit_i + 1'b1;
                  end
               end
            endcase
            //----------------------------------------------------------
            S_AACK, S_WACK: if (tick) case (phase)
               2'd0: begin sda_oe <= 1'b0; scl_oe <= 1'b1; end
               2'd1: scl_oe <= 1'b0;
               2'd2: c_ack_n <= sda_in;
               2'd3: begin
                  scl_oe <= 1'b1;
                  if (st == S_AACK) begin
                     if (c_ack_n)      st <= S_STOP;
                     else if (do_rw)   st <= S_RD;
                     else begin sh <= c_wdata; st <= S_WR; end
                  end else begin
                     st <= do_stop ? S_STOP : S_DONE;
                  end
               end
            endcase
            //----------------------------------------------------------
            S_RD: if (tick) case (phase)
               2'd0: begin sda_oe <= 1'b0; scl_oe <= 1'b1; end
               2'd1: scl_oe <= 1'b0;
               2'd2: sh <= {sh[6:0], sda_in};
               2'd3: begin
                  scl_oe <= 1'b1;
                  if (bit_i == 4'd7) begin
                     bit_i   <= 4'd0;
                     c_rdata <= sh;
                     st      <= S_RACK;
                  end else begin
                     bit_i <= bit_i + 1'b1;
                  end
               end
            endcase
            //----------------------------------------------------------
            S_RACK: if (tick) case (phase)
               // NACK the last byte of a read, ACK otherwise
               2'd0: begin sda_oe <= ~do_stop; scl_oe <= 1'b1; end
               2'd1: scl_oe <= 1'b0;
               2'd3: begin
                  scl_oe <= 1'b1;
                  st     <= do_stop ? S_STOP : S_DONE;
               end
               default: ;
            endcase
            //----------------------------------------------------------
            S_STOP: if (tick) case (phase)
               2'd0: begin sda_oe <= 1'b1; scl_oe <= 1'b1; end
               2'd1: scl_oe <= 1'b0;
               2'd3: begin sda_oe <= 1'b0; st <= S_DONE; end
               default: ;
            endcase
            //----------------------------------------------------------
            S_DONE: begin
               c_done <= 1'b1;
               c_busy <= 1'b0;
               st     <= S_IDLE;
            end
            //----------------------------------------------------------
            default: st <= S_IDLE;
            endcase
         end
      end
   end
endmodule
