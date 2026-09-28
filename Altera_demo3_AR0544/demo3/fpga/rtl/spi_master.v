//=====================================================================
// spi_master.v -- generic 8-bit SPI master, mode 0
//
// On Demo3 the FPGA configuration EPROM is normally owned by the FX3
// SPI master [EVBUM2310/D]; this block exists so the FPGA can take the
// bus when FX3 hands it over (or for a second SPI peripheral on a
// headboard through HEAD_MOSI / HEAD_MISO / HEAD_SSN).
//=====================================================================
`timescale 1ns/1ps

module spi_master (
   input  wire        clk,
   input  wire        rst_n,
   input  wire [3:0]  cfg_div,         // sclk = clk / (2*(div+1))
   input  wire        cfg_cs_n,        // software chip select

   input  wire        go,
   input  wire [7:0]  tx,
   output reg  [7:0]  rx,
   output reg         busy,
   output reg         done,

   output reg         spi_sclk,
   output reg         spi_mosi,
   input  wire        spi_miso,
   output wire        spi_cs_n
);
   assign spi_cs_n = cfg_cs_n;

   reg [3:0] div;
   reg [3:0] bit_i;
   reg [7:0] sh;
   reg       running;

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         div <= 4'd0; bit_i <= 4'd0; sh <= 8'd0;
         spi_sclk <= 1'b0; spi_mosi <= 1'b0;
         rx <= 8'd0; busy <= 1'b0; done <= 1'b0; running <= 1'b0;
      end else begin
         done <= 1'b0;
         if (!running) begin
            spi_sclk <= 1'b0;
            if (go) begin
               sh <= tx; bit_i <= 4'd0; div <= 4'd0;
               spi_mosi <= tx[7];
               running <= 1'b1; busy <= 1'b1;
            end
         end else if (div != cfg_div) begin
            div <= div + 1'b1;
         end else begin
            div <= 4'd0;
            spi_sclk <= ~spi_sclk;
            if (!spi_sclk) begin
               // rising edge: sample MISO
               sh <= {sh[6:0], spi_miso};
            end else begin
               // falling edge: present the next bit
               if (bit_i == 4'd7) begin
                  running <= 1'b0;
                  busy    <= 1'b0;
                  done    <= 1'b1;
                  rx      <= sh;
               end else begin
                  bit_i    <= bit_i + 1'b1;
                  spi_mosi <= sh[7];
               end
            end
         end
      end
   end
endmodule
