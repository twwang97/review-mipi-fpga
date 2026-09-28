//=====================================================================
// frame_buffer.v - external DDR3L frame store.
//
//   frame_writer : ISP groups -> 64-bit words -> DDR bursts
//   frame_ring   : descriptor FIFO (slot, size, timestamp, id)
//   frame_reader : DDR bursts -> 64-bit byte stream for GVSP
//   ddr_arb      : writer-priority arbiter over the DDR user port
//   frame_buffer : the four above wired together
//
// Why this exists: the sensor bursts at 2.76 Gb/s and the wire drains
// at under 1 Gb/s. On-chip memory on the LIFCL-40 totals 2.5 Mb of
// EBR+LRAM, about one seventh of a single 1920x1200 Mono8 frame, so
// the elasticity has to be external.
//
// Stored pixel formats:
//   Mono8  - 1 byte/pixel, two 4-pixel groups per 64-bit word
//   Mono10 - 2 bytes/pixel in a 16-bit container (PFNC Mono10),
//            exactly one 4-pixel group per 64-bit word
//
// The DDR user port below is a generic command/write/read interface.
// Map it onto whatever Radiant emits for the DDR3L controller; the
// signal set is deliberately close to the Lattice native interface.
//
// Verilog-2001.
//=====================================================================
`timescale 1ns/1ps
`default_nettype none
`include "cam_defs.vh"

//---------------------------------------------------------------------
// frame_writer
//---------------------------------------------------------------------
module frame_writer #(
    parameter AW = `FB_ADDR_W,
    parameter SLOT_SHIFT = 22            // 4 MiB per frame slot
)(
    input  wire            clk,
    input  wire            rst_n,

    // ISP side
    input  wire [39:0]     g_data,
    input  wire            g_vld,
    input  wire            g_sof,
    input  wire            g_eof,
    input  wire            cfg_mono10,

    // slot allocation
    input  wire [1:0]      slot,
    input  wire            slot_valid,    // a free slot is available
    output reg             slot_take,     // one-cycle: slot consumed

    // DDR command/write port
    output reg             cmd_valid,
    input  wire            cmd_ready,
    output reg             cmd_we,
    output reg  [AW-1:0]   cmd_addr,
    output reg  [7:0]      cmd_len,       // beats - 1
    output wire            wr_valid,
    input  wire            wr_ready,
    output wire [63:0]     wr_data,
    output wire [7:0]      wr_be,

    // descriptor out
    output reg             desc_vld,
    output reg  [1:0]      desc_slot,
    output reg  [31:0]     desc_bytes,

    output reg             err_overflow
);
    localparam BURST = 8;                 // 8 x 64 bit = 64 bytes

    //---- pack groups into 64-bit words -------------------------------
    reg        half;                      // Mono8 only: low half written
    reg [31:0] lo;
    wire [31:0] m8  = {g_data[39:32], g_data[29:22], g_data[19:12], g_data[9:2]};
    wire [63:0] m10 = {6'd0, g_data[39:30], 6'd0, g_data[29:20],
                       6'd0, g_data[19:10], 6'd0, g_data[ 9: 0]};

    reg        pk_vld;
    reg [63:0] pk_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half <= 1'b0; lo <= 32'd0; pk_vld <= 1'b0; pk_data <= 64'd0;
        end else begin
            pk_vld <= 1'b0;
            if (g_sof) half <= 1'b0;
            if (g_vld) begin
                if (cfg_mono10) begin
                    pk_data <= m10; pk_vld <= 1'b1;
                end else begin
                    if (!half) begin lo <= m8; half <= 1'b1; end
                    else begin
                        pk_data <= {m8, lo}; pk_vld <= 1'b1; half <= 1'b0;
                    end
                end
            end
            // flush a dangling half word at end of frame
            if (g_eof && !cfg_mono10 && half) begin
                pk_data <= {32'd0, lo}; pk_vld <= 1'b1; half <= 1'b0;
            end
        end
    end

    //---- staging FIFO -----------------------------------------------
    wire        f_full, f_empty;
    wire [63:0] f_dout;
    wire [9:0]  f_level;
    wire        f_rd = wr_valid && wr_ready;   // FWFT: pop as it is taken

    sync_fifo #(.DW(64), .AW(9)) u_wf (
        .clk(clk), .rst_n(rst_n),
        .wr(pk_vld && !f_full), .din(pk_data), .full(f_full),
        .rd(f_rd), .dout(f_dout), .empty(f_empty), .level(f_level)
    );

    assign wr_data = f_dout;
    assign wr_be   = 8'hFF;

    //---- burst engine ------------------------------------------------
    localparam W_IDLE = 2'd0, W_CMD = 2'd1, W_DATA = 2'd2;

    reg [1:0]      wst;
    reg [AW-1:0]   wptr;
    reg [31:0]     bytes;
    reg [3:0]      beat;
    reg [3:0]      burst_n;
    reg            eof_pend;
    reg            active;
    reg [1:0]      cur_slot;

    wire enough   = (f_level >= BURST);
    wire flushing = eof_pend && !f_empty;

    assign wr_valid = (wst == W_DATA) && !f_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wst <= W_IDLE; wptr <= {AW{1'b0}}; bytes <= 32'd0;
            beat <= 4'd0; burst_n <= 4'd0; eof_pend <= 1'b0;
            cmd_valid <= 1'b0; cmd_we <= 1'b1; cmd_addr <= {AW{1'b0}};
            cmd_len <= 8'd0; cur_slot <= 2'd0;
            desc_vld <= 1'b0; desc_slot <= 2'd0; desc_bytes <= 32'd0;
            slot_take <= 1'b0; err_overflow <= 1'b0; active <= 1'b0;
        end else begin
            desc_vld     <= 1'b0;
            slot_take    <= 1'b0;
            err_overflow <= 1'b0;

            if (pk_vld && f_full) err_overflow <= 1'b1;

            if (g_sof) begin
                if (slot_valid) begin
                    wptr      <= {{(AW-2-SLOT_SHIFT){1'b0}}, slot,
                                  {SLOT_SHIFT{1'b0}}};
                    cur_slot  <= slot;
                    bytes     <= 32'd0;
                    active    <= 1'b1;
                    slot_take <= 1'b1;
                end else begin
                    active       <= 1'b0;     // no free slot: drop the frame
                    err_overflow <= 1'b1;
                end
            end
            if (g_eof && active) eof_pend <= 1'b1;

            case (wst)
            W_IDLE:
                if (active && (enough || flushing)) begin
                    burst_n   <= (f_level >= BURST) ? BURST[3:0]
                                                    : f_level[3:0];
                    cmd_valid <= 1'b1;
                    cmd_we    <= 1'b1;
                    cmd_addr  <= wptr;
                    cmd_len   <= ((f_level >= BURST) ? BURST[7:0]
                                                     : {4'd0, f_level[3:0]})
                                 - 8'd1;
                    wst       <= W_CMD;
                end else if (eof_pend && f_empty) begin
                    desc_vld   <= 1'b1;
                    desc_slot  <= cur_slot;
                    desc_bytes <= bytes;
                    eof_pend   <= 1'b0;
                    // Do not clear active if the next frame's start
                    // arrived in this same cycle: the last non-blocking
                    // assignment in the block wins, and clearing here
                    // would silently swallow the incoming frame.
                    if (!g_sof) active <= 1'b0;
                end

            W_CMD:
                if (cmd_ready) begin
                    cmd_valid <= 1'b0;
                    beat      <= 4'd0;
                    wst       <= W_DATA;
                end

            W_DATA:
                if (wr_valid && wr_ready) begin
                    wptr  <= wptr  + 27'd8;
                    bytes <= bytes + 32'd8;
                    if (beat == (burst_n - 4'd1)) wst <= W_IDLE;
                    else                          beat <= beat + 4'd1;
                end
            endcase
        end
    end
endmodule

//---------------------------------------------------------------------
// frame_ring - slot allocator plus descriptor FIFO.
//---------------------------------------------------------------------
module frame_ring #(parameter NSLOT = `FB_NUM_BUFS) (
    input  wire        clk,
    input  wire        rst_n,

    output wire [1:0]  alloc_slot,
    output wire        alloc_valid,
    input  wire        alloc_take,

    input  wire        desc_vld,
    input  wire [1:0]  desc_slot,
    input  wire [31:0] desc_bytes,
    input  wire [63:0] desc_ts,
    input  wire [15:0] desc_id,

    output wire        rd_vld,
    output wire [1:0]  rd_slot,
    output wire [31:0] rd_bytes,
    output wire [63:0] rd_ts,
    output wire [15:0] rd_id,
    input  wire        rd_take,

    output reg  [15:0] frames_done,
    output reg  [15:0] frames_dropped
);
    // occupancy: a slot is busy from allocation until the reader frees it
    reg [NSLOT-1:0] busy;
    reg [1:0]       next;

    wire free_any = ~(&busy);
    assign alloc_valid = free_any;
    assign alloc_slot  = next;

    integer i;
    reg [1:0] cand;
    always @(*) begin
        cand = next;
        for (i = NSLOT-1; i >= 0; i = i - 1)
            if (!busy[i]) cand = i[1:0];
    end

    // Descriptor FIFO with first-word-fall-through. A plain synchronous
    // FIFO will not do here: the reader must SEE the head descriptor
    // (slot and byte count) before it consumes it, and a registered-read
    // FIFO only updates its output on a pop. Eight entries of 114 bits
    // is small enough to live in distributed RAM with an async read.
    reg [113:0] dmem [0:7];
    reg [3:0]   dwp, drp;

    wire [113:0] din    = {desc_id, desc_ts, desc_bytes, desc_slot};
    wire         dempty = (dwp == drp);
    wire         dfull  = (dwp[2:0] == drp[2:0]) && (dwp[3] != drp[3]);
    wire [113:0] dout   = dmem[drp[2:0]];

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin dwp <= 4'd0; drp <= 4'd0; end
        else begin
            if (desc_vld && !dfull) dwp <= dwp + 4'd1;
            if (rd_take && !dempty) drp <= drp + 4'd1;
        end

    always @(posedge clk)
        if (desc_vld && !dfull) dmem[dwp[2:0]] <= din;

    assign rd_vld   = ~dempty;
    assign rd_slot  = dout[1:0];
    assign rd_bytes = dout[33:2];
    assign rd_ts    = dout[97:34];
    assign rd_id    = dout[113:98];

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            busy <= {NSLOT{1'b0}}; next <= 2'd0;
            frames_done <= 16'd0; frames_dropped <= 16'd0;
        end else begin
            if (alloc_take && alloc_valid) begin
                busy[alloc_slot] <= 1'b1;
                next <= cand;
            end
            if (rd_take && rd_vld) begin
                busy[rd_slot] <= 1'b0;
                frames_done   <= frames_done + 16'd1;
            end
            if (desc_vld && dfull) frames_dropped <= frames_dropped + 16'd1;
        end
endmodule

//---------------------------------------------------------------------
// frame_reader - streams one frame slot out as 64-bit beats.
//---------------------------------------------------------------------
module frame_reader #(
    parameter AW = `FB_ADDR_W,
    parameter SLOT_SHIFT = 22
)(
    input  wire          clk,
    input  wire          rst_n,

    input  wire          start,            // pulse
    input  wire [1:0]    slot,
    input  wire [31:0]   nbytes,
    output reg           busy,
    output reg           done,             // pulse when the last beat is out

    // DDR command/read port
    output reg           cmd_valid,
    input  wire          cmd_ready,
    output reg           cmd_we,
    output reg  [AW-1:0] cmd_addr,
    output reg  [7:0]    cmd_len,
    input  wire          rd_valid,
    input  wire [63:0]   rd_data,

    // stream out
    output wire [63:0]   s_data,
    output wire          s_vld,
    input  wire          s_rdy
);
    localparam BURST = 8;
    localparam R_IDLE = 2'd0, R_CMD = 2'd1, R_WAIT = 2'd2;

    reg [1:0]    rst_st;
    reg [AW-1:0] rptr;
    reg [31:0]   left;
    reg [3:0]    beats_out;
    reg [3:0]    burst_n;

    wire        ffull, fempty;
    wire [9:0]  flevel;
    wire [63:0] fdout;

    sync_fifo #(.DW(64), .AW(9)) u_rf (
        .clk(clk), .rst_n(rst_n),
        .wr(rd_valid && !ffull), .din(rd_data), .full(ffull),
        .rd(s_vld && s_rdy), .dout(fdout), .empty(fempty), .level(flevel)
    );

    assign s_data = fdout;
    assign s_vld  = ~fempty;

    wire room = (flevel < (10'd512 - 10'd16));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_st <= R_IDLE; rptr <= {AW{1'b0}}; left <= 32'd0;
            busy <= 1'b0; done <= 1'b0;
            cmd_valid <= 1'b0; cmd_we <= 1'b0; cmd_addr <= {AW{1'b0}};
            cmd_len <= 8'd0; beats_out <= 4'd0; burst_n <= 4'd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                rptr <= {{(AW-2-SLOT_SHIFT){1'b0}}, slot,
                         {SLOT_SHIFT{1'b0}}};
                left <= (nbytes + 32'd7) & ~32'd7;     // round to 8 bytes
                busy <= 1'b1;
            end

            case (rst_st)
            R_IDLE:
                if (busy && (left != 32'd0) && room) begin
                    burst_n   <= (left >= 32'd64) ? BURST[3:0]
                                                  : left[6:3];
                    cmd_valid <= 1'b1;
                    cmd_we    <= 1'b0;
                    cmd_addr  <= rptr;
                    cmd_len   <= ((left >= 32'd64) ? BURST[7:0]
                                                   : {4'd0, left[6:3]}) - 8'd1;
                    rst_st    <= R_CMD;
                end else if (busy && (left == 32'd0) && fempty) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end

            R_CMD:
                if (cmd_ready) begin
                    cmd_valid <= 1'b0;
                    beats_out <= 4'd0;
                    rst_st    <= R_WAIT;
                end

            R_WAIT:
                if (rd_valid) begin
                    rptr <= rptr + 27'd8;
                    left <= (left >= 32'd8) ? (left - 32'd8) : 32'd0;
                    if (beats_out == (burst_n - 4'd1)) rst_st <= R_IDLE;
                    else beats_out <= beats_out + 4'd1;
                end
            endcase
        end
    end
endmodule

//---------------------------------------------------------------------
// ddr_arb - writer has absolute priority; the sensor cannot be stalled.
//---------------------------------------------------------------------
module ddr_arb #(parameter AW = `FB_ADDR_W) (
    input  wire          clk, input wire rst_n,

    input  wire          a_valid, output wire a_ready,
    input  wire          a_we, input wire [AW-1:0] a_addr,
    input  wire [7:0]    a_len,

    input  wire          b_valid, output wire b_ready,
    input  wire          b_we, input wire [AW-1:0] b_addr,
    input  wire [7:0]    b_len,

    output wire          m_valid, input wire m_ready,
    output wire          m_we, output wire [AW-1:0] m_addr,
    output wire [7:0]    m_len
);
    wire sel_a = a_valid;
    assign m_valid = a_valid | b_valid;
    assign m_we    = sel_a ? a_we   : b_we;
    assign m_addr  = sel_a ? a_addr : b_addr;
    assign m_len   = sel_a ? a_len  : b_len;
    assign a_ready = m_ready &  sel_a;
    assign b_ready = m_ready & ~sel_a;
endmodule

//---------------------------------------------------------------------
// frame_buffer
//---------------------------------------------------------------------
module frame_buffer #(parameter AW = `FB_ADDR_W) (
    input  wire          clk,
    input  wire          rst_n,

    // ISP in
    input  wire [39:0]   g_data,
    input  wire          g_vld,
    input  wire          g_sof,
    input  wire          g_eof,
    input  wire          cfg_mono10,
    input  wire [63:0]   ts_now,
    input  wire [15:0]   frame_id,

    // stream out to GVSP
    output wire          fr_vld,
    output wire [31:0]   fr_bytes,
    output wire [63:0]   fr_ts,
    output wire [15:0]   fr_id,
    input  wire          fr_start,
    output wire          fr_busy,
    output wire          fr_done,
    output wire [63:0]   s_data,
    output wire          s_vld,
    input  wire          s_rdy,

    // DDR user port
    output wire          cmd_valid, input wire cmd_ready,
    output wire          cmd_we, output wire [AW-1:0] cmd_addr,
    output wire [7:0]    cmd_len,
    output wire          wr_valid, input wire wr_ready,
    output wire [63:0]   wr_data, output wire [7:0] wr_be,
    input  wire          rd_valid, input wire [63:0] rd_data,

    // status
    output wire [15:0]   frames_done,
    output wire [15:0]   frames_dropped,
    output wire          err_overflow
);
    wire [1:0] al_slot; wire al_vld, al_take;
    wire [1:0] ring_slot;

    wire        wc_v, wc_r, wc_we; wire [AW-1:0] wc_a; wire [7:0] wc_l;
    wire        rc_v, rc_r, rc_we; wire [AW-1:0] rc_a; wire [7:0] rc_l;

    wire        d_vld; wire [1:0] d_slot; wire [31:0] d_bytes;

    frame_writer #(.AW(AW)) u_wr (
        .clk(clk), .rst_n(rst_n),
        .g_data(g_data), .g_vld(g_vld), .g_sof(g_sof), .g_eof(g_eof),
        .cfg_mono10(cfg_mono10),
        .slot(al_slot), .slot_valid(al_vld), .slot_take(al_take),
        .cmd_valid(wc_v), .cmd_ready(wc_r), .cmd_we(wc_we),
        .cmd_addr(wc_a), .cmd_len(wc_l),
        .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_data(wr_data), .wr_be(wr_be),
        .desc_vld(d_vld), .desc_slot(d_slot), .desc_bytes(d_bytes),
        .err_overflow(err_overflow)
    );

    frame_ring u_ring (
        .clk(clk), .rst_n(rst_n),
        .alloc_slot(al_slot), .alloc_valid(al_vld), .alloc_take(al_take),
        .desc_vld(d_vld), .desc_slot(d_slot), .desc_bytes(d_bytes),
        .desc_ts(ts_now), .desc_id(frame_id),
        .rd_vld(fr_vld), .rd_slot(ring_slot), .rd_bytes(fr_bytes),
        .rd_ts(fr_ts), .rd_id(fr_id), .rd_take(fr_done),
        .frames_done(frames_done), .frames_dropped(frames_dropped)
    );

    frame_reader #(.AW(AW)) u_rd (
        .clk(clk), .rst_n(rst_n),
        .start(fr_start), .slot(ring_slot), .nbytes(fr_bytes),
        .busy(fr_busy), .done(fr_done),
        .cmd_valid(rc_v), .cmd_ready(rc_r), .cmd_we(rc_we),
        .cmd_addr(rc_a), .cmd_len(rc_l),
        .rd_valid(rd_valid), .rd_data(rd_data),
        .s_data(s_data), .s_vld(s_vld), .s_rdy(s_rdy)
    );

    ddr_arb #(.AW(AW)) u_arb (
        .clk(clk), .rst_n(rst_n),
        .a_valid(wc_v), .a_ready(wc_r), .a_we(wc_we),
        .a_addr(wc_a), .a_len(wc_l),
        .b_valid(rc_v), .b_ready(rc_r), .b_we(rc_we),
        .b_addr(rc_a), .b_len(rc_l),
        .m_valid(cmd_valid), .m_ready(cmd_ready), .m_we(cmd_we),
        .m_addr(cmd_addr), .m_len(cmd_len)
    );
endmodule

`default_nettype wire
