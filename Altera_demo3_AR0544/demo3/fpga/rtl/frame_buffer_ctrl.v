//=====================================================================
// frame_buffer_ctrl.v -- triple-buffered DDR3 frame store
//
// Avalon-MM master into the UniPHY DDR3 controller (128-bit, bursting).
// Matches the documented Demo3 behaviour [EVBUM2310/D]:
//   * 1 Gb buffer, three frame slots, triple buffered to cut frame loss
//   * self-timed streaming mode, or frame-capture mode where the whole
//     buffer is filled before anything is handed to FX3
//   * write and read sides arbitrate for one Avalon port
//
// Documented ceilings this block is sized against:
//   750 Mpixel/s aggregate, 400 Mpixel/s in, 200 Mpixel/s out.
//=====================================================================
`timescale 1ns/1ps
`include "demo3_defs.vh"

module frame_buffer_ctrl #(
   parameter BURST = 16
) (
   input  wire              clk,
   input  wire              rst_n,

   input  wire              cfg_en,
   input  wire              cfg_capture_mode,
   input  wire              cfg_flush,
   input  wire [`AVL_AW-1:0] cfg_base0,
   input  wire [`AVL_AW-1:0] cfg_base1,
   input  wire [`AVL_AW-1:0] cfg_base2,
   input  wire [31:0]       cfg_frame_bytes,

   // write side, from the formatter
   input  wire [`DDRW-1:0]  w_data,
   input  wire              w_valid,
   input  wire              w_sof,
   input  wire              w_eof,
   output wire              w_ready,

   // read side, to FX3 / HDMI
   input  wire              r_req,
   output reg  [`DDRW-1:0]  r_data,
   output reg               r_valid,
   input  wire              r_ready,
   output reg               r_frame_done,

   // Avalon-MM master
   output reg  [`AVL_AW-1:0] avl_addr,
   output reg               avl_read_req,
   output reg               avl_write_req,
   output reg  [4:0]        avl_burstbegin,
   output reg  [`DDRW-1:0]  avl_wdata,
   output reg  [15:0]       avl_be,
   output reg  [4:0]        avl_size,
   input  wire              avl_ready,
   input  wire [`DDRW-1:0]  avl_rdata,
   input  wire              avl_rdata_valid,

   // status
   output reg  [1:0]        st_wr_buf,
   output reg  [1:0]        st_rd_buf,
   output reg               st_ready,
   output reg               st_overflow,
   output reg  [31:0]       st_wr_cnt,
   output reg  [31:0]       st_rd_cnt,
   output reg               ev_frame_ready
);
   localparam FD = 8;                       // staging FIFO depth log2

   //------------------------------------------------------------------
   // write staging FIFO (same clock; DCFIFO used for its usedw ports)
   //------------------------------------------------------------------
   wire [`DDRW-1:0] wf_q;
   wire             wf_empty, wf_full;
   wire [FD-1:0]    wf_used;
   reg              wf_pop;

   dcfifo_wrap #(.W(`DDRW), .DEPTH_LOG2(FD)) u_wfifo (
      .aclr(~rst_n | cfg_flush),
      .wrclk(clk), .wrreq(w_valid & ~wf_full), .data(w_data),
      .wrfull(wf_full), .wrusedw(wf_used),
      .rdclk(clk), .rdreq(wf_pop), .q(wf_q), .rdempty(wf_empty),
      .rdusedw());

   assign w_ready = ~wf_full;

   //------------------------------------------------------------------
   // read staging FIFO
   //------------------------------------------------------------------
   wire [`DDRW-1:0] rf_q;
   wire             rf_empty, rf_full;
   wire [FD-1:0]    rf_used;
   reg              rf_push;
   reg  [`DDRW-1:0] rf_din;

   dcfifo_wrap #(.W(`DDRW), .DEPTH_LOG2(FD)) u_rfifo (
      .aclr(~rst_n | cfg_flush),
      .wrclk(clk), .wrreq(rf_push), .data(rf_din),
      .wrfull(rf_full), .wrusedw(rf_used),
      .rdclk(clk), .rdreq(r_ready & ~rf_empty), .q(rf_q), .rdempty(rf_empty),
      .rdusedw());

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin r_data <= {`DDRW{1'b0}}; r_valid <= 1'b0; end
      else begin
         r_valid <= r_ready & ~rf_empty;
         r_data  <= rf_q;
      end
   end

   always @(*) begin
      rf_push = avl_rdata_valid & ~rf_full;
      rf_din  = avl_rdata;
   end

   //------------------------------------------------------------------
   // buffer slot bases
   //------------------------------------------------------------------
   function [`AVL_AW-1:0] base_of;
      input [1:0] slot;
      begin
         case (slot)
            2'd0:    base_of = cfg_base0;
            2'd1:    base_of = cfg_base1;
            default: base_of = cfg_base2;
         endcase
      end
   endfunction

   reg [`AVL_AW-1:0] wr_off, rd_off;
   reg [1:0]         buf_full_msk;          // which slots hold a whole frame

   //------------------------------------------------------------------
   // Avalon arbiter: write has priority unless the read FIFO is running
   // dry, which keeps HDMI and FX3 from starving during a burst.
   //------------------------------------------------------------------
   localparam A_IDLE = 2'd0, A_WR = 2'd1, A_RD = 2'd2;
   reg [1:0] ast;
   reg [4:0] beat;

   wire wr_have_burst = (wf_used >= BURST[FD-1:0]);
   wire rd_need_burst = r_req && ((rf_used + BURST) < (1<<FD)) && st_ready;
   wire rd_urgent     = rd_need_burst && (rf_used < (BURST*2));

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         ast <= A_IDLE; beat <= 5'd0;
         avl_addr <= {`AVL_AW{1'b0}};
         avl_read_req <= 1'b0; avl_write_req <= 1'b0;
         avl_burstbegin <= 5'd0; avl_wdata <= {`DDRW{1'b0}};
         avl_be <= 16'hFFFF; avl_size <= 5'd0;
         wf_pop <= 1'b0;
         wr_off <= {`AVL_AW{1'b0}}; rd_off <= {`AVL_AW{1'b0}};
         st_wr_buf <= 2'd0; st_rd_buf <= 2'd0;
         st_ready <= 1'b0; st_overflow <= 1'b0;
         st_wr_cnt <= 32'd0; st_rd_cnt <= 32'd0;
         buf_full_msk <= 2'd0; ev_frame_ready <= 1'b0;
         r_frame_done <= 1'b0;
      end else begin
         avl_burstbegin <= 5'd0;
         ev_frame_ready <= 1'b0;
         r_frame_done   <= 1'b0;
         wf_pop         <= 1'b0;

         if (cfg_flush || !cfg_en) begin
            ast <= A_IDLE; beat <= 5'd0;
            avl_read_req <= 1'b0; avl_write_req <= 1'b0;
            wr_off <= {`AVL_AW{1'b0}}; rd_off <= {`AVL_AW{1'b0}};
            st_ready <= 1'b0; st_overflow <= 1'b0;
            st_wr_buf <= 2'd0; st_rd_buf <= 2'd0;
         end else begin
            if (wf_full && w_valid) st_overflow <= 1'b1;

            case (ast)
            //----------------------------------------------------------
            A_IDLE: begin
               avl_read_req  <= 1'b0;
               avl_write_req <= 1'b0;
               if (rd_urgent) begin
                  avl_addr       <= base_of(st_rd_buf) + rd_off;
                  avl_size       <= BURST[4:0];
                  avl_burstbegin <= 5'd1;
                  avl_read_req   <= 1'b1;
                  beat           <= 5'd0;
                  ast            <= A_RD;
               end else if (wr_have_burst) begin
                  avl_addr       <= base_of(st_wr_buf) + wr_off;
                  avl_size       <= BURST[4:0];
                  avl_burstbegin <= 5'd1;
                  avl_write_req  <= 1'b1;
                  avl_wdata      <= wf_q;
                  wf_pop         <= 1'b1;
                  beat           <= 5'd1;
                  ast            <= A_WR;
               end else if (rd_need_burst) begin
                  avl_addr       <= base_of(st_rd_buf) + rd_off;
                  avl_size       <= BURST[4:0];
                  avl_burstbegin <= 5'd1;
                  avl_read_req   <= 1'b1;
                  beat           <= 5'd0;
                  ast            <= A_RD;
               end
            end
            //----------------------------------------------------------
            A_WR: if (avl_ready) begin
               if (beat == BURST[4:0]) begin
                  avl_write_req <= 1'b0;
                  wr_off        <= wr_off + (BURST*(`DDRW/8));
                  st_wr_cnt     <= st_wr_cnt + (BURST*(`DDRW/8));
                  ast           <= A_IDLE;
                  if ((wr_off + (BURST*(`DDRW/8))) >= cfg_frame_bytes[`AVL_AW-1:0]) begin
                     wr_off         <= {`AVL_AW{1'b0}};
                     st_wr_buf      <= (st_wr_buf == 2'd2) ? 2'd0 : st_wr_buf + 1'b1;
                     st_ready       <= 1'b1;
                     ev_frame_ready <= 1'b1;
                     if (cfg_capture_mode) buf_full_msk <= buf_full_msk + 1'b1;
                  end
               end else begin
                  avl_wdata <= wf_q;
                  wf_pop    <= 1'b1;
                  beat      <= beat + 1'b1;
               end
            end
            //----------------------------------------------------------
            A_RD: begin
               if (avl_ready) avl_read_req <= 1'b0;
               if (avl_rdata_valid) begin
                  beat      <= beat + 1'b1;
                  st_rd_cnt <= st_rd_cnt + (`DDRW/8);
                  if (beat == (BURST[4:0]-1)) begin
                     rd_off <= rd_off + (BURST*(`DDRW/8));
                     ast    <= A_IDLE;
                     if ((rd_off + (BURST*(`DDRW/8))) >= cfg_frame_bytes[`AVL_AW-1:0]) begin
                        rd_off       <= {`AVL_AW{1'b0}};
                        st_rd_buf    <= (st_rd_buf == 2'd2) ? 2'd0 : st_rd_buf + 1'b1;
                        r_frame_done <= 1'b1;
                        if (st_rd_buf == st_wr_buf) st_ready <= 1'b0;
                     end
                  end
               end
            end
            //----------------------------------------------------------
            default: ast <= A_IDLE;
            endcase
         end
      end
   end

   wire _unused_sof_eof = w_sof | w_eof;
endmodule
