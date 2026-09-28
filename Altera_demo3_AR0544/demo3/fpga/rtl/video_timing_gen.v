//=====================================================================
// video_timing_gen.v -- CEA-861 timing for the HDMI path
//   mode 0 : 720p60   1280x720  @ 74.25 MHz
//   mode 1 : 1080p60  1920x1080 @ 148.5 MHz
// Both are the rates EVBUM2310/D lists for the frame-buffer's
// direct-to-HDMI mode. Timing numbers may also be overridden from the
// register file (cfg_ext) for non-standard panels.
//=====================================================================
`timescale 1ns/1ps

module video_timing_gen (
   input  wire        clk_pix,
   input  wire        rst_n,
   input  wire        cfg_en,
   input  wire        cfg_mode,        // 0 = 720p60, 1 = 1080p60
   input  wire        cfg_ext,         // use the register-supplied numbers
   input  wire [15:0] cfg_htotal,  input wire [15:0] cfg_hactive,
   input  wire [15:0] cfg_hfront,  input wire [15:0] cfg_hsync,
   input  wire [15:0] cfg_vtotal,  input wire [15:0] cfg_vactive,
   input  wire [15:0] cfg_vfront,  input wire [15:0] cfg_vsync,
   input  wire        cfg_hs_pol,  input wire cfg_vs_pol,

   output reg         hsync,
   output reg         vsync,
   output reg         de,
   output reg  [15:0] hpos,
   output reg  [15:0] vpos,
   output reg         frame_start,
   output reg         line_start
);
   reg [15:0] htotal, hactive, hfront, hsw;
   reg [15:0] vtotal, vactive, vfront, vsw;

   always @(*) begin
      if (cfg_ext) begin
         htotal=cfg_htotal; hactive=cfg_hactive; hfront=cfg_hfront; hsw=cfg_hsync;
         vtotal=cfg_vtotal; vactive=cfg_vactive; vfront=cfg_vfront; vsw=cfg_vsync;
      end else if (cfg_mode) begin        // 1080p60
         htotal=16'd2200; hactive=16'd1920; hfront=16'd88;  hsw=16'd44;
         vtotal=16'd1125; vactive=16'd1080; vfront=16'd4;   vsw=16'd5;
      end else begin                      // 720p60
         htotal=16'd1650; hactive=16'd1280; hfront=16'd110; hsw=16'd40;
         vtotal=16'd750;  vactive=16'd720;  vfront=16'd5;   vsw=16'd5;
      end
   end

   wire [15:0] hs_start = hactive + hfront;
   wire [15:0] hs_end   = hactive + hfront + hsw;
   wire [15:0] vs_start = vactive + vfront;
   wire [15:0] vs_end   = vactive + vfront + vsw;

   always @(posedge clk_pix or negedge rst_n) begin
      if (!rst_n) begin
         hpos <= 16'd0; vpos <= 16'd0;
         hsync <= 1'b0; vsync <= 1'b0; de <= 1'b0;
         frame_start <= 1'b0; line_start <= 1'b0;
      end else if (!cfg_en) begin
         hpos <= 16'd0; vpos <= 16'd0;
         hsync <= cfg_hs_pol; vsync <= cfg_vs_pol; de <= 1'b0;
         frame_start <= 1'b0; line_start <= 1'b0;
      end else begin
         frame_start <= 1'b0;
         line_start  <= 1'b0;

         if (hpos == (htotal - 1'b1)) begin
            hpos       <= 16'd0;
            line_start <= 1'b1;
            if (vpos == (vtotal - 1'b1)) begin
               vpos        <= 16'd0;
               frame_start <= 1'b1;
            end else begin
               vpos <= vpos + 1'b1;
            end
         end else begin
            hpos <= hpos + 1'b1;
         end

         de    <= (hpos < hactive) && (vpos < vactive);
         hsync <= ((hpos >= hs_start) && (hpos < hs_end)) ^ cfg_hs_pol;
         vsync <= ((vpos >= vs_start) && (vpos < vs_end)) ^ cfg_vs_pol;
      end
   end
endmodule
