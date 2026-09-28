//=====================================================================
// hdmi_out.v -- video output to the ADV7526 HDMI transmitter
//
// ADV7526 accepts up to 36-bit RGB or YCbCr with a forwarded pixel
// clock; HDMI 1.4 with 12-bit deep colour, I2C address 0x72
// [EVBUM2310/D]. Register configuration of the ADV7526 itself is done
// by the i2c_seq block from a host-loaded script -- this module only
// handles the video bus.
//
// Pixels arrive as 16-bit containers out of the frame buffer; they are
// replicated across the three 12-bit channels for monochrome, or taken
// as pre-formed RGB when the host has an ISP in the path.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module hdmi_out (
   input  wire        clk_pix,
   input  wire        rst_n,
   input  wire        cfg_out_en,
   input  wire [1:0]  cfg_fmt,          // 0 = raw->grey, 1 = RGB444, 2 = YCbCr422

   // timing
   input  wire        t_hsync,
   input  wire        t_vsync,
   input  wire        t_de,

   // pixel source: 128-bit beats from the frame buffer read port
   input  wire [`DDRW-1:0] s_data,
   input  wire        s_valid,
   output reg         s_ready,

   // ADV7526 bus
   output reg  [35:0] hdmi_d,
   output reg         hdmi_hs,
   output reg         hdmi_vs,
   output reg         hdmi_de,
   output wire        hdmi_clk
);
   // forward the pixel clock through an ALTDDIO_OUT so it leaves on a
   // real output register rather than a routed clock
   altddio_out_wrap #(1) u_clkfwd (
      .outclock(clk_pix), .datain_h(1'b1), .datain_l(1'b0), .dataout(hdmi_clk));

   reg [`DDRW-1:0] beat;
   reg [2:0]       idx;                 // which of the 8 pixels in the beat
   reg             have;

   wire [`PIXW-1:0] px = beat[idx*`PIXW +: `PIXW];
   wire [11:0]      px12 = px[15:4];    // MSB-align a 16-bit container

   always @(posedge clk_pix or negedge rst_n) begin
      if (!rst_n) begin
         beat <= {`DDRW{1'b0}}; idx <= 3'd0; have <= 1'b0; s_ready <= 1'b0;
         hdmi_d <= 36'd0; hdmi_hs <= 1'b0; hdmi_vs <= 1'b0; hdmi_de <= 1'b0;
      end else begin
         hdmi_hs <= t_hsync;
         hdmi_vs <= t_vsync;
         hdmi_de <= t_de & cfg_out_en;
         s_ready <= 1'b0;

         if (!cfg_out_en) begin
            have   <= 1'b0;
            idx    <= 3'd0;
            hdmi_d <= 36'd0;
         end else begin
            if (!have && s_valid) begin
               beat    <= s_data;
               have    <= 1'b1;
               idx     <= 3'd0;
               s_ready <= 1'b1;
            end

            if (t_de && have) begin
               case (cfg_fmt)
                  2'd1:    hdmi_d <= {px12, px12, px12};     // RGB444 passthrough
                  2'd2:    hdmi_d <= {px12, 12'h800, 12'h800};
                  default: hdmi_d <= {px12, px12, px12};     // raw -> grey
               endcase
               if (idx == 3'd7) begin
                  have <= 1'b0;
                  idx  <= 3'd0;
               end else begin
                  idx <= idx + 1'b1;
               end
            end else if (!t_de) begin
               hdmi_d <= 36'd0;
            end
         end
      end
   end
endmodule
