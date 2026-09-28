//=====================================================================
// net_stack.v - Ethernet / ARP / IPv4 / ICMP / UDP.
//
//   ip_cksum16  : one's-complement header checksum
//   net_rx      : single-pass parser for Ethernet + ARP + IPv4 + UDP
//   arp_reply   : builds the 28-byte ARP reply body
//   icmp_echo   : buffers a ping request and replays it
//   tx_compose  : builds Ethernet [+ IPv4 + UDP] headers and streams
//                 a frame to mac_tx
//   tx_arbiter  : fixed priority - GVSP stream, then GVCP, ICMP, ARP
//
// The UDP checksum is transmitted as zero, which IPv4 permits and
// which the GigE Vision specification allows. The IPv4 header checksum
// is always computed.
//
// Verilog-2001.
//=====================================================================
`timescale 1ns/1ps
`default_nettype none
`include "cam_defs.vh"

//---------------------------------------------------------------------
// ip_cksum16 - folds a 20-byte IPv4 header into a 16-bit checksum.
//---------------------------------------------------------------------
module ip_cksum16 (
    input  wire [159:0] hdr,          // byte 0 in [159:152]
    output wire [15:0]  cks
);
    wire [15:0] w0 = hdr[159:144];
    wire [15:0] w1 = hdr[143:128];
    wire [15:0] w2 = hdr[127:112];
    wire [15:0] w3 = hdr[111:96];
    wire [15:0] w4 = hdr[95:80];
    wire [15:0] w5 = 16'h0000;        // checksum field itself
    wire [15:0] w6 = hdr[63:48];
    wire [15:0] w7 = hdr[47:32];
    wire [15:0] w8 = hdr[31:16];
    wire [15:0] w9 = hdr[15:0];

    wire [19:0] sum = w0 + w1 + w2 + w3 + w4 + w5 + w6 + w7 + w8 + w9;
    wire [16:0] f1  = sum[15:0] + {4'd0, sum[19:16]};
    wire [15:0] f2  = f1[15:0] + {15'd0, f1[16]};
    assign cks = ~f2;
endmodule

//---------------------------------------------------------------------
// net_rx - byte-serial parser.
//---------------------------------------------------------------------
module net_rx (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  f_data,
    input  wire        f_vld,
    input  wire        f_sof,
    input  wire        f_eof,
    input  wire        f_crc_ok,

    input  wire [47:0] my_mac,
    input  wire [31:0] my_ip,

    // ARP request for our IP
    output reg         arp_req,
    output reg  [47:0] arp_sha,
    output reg  [31:0] arp_spa,

    // ICMP echo request
    output reg         icmp_req,
    output reg  [15:0] icmp_len,       // ICMP payload bytes after the 8-byte header
    output reg  [7:0]  icmp_d,
    output reg         icmp_d_vld,
    output reg  [15:0] icmp_id,
    output reg  [15:0] icmp_seq,

    // UDP delivery
    output reg         udp_vld,
    output reg  [7:0]  udp_d,
    output reg         udp_sop,
    output reg         udp_eop,
    output reg  [15:0] udp_sport,
    output reg  [15:0] udp_dport,
    output reg  [15:0] udp_len,

    // peer identity, latched at the start of every accepted frame
    output reg  [47:0] peer_mac,
    output reg  [31:0] peer_ip,

    output reg  [15:0] rx_frames
);
    reg [10:0] bc;                     // byte counter within the frame
    reg [15:0] ethertype;
    reg [47:0] dmac, smac;
    reg [31:0] sip, dip;
    reg [7:0]  ipproto;
    reg [15:0] iplen;
    reg [3:0]  ihl;
    reg [15:0] udplen_r;
    reg        accept;
    reg        is_ip, is_arp;
    reg [15:0] arp_op;
    reg [31:0] arp_tpa_r;
    reg [47:0] arp_sha_r;
    reg [31:0] arp_spa_r;

    wire bcast = (dmac == 48'hFFFFFFFFFFFF);
    wire forme = (dmac == my_mac);

    // start of the IP payload, in frame byte offsets
    wire [10:0] ip_start  = 11'd14;
    wire [10:0] pay_start = ip_start + {7'd0, ihl, 2'd0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bc <= 11'd0; ethertype <= 16'd0; dmac <= 48'd0; smac <= 48'd0;
            sip <= 32'd0; dip <= 32'd0; ipproto <= 8'd0; iplen <= 16'd0;
            ihl <= 4'd5; accept <= 1'b0; is_ip <= 1'b0; is_arp <= 1'b0;
            arp_op <= 16'd0; arp_tpa_r <= 32'd0;
            arp_sha_r <= 48'd0; arp_spa_r <= 32'd0;
            arp_req <= 1'b0; arp_sha <= 48'd0; arp_spa <= 32'd0;
            icmp_req <= 1'b0; icmp_len <= 16'd0; icmp_d <= 8'd0;
            icmp_d_vld <= 1'b0; icmp_id <= 16'd0; icmp_seq <= 16'd0;
            udp_vld <= 1'b0; udp_d <= 8'd0; udp_sop <= 1'b0; udp_eop <= 1'b0;
            udp_sport <= 16'd0; udp_dport <= 16'd0; udp_len <= 16'd0;
            udplen_r <= 16'd0;
            peer_mac <= 48'd0; peer_ip <= 32'd0; rx_frames <= 16'd0;
        end else begin
            arp_req <= 1'b0; icmp_req <= 1'b0; icmp_d_vld <= 1'b0;
            udp_vld <= 1'b0; udp_sop <= 1'b0; udp_eop <= 1'b0;

            if (f_sof) begin
                bc <= 11'd0; accept <= 1'b1;
                is_ip <= 1'b0; is_arp <= 1'b0; ihl <= 4'd5;
            end

            if (f_vld && accept) begin
                bc <= bc + 11'd1;

                // ---- Ethernet header -------------------------------
                if (bc < 11'd6)       dmac <= {dmac[39:0], f_data};
                else if (bc < 11'd12) smac <= {smac[39:0], f_data};
                else if (bc == 11'd12) ethertype[15:8] <= f_data;
                else if (bc == 11'd13) begin
                    ethertype[7:0] <= f_data;
                    if (!(bcast || forme)) accept <= 1'b0;
                    is_ip  <= ({ethertype[15:8], f_data} == `ETH_TYPE_IPV4);
                    is_arp <= ({ethertype[15:8], f_data} == `ETH_TYPE_ARP);
                    peer_mac <= smac;
                end

                // ---- ARP -------------------------------------------
                else if (is_arp) begin
                    case (bc)
                    11'd20: arp_op[15:8] <= f_data;
                    11'd21: arp_op[7:0]  <= f_data;
                    11'd22, 11'd23, 11'd24,
                    11'd25, 11'd26, 11'd27: arp_sha_r <= {arp_sha_r[39:0], f_data};
                    11'd28, 11'd29, 11'd30,
                    11'd31: arp_spa_r <= {arp_spa_r[23:0], f_data};
                    11'd38, 11'd39, 11'd40,
                    11'd41: begin
                        arp_tpa_r <= {arp_tpa_r[23:0], f_data};
                        if (bc == 11'd41) begin
                            if (({arp_tpa_r[23:0], f_data} == my_ip) &&
                                (arp_op == 16'd1)) begin
                                arp_req  <= 1'b1;
                                arp_sha  <= arp_sha_r;
                                arp_spa  <= arp_spa_r;
                                peer_ip  <= arp_spa_r;
                            end
                        end
                    end
                    default: ;
                    endcase
                end

                // ---- IPv4 ------------------------------------------
                else if (is_ip) begin
                    if (bc == ip_start)           ihl     <= f_data[3:0];
                    else if (bc == ip_start + 2)  iplen[15:8] <= f_data;
                    else if (bc == ip_start + 3)  iplen[7:0]  <= f_data;
                    else if (bc == ip_start + 9)  ipproto <= f_data;
                    else if ((bc >= ip_start + 12) && (bc <= ip_start + 15))
                        sip <= {sip[23:0], f_data};
                    else if ((bc >= ip_start + 16) && (bc <= ip_start + 19)) begin
                        dip <= {dip[23:0], f_data};
                        if (bc == ip_start + 19) begin
                            peer_ip <= sip;
                            if ({dip[23:0], f_data} != my_ip) accept <= 1'b0;
                        end
                    end

                    // ---- ICMP --------------------------------------
                    else if ((ipproto == `IP_PROTO_ICMP) && (bc >= pay_start)) begin
                        if (bc == pay_start) begin
                            if (f_data != 8'd8) accept <= 1'b0;   // echo request only
                        end
                        else if (bc == pay_start + 4) icmp_id[15:8]  <= f_data;
                        else if (bc == pay_start + 5) icmp_id[7:0]   <= f_data;
                        else if (bc == pay_start + 6) icmp_seq[15:8] <= f_data;
                        else if (bc == pay_start + 7) begin
                            icmp_seq[7:0] <= f_data;
                            icmp_len <= iplen - {7'd0, ihl, 2'd0} - 16'd8;
                            icmp_req <= 1'b1;
                        end
                        else if (bc > pay_start + 7) begin
                            icmp_d     <= f_data;
                            icmp_d_vld <= 1'b1;
                        end
                    end

                    // ---- UDP ---------------------------------------
                    else if ((ipproto == `IP_PROTO_UDP) && (bc >= pay_start)) begin
                        if (bc == pay_start)          udp_sport[15:8] <= f_data;
                        else if (bc == pay_start + 1) udp_sport[7:0]  <= f_data;
                        else if (bc == pay_start + 2) udp_dport[15:8] <= f_data;
                        else if (bc == pay_start + 3) udp_dport[7:0]  <= f_data;
                        else if (bc == pay_start + 4) udplen_r[15:8]  <= f_data;
                        else if (bc == pay_start + 5) begin
                            udplen_r[7:0] <= f_data;
                            udp_len <= {udplen_r[15:8], f_data} - 16'd8;
                        end
                        else if (bc >= pay_start + 8) begin
                            udp_d   <= f_data;
                            udp_vld <= 1'b1;
                            udp_sop <= (bc == pay_start + 8);
                            udp_eop <= (bc == (pay_start + 7 + udp_len));
                        end
                    end
                end
            end

            if (f_eof) begin
                accept <= 1'b0;
                if (f_crc_ok) rx_frames <= rx_frames + 16'd1;
            end
        end
    end
endmodule

//---------------------------------------------------------------------
// arp_reply - produces the 28-byte ARP body for tx_compose RAW mode.
//---------------------------------------------------------------------
module arp_reply (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire [47:0] sha,
    input  wire [31:0] spa,
    input  wire [47:0] my_mac,
    input  wire [31:0] my_ip,

    output reg         tx_req,
    output reg  [47:0] tx_dmac,
    input  wire        tx_gnt,
    output wire [7:0]  tx_d,
    output wire        tx_vld,
    input  wire        tx_rdy,
    output wire        tx_last,
    output wire [15:0] tx_len
);
    reg [223:0] body;                 // 28 bytes
    reg [4:0]   idx;
    reg         busy;

    assign tx_len  = 16'd28;
    assign tx_d    = body[223:216];
    assign tx_vld  = busy && tx_gnt;
    assign tx_last = busy && (idx == 5'd27);

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            body <= 224'd0; idx <= 5'd0; busy <= 1'b0;
            tx_req <= 1'b0; tx_dmac <= 48'd0;
        end else begin
            if (req && !busy) begin
                body <= {16'h0001, 16'h0800, 8'd6, 8'd4, 16'h0002,
                         my_mac, my_ip, sha, spa};
                tx_dmac <= sha;
                tx_req  <= 1'b1;
                busy    <= 1'b1;
                idx     <= 5'd0;
            end
            if (busy && tx_gnt && tx_rdy) begin
                body <= {body[215:0], 8'd0};
                if (idx == 5'd27) begin
                    busy <= 1'b0; tx_req <= 1'b0; idx <= 5'd0;
                end else idx <= idx + 5'd1;
            end
        end
endmodule

//---------------------------------------------------------------------
// icmp_echo - buffers up to 512 payload bytes and replays them.
// Longer pings are silently dropped; that is a deliberate bound, not
// an oversight, and is documented in the RTL README.
//---------------------------------------------------------------------
module icmp_echo (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire [15:0] len,
    input  wire [7:0]  d,
    input  wire        d_vld,
    input  wire [15:0] id,
    input  wire [15:0] seq,
    input  wire [31:0] peer_ip,
    input  wire [47:0] peer_mac,

    output reg         tx_req,
    output reg  [31:0] tx_dip,
    output reg  [47:0] tx_dmac,
    input  wire        tx_gnt,
    output wire [7:0]  tx_d,
    output wire        tx_vld,
    input  wire        tx_rdy,
    output wire        tx_last,
    output reg  [15:0] tx_len
);
    localparam MAXB = 512;

    reg [7:0]  buf_mem [0:MAXB-1];
    reg [9:0]  wp, rp;
    reg [15:0] plen;
    reg        capturing, sending;
    reg [3:0]  hdr_idx;
    reg [15:0] id_r, seq_r, cks;
    reg [19:0] acc;
    reg        odd;
    reg [7:0]  hi_byte;

    wire [16:0] fold1 = acc[15:0] + {4'd0, acc[19:16]};
    wire [15:0] fold2 = fold1[15:0] + {15'd0, fold1[16]};

    reg [7:0] hdr_b;
    always @(*) begin
        case (hdr_idx)
        4'd0: hdr_b = 8'd0;            // type = echo reply
        4'd1: hdr_b = 8'd0;            // code
        4'd2: hdr_b = cks[15:8];
        4'd3: hdr_b = cks[7:0];
        4'd4: hdr_b = id_r[15:8];
        4'd5: hdr_b = id_r[7:0];
        4'd6: hdr_b = seq_r[15:8];
        default: hdr_b = seq_r[7:0];
        endcase
    end

    // Combinational output: the valid stays asserted for the whole
    // transfer and the byte advances only when the composer accepts it.
    assign tx_d    = (hdr_idx < 4'd8) ? hdr_b : buf_mem[rp];
    assign tx_vld  = sending;
    assign tx_last = sending && (hdr_idx >= 4'd8) &&
                     (rp == (plen[9:0] - 10'd1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= 10'd0; rp <= 10'd0; plen <= 16'd0;
            capturing <= 1'b0; sending <= 1'b0; hdr_idx <= 4'd0;
            id_r <= 16'd0; seq_r <= 16'd0; cks <= 16'd0; acc <= 20'd0;
            tx_req <= 1'b0; tx_dip <= 32'd0; tx_dmac <= 48'd0;
            tx_len <= 16'd0; odd <= 1'b0; hi_byte <= 8'd0;
        end else begin
            if (req && !sending && !capturing) begin
                capturing <= (len <= MAXB) && (len != 16'd0);
                wp        <= 10'd0;
                plen      <= len;
                id_r      <= id;
                seq_r     <= seq;
                tx_dip    <= peer_ip;
                tx_dmac   <= peer_mac;
                acc       <= {4'd0, id} + {4'd0, seq};
                odd       <= 1'b0;
            end

            if (capturing && d_vld) begin
                buf_mem[wp] <= d;
                wp <= wp + 10'd1;
                if (!odd) hi_byte <= d;
                else      acc <= acc + {4'd0, hi_byte, d};
                odd <= ~odd;
                if (wp == (plen[9:0] - 10'd1)) begin
                    capturing <= 1'b0;
                    if (odd) acc <= acc + {4'd0, d, 8'd0};
                    cks     <= ~fold2;
                    tx_req  <= 1'b1;
                    sending <= 1'b1;
                    rp      <= 10'd0;
                    hdr_idx <= 4'd0;
                    tx_len  <= plen + 16'd8;
                end
            end

            if (sending && tx_gnt && tx_rdy) begin
                if (hdr_idx < 4'd8) hdr_idx <= hdr_idx + 4'd1;
                else begin
                    rp <= rp + 10'd1;
                    if (rp == (plen[9:0] - 10'd1)) begin
                        sending <= 1'b0;
                        tx_req  <= 1'b0;
                    end
                end
            end
        end
    end
endmodule

//---------------------------------------------------------------------
// tx_compose - builds the outgoing frame.
//   mode 0 : RAW  - payload is the whole Ethernet payload (ARP)
//   mode 1 : UDP  - insert IPv4 + UDP headers
//---------------------------------------------------------------------
module tx_compose (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [1:0]  mode,            // 0 = raw, 1 = UDP, 2 = ICMP
    input  wire [47:0] dmac,
    input  wire [15:0] ethertype,
    input  wire [31:0] dip,
    input  wire [15:0] sport,
    input  wire [15:0] dport,
    input  wire [15:0] plen,            // payload bytes
    input  wire [47:0] my_mac,
    input  wire [31:0] my_ip,
    output wire        busy,

    // payload source: p_vld/p_rdy is a standard handshake, one byte per
    // cycle in which both are high. The earlier version re-latched
    // p_data on every cycle the MAC was not ready, which transmitted
    // the same byte several times and desynchronised the source.
    output wire        p_rdy,
    input  wire [7:0]  p_data,
    input  wire        p_vld,

    // to mac_tx
    output wire [7:0]  f_data,
    output wire        f_vld,
    output wire        f_eof,
    input  wire        f_rdy
);
    localparam C_IDLE = 2'd0, C_HDR = 2'd1, C_PAY = 2'd2, C_PAD = 2'd3;

    reg [1:0]   st;
    reg [5:0]   hi, hlen;
    reg [15:0]  left, sent;
    reg [111:0] eth;
    reg [159:0] ip;
    reg [63:0]  udp;
    reg [15:0]  ipid;

    wire [15:0] cks;
    ip_cksum16 u_ck (.hdr(ip), .cks(cks));

    reg [7:0] hbyte;
    always @(*) begin
        if (hi < 6'd14)                     hbyte = eth[111 - 8*hi -: 8];
        else if ((mode != 2'd0) && hi < 6'd34)
                                            hbyte = ip [159 - 8*(hi-6'd14) -: 8];
        else if (mode == 2'd1)              hbyte = udp[63  - 8*(hi-6'd34) -: 8];
        else                                hbyte = 8'd0;
    end

    wire [7:0] hdr_out = ((mode != 2'd0) && (hi == 6'd24)) ? cks[15:8] :
                         ((mode != 2'd0) && (hi == 6'd25)) ? cks[7:0]  : hbyte;

    wire       need_pad = ((hlen + left) < 16'd60);
    wire       last_pay = (st == C_PAY) && p_vld && (sent == (left - 16'd1));
    wire       last_pad = (st == C_PAD) && ((hlen + sent) >= 16'd59);

    assign f_data = (st == C_HDR) ? hdr_out :
                    (st == C_PAY) ? p_data  : 8'd0;
    assign f_vld  = (st == C_HDR) || (st == C_PAD) ||
                    ((st == C_PAY) && p_vld);
    assign f_eof  = (last_pay && !need_pad) || last_pad;
    assign p_rdy  = (st == C_PAY) && f_rdy;
    assign busy   = (st != C_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= C_IDLE; hi <= 6'd0; hlen <= 6'd14;
            left <= 16'd0; sent <= 16'd0;
            eth <= 112'd0; ip <= 160'd0; udp <= 64'd0; ipid <= 16'd0;
        end else begin
            case (st)
            C_IDLE: if (start) begin
                eth  <= {dmac, my_mac, (mode != 2'd0) ? `ETH_TYPE_IPV4
                                                      : ethertype};
                ip   <= {8'h45, 8'h00,
                         plen + ((mode == 2'd1) ? 16'd28 : 16'd20),
                         ipid, 16'h4000, 8'd64,
                         (mode == 2'd1) ? `IP_PROTO_UDP : `IP_PROTO_ICMP,
                         16'h0000, my_ip, dip};
                udp  <= {sport, dport, plen + 16'd8, 16'h0000};
                hlen <= (mode == 2'd0) ? 6'd14 :
                        (mode == 2'd1) ? 6'd42 : 6'd34;
                hi   <= 6'd0;
                left <= plen;
                sent <= 16'd0;
                ipid <= ipid + 16'd1;
                st   <= C_HDR;
            end

            C_HDR: if (f_rdy) begin
                if (hi == (hlen - 6'd1)) st <= C_PAY;
                else                     hi <= hi + 6'd1;
            end

            C_PAY: if (f_rdy && p_vld) begin
                sent <= sent + 16'd1;
                if (sent == (left - 16'd1))
                    st <= need_pad ? C_PAD : C_IDLE;
            end

            C_PAD: if (f_rdy) begin
                sent <= sent + 16'd1;
                if ((hlen + sent) >= 16'd59) st <= C_IDLE;
            end
            endcase
        end
    end
endmodule

`default_nettype wire
