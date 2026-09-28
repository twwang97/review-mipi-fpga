//=====================================================================
// isp.v - 4-pixel-per-clock image pipeline.
//
//   isp_framer  : turns CSI-2 short-packet pulses into clean per-group
//                 start/end flags and (x,y) group coordinates
//   isp_blc     : black-level subtract with clamp
//   isp_defect  : 5-tap same-colour hot/dead pixel clamp
//   isp_gain    : Q4.8 digital gain, saturating  (uses 4 DSP mults)
//   isp_roi     : region-of-interest crop, group granularity in x
//   line_buffer : EBR-inferred line store
//   isp_bin2x2  : 2x2 binning, emits full 4-pixel groups at half rate
//   isp_pipeline: the chain
//
// Bus convention throughout:
//   g_vld              one 4-pixel group is valid this cycle
//   g_data[39:0]       pixel 0 in [9:0] ... pixel 3 in [39:30]
//   g_sof/g_eol/g_eof  group-aligned frame and line markers
//
// Verilog-2001.
//=====================================================================
`timescale 1ns/1ps
`default_nettype none
`include "cam_defs.vh"

//---------------------------------------------------------------------
// isp_framer
//---------------------------------------------------------------------
module isp_framer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [39:0] px_data,
    input  wire        px_vld,
    input  wire        px_sof,           // CSI-2 frame-start pulse
    input  wire        px_eof,
    input  wire        px_sol,
    input  wire [10:0] cfg_groups,       // pixels per line / 4
    input  wire [11:0] cfg_lines,

    output reg  [39:0] g_data,
    output reg         g_vld,
    output reg         g_sof,
    output reg         g_eol,
    output reg         g_eof,
    output reg  [10:0] g_x,
    output reg  [11:0] g_y,
    output reg         err_short_line
);
    reg        frame_pend;
    reg [10:0] xc;
    reg [11:0] yc;
    reg        first_of_line;

    wire last_group = (xc == (cfg_groups - 11'd1));
    wire last_line  = (yc == (cfg_lines  - 12'd1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_pend <= 1'b0; xc <= 11'd0; yc <= 12'd0;
            first_of_line <= 1'b1;
            g_vld <= 1'b0; g_sof <= 1'b0; g_eol <= 1'b0; g_eof <= 1'b0;
            g_data <= 40'd0; g_x <= 11'd0; g_y <= 12'd0;
            err_short_line <= 1'b0;
        end else begin
            g_vld <= 1'b0; g_sof <= 1'b0; g_eol <= 1'b0; g_eof <= 1'b0;
            err_short_line <= 1'b0;

            if (px_sof) begin frame_pend <= 1'b1; yc <= 12'd0; end

            if (px_sol) begin
                if (!first_of_line && (xc != 11'd0)) err_short_line <= 1'b1;
                xc <= 11'd0;
                first_of_line <= 1'b1;
            end

            if (px_vld) begin
                g_data <= px_data;
                g_vld  <= 1'b1;
                g_x    <= xc;
                g_y    <= yc;

                if (first_of_line && frame_pend) begin
                    g_sof      <= 1'b1;
                    frame_pend <= 1'b0;
                end
                first_of_line <= 1'b0;

                if (last_group) begin
                    g_eol <= 1'b1;
                    xc    <= 11'd0;
                    yc    <= yc + 12'd1;
                    if (last_line) g_eof <= 1'b1;
                end else begin
                    xc <= xc + 11'd1;
                end
            end

            if (px_eof) begin frame_pend <= 1'b0; end
        end
    end
endmodule

//---------------------------------------------------------------------
// isp_blc - subtract the black level, clamp at zero.
//---------------------------------------------------------------------
module isp_blc (
    input  wire        clk, input wire rst_n, input wire en,
    input  wire [9:0]  black,
    input  wire [39:0] d_i, input wire v_i, input wire [2:0] c_i,
    output reg  [39:0] d_o, output reg  v_o, output reg  [2:0] c_o
);
    function [9:0] sub_clamp;
        input [9:0] p; input [9:0] b;
        begin sub_clamp = (p > b) ? (p - b) : 10'd0; end
    endfunction

    integer k;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin d_o <= 40'd0; v_o <= 1'b0; c_o <= 3'd0; end
        else begin
            v_o <= v_i; c_o <= c_i;
            for (k = 0; k < 4; k = k + 1)
                d_o[k*10 +: 10] <= en ? sub_clamp(d_i[k*10 +: 10], black)
                                      : d_i[k*10 +: 10];
        end
endmodule

//---------------------------------------------------------------------
// isp_defect - clamp every pixel between its two same-colour
// neighbours (x-2 and x+2). One group of latency; the window spans the
// previous, current and next group so no line buffer is needed.
// Full 3x3 correction would need two line buffers - see line_buffer.
//---------------------------------------------------------------------
module isp_defect (
    input  wire        clk, input wire rst_n, input wire en,
    input  wire [39:0] d_i, input wire v_i, input wire [2:0] c_i,
    output reg  [39:0] d_o, output reg  v_o, output reg  [2:0] c_o
);
    reg [39:0] p0, p1;          // p1 = oldest, p0 = middle
    reg [2:0]  cq0, cq1;
    reg        vq0, vq1;

    // 12-pixel window: {d_i (newest), p0 (middle), p1 (oldest)}
    wire [119:0] win = {d_i, p0, p1};

    function [9:0] clamp3;
        input [9:0] a; input [9:0] p; input [9:0] b;
        reg   [9:0] lo, hi;
        begin
            lo = (a < b) ? a : b;
            hi = (a < b) ? b : a;
            clamp3 = (p < lo) ? lo : (p > hi) ? hi : p;
        end
    endfunction

    integer k;
    reg [39:0] corr;
    always @(*) begin
        // Correct the middle group, pixels 4..7 of the 12-pixel window.
        for (k = 0; k < 4; k = k + 1)
            corr[k*10 +: 10] = clamp3(win[(k+4-2)*10 +: 10],
                                      win[(k+4)*10   +: 10],
                                      win[(k+4+2)*10 +: 10]);
    end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            p0 <= 40'd0; p1 <= 40'd0;
            vq0 <= 1'b0; vq1 <= 1'b0; cq0 <= 3'd0; cq1 <= 3'd0;
            d_o <= 40'd0; v_o <= 1'b0; c_o <= 3'd0;
        end else begin
            if (v_i) begin
                p0  <= d_i; p1  <= p0;
                cq0 <= c_i; cq1 <= cq0;
            end
            vq0 <= v_i; vq1 <= vq0;
            v_o <= vq1;
            c_o <= cq1;
            d_o <= en ? corr : p1;
        end
endmodule

//---------------------------------------------------------------------
// isp_gain - Q4.8 unsigned gain, saturating to 10 bits.
//---------------------------------------------------------------------
module isp_gain (
    input  wire        clk, input wire rst_n, input wire en,
    input  wire [11:0] gain,                 // 12'h100 = unity
    input  wire [39:0] d_i, input wire v_i, input wire [2:0] c_i,
    output reg  [39:0] d_o, output reg  v_o, output reg  [2:0] c_o
);
    // One 10 x 12 multiplier per lane; Radiant maps these to sysDSP.
    wire [21:0] prod0 = d_i[ 9: 0] * gain;
    wire [21:0] prod1 = d_i[19:10] * gain;
    wire [21:0] prod2 = d_i[29:20] * gain;
    wire [21:0] prod3 = d_i[39:30] * gain;

    wire [9:0] s0 = (prod0[21:8] > 14'd1023) ? 10'd1023 : prod0[17:8];
    wire [9:0] s1 = (prod1[21:8] > 14'd1023) ? 10'd1023 : prod1[17:8];
    wire [9:0] s2 = (prod2[21:8] > 14'd1023) ? 10'd1023 : prod2[17:8];
    wire [9:0] s3 = (prod3[21:8] > 14'd1023) ? 10'd1023 : prod3[17:8];

    wire [39:0] sat = {s3, s2, s1, s0};

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin d_o <= 40'd0; v_o <= 1'b0; c_o <= 3'd0; end
        else begin
            v_o <= v_i; c_o <= c_i;
            d_o <= en ? sat : d_i;
        end
endmodule

//---------------------------------------------------------------------
// isp_roi - crop. x offset and width are in groups of four pixels;
// y offset and height are per line.
//---------------------------------------------------------------------
module isp_roi (
    input  wire        clk, input wire rst_n, input wire en,
    input  wire [10:0] off_xg, input wire [10:0] wid_g,
    input  wire [11:0] off_y,  input wire [11:0] hgt,
    input  wire [39:0] d_i, input wire v_i,
    input  wire        sof_i, input wire eol_i, input wire eof_i,
    input  wire [10:0] x_i,   input wire [11:0] y_i,
    output reg  [39:0] d_o, output reg  v_o,
    output reg         sof_o, output reg eol_o, output reg eof_o
);
    wire in_x = (x_i >= off_xg) && (x_i < (off_xg + wid_g));
    wire in_y = (y_i >= off_y)  && (y_i < (off_y  + hgt));
    wire keep = en ? (in_x && in_y) : 1'b1;

    wire last_x = (x_i == (off_xg + wid_g - 11'd1));
    wire last_y = (y_i == (off_y  + hgt   - 12'd1));

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            d_o <= 40'd0; v_o <= 1'b0;
            sof_o <= 1'b0; eol_o <= 1'b0; eof_o <= 1'b0;
        end else begin
            d_o   <= d_i;
            v_o   <= v_i && keep;
            sof_o <= v_i && keep && (en ? ((x_i == off_xg) && (y_i == off_y))
                                        : sof_i);
            eol_o <= v_i && keep && (en ? last_x : eol_i);
            eof_o <= v_i && keep && (en ? (last_x && last_y) : eof_i);
        end
endmodule

//---------------------------------------------------------------------
// line_buffer - simple dual-port synchronous RAM. Radiant maps this to
// sysMEM EBR. One 18 kb EBR holds 480 x 22 bits, which is exactly one
// full-width line of horizontal bin sums.
//---------------------------------------------------------------------
module line_buffer #(parameter DW = 22, parameter AW = 9) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] wa,
    input  wire [DW-1:0] wd,
    input  wire [AW-1:0] ra,
    output reg  [DW-1:0] rd
);
    (* syn_ramstyle = "block_ram" *) reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rd <= mem[ra];
    end
endmodule

//---------------------------------------------------------------------
// isp_bin2x2
//
// Horizontal: sum pixel pairs inside each group -> two 11-bit sums.
// Vertical  : even lines are written to the line buffer, odd lines are
//             added to it and produce output.
// Output    : two binned pixels per input group, packed into full
//             4-pixel groups, so the output group rate is half the
//             input group rate and the downstream stays 4-wide.
//---------------------------------------------------------------------
module isp_bin2x2 (
    input  wire        clk, input wire rst_n, input wire en,
    input  wire [39:0] d_i, input wire v_i,
    input  wire        sof_i, input wire eol_i, input wire eof_i,
    output reg  [39:0] d_o, output reg  v_o,
    output reg         sof_o, output reg eol_o, output reg eof_o
);
    reg [8:0]  xg;              // group index within the line
    reg        odd_line;
    reg        half;            // 0 = filling low half of the output group
    reg [19:0] lo_half;
    reg        sof_lat, eof_lat;

    wire [10:0] h0 = d_i[9:0]   + d_i[19:10];
    wire [10:0] h1 = d_i[29:20] + d_i[39:30];

    wire [21:0] wd = {h1, h0};
    wire [21:0] rd;

    line_buffer #(.DW(22), .AW(9)) u_lb (
        .clk(clk), .we(v_i && !odd_line && en), .wa(xg), .wd(wd),
        .ra(xg), .rd(rd)
    );

    // rd is one cycle late, so delay the odd-line data to match.
    reg [21:0] wd_q;
    reg        v_q, eol_q, eof_q, sof_q, odd_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            wd_q <= 22'd0; v_q <= 1'b0;
            eol_q <= 1'b0; eof_q <= 1'b0; sof_q <= 1'b0; odd_q <= 1'b0;
        end else begin
            wd_q  <= wd;   v_q   <= v_i;
            eol_q <= eol_i; eof_q <= eof_i; sof_q <= sof_i;
            odd_q <= odd_line;
        end

    wire [12:0] s0 = {2'd0, wd_q[10:0]} + {2'd0, rd[10:0]};
    wire [12:0] s1 = {2'd0, wd_q[21:11]} + {2'd0, rd[21:11]};
    wire [9:0]  q0 = s0[11:2];              // /4, back to 10 bits
    wire [9:0]  q1 = s1[11:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xg <= 9'd0; odd_line <= 1'b0; half <= 1'b0;
            lo_half <= 20'd0; d_o <= 40'd0; v_o <= 1'b0;
            sof_o <= 1'b0; eol_o <= 1'b0; eof_o <= 1'b0;
            sof_lat <= 1'b0; eof_lat <= 1'b0;
        end else if (!en) begin
            // bypass
            d_o <= d_i; v_o <= v_i;
            sof_o <= sof_i; eol_o <= eol_i; eof_o <= eof_i;
            xg <= 9'd0; odd_line <= 1'b0; half <= 1'b0;
        end else begin
            v_o <= 1'b0; sof_o <= 1'b0; eol_o <= 1'b0; eof_o <= 1'b0;

            if (v_i) begin
                if (eol_i) begin xg <= 9'd0; odd_line <= ~odd_line; end
                else             xg <= xg + 9'd1;
            end

            if (sof_i) begin odd_line <= 1'b0; half <= 1'b0; sof_lat <= 1'b1; end
            if (eof_i) eof_lat <= 1'b1;

            if (v_q && odd_q) begin
                if (!half) begin
                    lo_half <= {q1, q0};
                    half    <= 1'b1;
                    // An odd number of groups per line flushes at eol.
                    if (eol_q) begin
                        d_o   <= {20'd0, q1, q0};
                        v_o   <= 1'b1;
                        eol_o <= 1'b1;
                        eof_o <= eof_lat;
                        sof_o <= sof_lat; sof_lat <= 1'b0;
                        half  <= 1'b0;
                        eof_lat <= 1'b0;
                    end
                end else begin
                    d_o   <= {q1, q0, lo_half};
                    v_o   <= 1'b1;
                    half  <= 1'b0;
                    eol_o <= eol_q;
                    eof_o <= eol_q && eof_lat;
                    sof_o <= sof_lat; sof_lat <= 1'b0;
                    if (eol_q && eof_lat) eof_lat <= 1'b0;
                end
            end
        end
    end
endmodule

//---------------------------------------------------------------------
// isp_pipeline
//---------------------------------------------------------------------
module isp_pipeline (
    input  wire        clk,
    input  wire        rst_n,

    // configuration (all in the clk domain, quasi-static)
    input  wire [10:0] cfg_groups,
    input  wire [11:0] cfg_lines,
    input  wire        cfg_blc_en,
    input  wire [9:0]  cfg_black,
    input  wire        cfg_dpc_en,
    input  wire [11:0] cfg_gain,
    input  wire        cfg_roi_en,
    input  wire [10:0] cfg_off_xg,
    input  wire [10:0] cfg_wid_g,
    input  wire [11:0] cfg_off_y,
    input  wire [11:0] cfg_hgt,
    input  wire        cfg_bin_en,

    // from csi2_rx
    input  wire [39:0] px_data,
    input  wire        px_vld,
    input  wire        px_sof,
    input  wire        px_eof,
    input  wire        px_sol,

    // to the frame buffer
    output wire [39:0] o_data,
    output wire        o_vld,
    output wire        o_sof,
    output wire        o_eol,
    output wire        o_eof,
    output wire        err_short_line
);
    wire [39:0] f_d; wire f_v, f_sof, f_eol, f_eof;
    wire [10:0] f_x; wire [11:0] f_y;

    isp_framer u_fr (
        .clk(clk), .rst_n(rst_n),
        .px_data(px_data), .px_vld(px_vld),
        .px_sof(px_sof), .px_eof(px_eof), .px_sol(px_sol),
        .cfg_groups(cfg_groups), .cfg_lines(cfg_lines),
        .g_data(f_d), .g_vld(f_v), .g_sof(f_sof), .g_eol(f_eol),
        .g_eof(f_eof), .g_x(f_x), .g_y(f_y),
        .err_short_line(err_short_line)
    );

    // side-band travels as a 3-bit vector through blc/defect/gain
    wire [2:0] c_fr = {f_sof, f_eol, f_eof};

    wire [39:0] b_d; wire b_v; wire [2:0] b_c;
    isp_blc u_blc (.clk(clk), .rst_n(rst_n), .en(cfg_blc_en),
                   .black(cfg_black),
                   .d_i(f_d), .v_i(f_v), .c_i(c_fr),
                   .d_o(b_d), .v_o(b_v), .c_o(b_c));

    wire [39:0] p_d; wire p_v; wire [2:0] p_c;
    isp_defect u_dpc (.clk(clk), .rst_n(rst_n), .en(cfg_dpc_en),
                      .d_i(b_d), .v_i(b_v), .c_i(b_c),
                      .d_o(p_d), .v_o(p_v), .c_o(p_c));

    wire [39:0] g_d; wire g_v; wire [2:0] g_c;
    isp_gain u_gn (.clk(clk), .rst_n(rst_n), .en(1'b1), .gain(cfg_gain),
                   .d_i(p_d), .v_i(p_v), .c_i(p_c),
                   .d_o(g_d), .v_o(g_v), .c_o(g_c));

    // Re-derive coordinates after the fixed pipeline latency by delaying
    // the framer's counters by the same number of stages (3).
    reg [10:0] x1, x2, x3;
    reg [11:0] y1, y2, y3;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            x1 <= 0; x2 <= 0; x3 <= 0; y1 <= 0; y2 <= 0; y3 <= 0;
        end else begin
            x1 <= f_x; x2 <= x1; x3 <= x2;
            y1 <= f_y; y2 <= y1; y3 <= y2;
        end

    wire [39:0] r_d; wire r_v, r_sof, r_eol, r_eof;
    isp_roi u_roi (.clk(clk), .rst_n(rst_n), .en(cfg_roi_en),
                   .off_xg(cfg_off_xg), .wid_g(cfg_wid_g),
                   .off_y(cfg_off_y), .hgt(cfg_hgt),
                   .d_i(g_d), .v_i(g_v),
                   .sof_i(g_c[2]), .eol_i(g_c[1]), .eof_i(g_c[0]),
                   .x_i(x3), .y_i(y3),
                   .d_o(r_d), .v_o(r_v),
                   .sof_o(r_sof), .eol_o(r_eol), .eof_o(r_eof));

    isp_bin2x2 u_bin (.clk(clk), .rst_n(rst_n), .en(cfg_bin_en),
                      .d_i(r_d), .v_i(r_v),
                      .sof_i(r_sof), .eol_i(r_eol), .eof_i(r_eof),
                      .d_o(o_data), .v_o(o_vld),
                      .sof_o(o_sof), .eol_o(o_eol), .eof_o(o_eof));
endmodule

`default_nettype wire
