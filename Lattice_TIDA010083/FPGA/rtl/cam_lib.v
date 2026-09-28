//=====================================================================
// cam_lib.v - clock-domain-crossing and FIFO primitives.
// Verilog-2001.
//=====================================================================
`timescale 1ns/1ps
`default_nettype none

//---------------------------------------------------------------------
// rst_sync : asynchronous assert, synchronous de-assert.
//---------------------------------------------------------------------
module rst_sync #(parameter STAGES = 3) (
    input  wire clk,
    input  wire arst_n,       // async, active low
    output wire rst_n         // sync-deasserted, active low
);
    reg [STAGES-1:0] q;
    always @(posedge clk or negedge arst_n)
        if (!arst_n) q <= {STAGES{1'b0}};
        else         q <= {q[STAGES-2:0], 1'b1};
    assign rst_n = q[STAGES-1];
endmodule

//---------------------------------------------------------------------
// bit_sync : two-flop synchroniser for slow / quasi-static signals.
//---------------------------------------------------------------------
module bit_sync #(parameter W = 1, parameter INIT = 1'b0) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] s0, s1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin s0 <= {W{INIT[0]}}; s1 <= {W{INIT[0]}}; end
        else        begin s0 <= d;           s1 <= s0;          end
    assign q = s1;
endmodule

//---------------------------------------------------------------------
// pulse_sync : single-cycle pulse from clk_a to clk_b (toggle method).
// The source must not issue pulses faster than ~3 destination clocks.
//---------------------------------------------------------------------
module pulse_sync (
    input  wire clk_a, input wire rst_a_n, input wire pulse_a,
    input  wire clk_b, input wire rst_b_n, output wire pulse_b
);
    reg tog;
    always @(posedge clk_a or negedge rst_a_n)
        if (!rst_a_n) tog <= 1'b0;
        else if (pulse_a) tog <= ~tog;

    wire tsync;
    bit_sync #(.W(1)) u_s (.clk(clk_b), .rst_n(rst_b_n), .d(tog), .q(tsync));

    reg tq;
    always @(posedge clk_b or negedge rst_b_n)
        if (!rst_b_n) tq <= 1'b0; else tq <= tsync;
    assign pulse_b = tsync ^ tq;
endmodule

//---------------------------------------------------------------------
// bus_sync : data-valid handshake for a multi-bit word across domains.
//---------------------------------------------------------------------
module bus_sync #(parameter W = 32) (
    input  wire         clk_a, input wire rst_a_n,
    input  wire [W-1:0] d_a,   input wire  vld_a, output wire rdy_a,
    input  wire         clk_b, input wire rst_b_n,
    output reg  [W-1:0] d_b,   output wire vld_b
);
    reg  [W-1:0] hold;
    reg          req;
    wire         ack_a;

    always @(posedge clk_a or negedge rst_a_n)
        if (!rst_a_n) begin req <= 1'b0; hold <= {W{1'b0}}; end
        else if (vld_a && rdy_a) begin hold <= d_a; req <= ~req; end

    wire req_b;
    bit_sync #(.W(1)) u_rq (.clk(clk_b), .rst_n(rst_b_n), .d(req), .q(req_b));

    reg req_b_q;
    always @(posedge clk_b or negedge rst_b_n)
        if (!rst_b_n) begin req_b_q <= 1'b0; d_b <= {W{1'b0}}; end
        else begin
            req_b_q <= req_b;
            if (req_b ^ req_b_q) d_b <= hold;   // hold is stable by then
        end
    assign vld_b = req_b ^ req_b_q;

    reg ack_tog;
    always @(posedge clk_b or negedge rst_b_n)
        if (!rst_b_n) ack_tog <= 1'b0; else if (vld_b) ack_tog <= ~ack_tog;

    bit_sync #(.W(1)) u_ak (.clk(clk_a), .rst_n(rst_a_n), .d(ack_tog), .q(ack_a));
    reg ack_a_q;
    always @(posedge clk_a or negedge rst_a_n)
        if (!rst_a_n) ack_a_q <= 1'b0; else ack_a_q <= ack_a;

    reg busy;
    always @(posedge clk_a or negedge rst_a_n)
        if (!rst_a_n) busy <= 1'b0;
        else if (vld_a && rdy_a) busy <= 1'b1;
        else if (ack_a ^ ack_a_q) busy <= 1'b0;
    assign rdy_a = ~busy;
endmodule

//---------------------------------------------------------------------
// sync_fifo : single-clock FIFO, EBR-inferred when DEPTH is large.
//---------------------------------------------------------------------
module sync_fifo #(parameter DW = 8, parameter AW = 9) (
    input  wire          clk, input wire rst_n,
    input  wire          wr,  input wire [DW-1:0] din,  output wire full,
    input  wire          rd,  output wire [DW-1:0] dout, output wire empty,
    output wire [AW:0]   level
);
    // First-word-fall-through. dout presents the head of the queue
    // without a pop, and rd consumes it in the same cycle. A plain
    // registered-read FIFO cannot be used by a consumer that has to
    // inspect the head before deciding to take it, and produces X on
    // the first access because the output register was never loaded.
    (* syn_ramstyle = "block_ram" *) reg [DW-1:0] mem [0:(1<<AW)-1];
    reg [AW:0]   wp, rp;
    reg [DW-1:0] dq;
    reg          valid;

    wire int_empty = (wp == rp);
    wire do_read   = !int_empty && (!valid || rd);

    assign full  = (wp[AW] != rp[AW]) && (wp[AW-1:0] == rp[AW-1:0]);
    assign empty = ~valid;
    assign dout  = dq;
    assign level = (wp - rp) + {{AW{1'b0}}, valid};

    always @(posedge clk) if (wr && !full) mem[wp[AW-1:0]] <= din;
    always @(posedge clk) if (do_read)     dq <= mem[rp[AW-1:0]];

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin wp <= 0; rp <= 0; valid <= 1'b0; end
        else begin
            if (wr && !full) wp <= wp + 1'b1;
            if (do_read) begin rp <= rp + 1'b1; valid <= 1'b1; end
            else if (rd)       valid <= 1'b0;
        end
endmodule

//---------------------------------------------------------------------
// async_fifo : dual-clock FIFO with Gray-coded pointers.
// Read data is registered: assert rd, data valid on the next edge.
//---------------------------------------------------------------------
module async_fifo #(parameter DW = 8, parameter AW = 9) (
    input  wire          wclk, input wire wrst_n,
    input  wire          wr,   input wire [DW-1:0] din, output wire wfull,
    output wire [AW:0]   wlevel,
    input  wire          rclk, input wire rrst_n,
    input  wire          rd,   output wire [DW-1:0] dout, output wire rempty
);
    localparam DEPTH = (1 << AW);
    (* syn_ramstyle = "block_ram" *) reg [DW-1:0] mem [0:DEPTH-1];

    reg  [AW:0] wbin, wgray, rbin, rgray;
    wire [AW:0] wbin_nxt  = wbin + (wr && !wfull);
    wire [AW:0] rbin_nxt  = rbin + (rd && !rempty);
    wire [AW:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
    wire [AW:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    wire [AW:0] rgray_w, wgray_r;
    bit_sync #(.W(AW+1)) u_r2w (.clk(wclk), .rst_n(wrst_n), .d(rgray), .q(rgray_w));
    bit_sync #(.W(AW+1)) u_w2r (.clk(rclk), .rst_n(rrst_n), .d(wgray), .q(wgray_r));

    always @(posedge wclk or negedge wrst_n)
        if (!wrst_n) begin wbin <= 0; wgray <= 0; end
        else         begin wbin <= wbin_nxt; wgray <= wgray_nxt; end

    always @(posedge rclk or negedge rrst_n)
        if (!rrst_n) begin rbin <= 0; rgray <= 0; end
        else         begin rbin <= rbin_nxt; rgray <= rgray_nxt; end

    // Both flags are REGISTERED. Computing them combinationally from the
    // "next" pointer while the pointer increment depends on the flag
    // closes a loop: in simulation everything resolves to X, and in
    // synthesis the loop is unroutable. This is the standard Cummings
    // formulation and it is the one detail of an async FIFO that is
    // worth getting exactly right.
    wire wfull_val  = (wgray_nxt == {~rgray_w[AW:AW-1], rgray_w[AW-2:0]});
    wire rempty_val = (rgray_nxt == wgray_r);

    reg wfull_r, rempty_r;
    always @(posedge wclk or negedge wrst_n)
        if (!wrst_n) wfull_r <= 1'b0; else wfull_r <= wfull_val;
    always @(posedge rclk or negedge rrst_n)
        if (!rrst_n) rempty_r <= 1'b1; else rempty_r <= rempty_val;

    assign wfull  = wfull_r;
    assign rempty = rempty_r;

    // Gray -> binary of the synchronised read pointer, for the level count.
    integer i;
    reg [AW:0] rbin_w;
    always @(*) begin
        rbin_w[AW] = rgray_w[AW];
        for (i = AW-1; i >= 0; i = i - 1)
            rbin_w[i] = rbin_w[i+1] ^ rgray_w[i];
    end
    assign wlevel = wbin - rbin_w;

    reg [DW-1:0] dq;
    always @(posedge wclk) if (wr && !wfull) mem[wbin[AW-1:0]] <= din;
    always @(posedge rclk) if (rd && !rempty) dq <= mem[rbin[AW-1:0]];
    assign dout = dq;
endmodule

`default_nettype wire
