//=====================================================================
// cam_defs.vh - global parameters for the TIDA-010083 + LIFCL-40 +
//               AR0234CS machine-vision camera.
// Verilog-2001. Include once per file that needs it.
//=====================================================================
`ifndef CAM_DEFS_VH
`define CAM_DEFS_VH

// ---- sensor geometry -----------------------------------------------
`define SENSOR_W        1920
`define SENSOR_H        1200
`define COORD_W         12          // enough for 0..4095
`define PIX_W           10          // RAW10 from the AR0234CS

// ---- CSI-2 --------------------------------------------------------
`define CSI_LANES       4
`define CSI_DT_RAW8     6'h2A
`define CSI_DT_RAW10    6'h2B
`define CSI_DT_FS       6'h00       // frame start  (short packet)
`define CSI_DT_FE       6'h01       // frame end    (short packet)
`define CSI_DT_LS       6'h02       // line  start
`define CSI_DT_LE       6'h03       // line  end

// ---- network ------------------------------------------------------
`define MAC_ADDR_DEF    48'h02_00_5E_10_00_01
`define IP_ADDR_DEF     32'hC0_A8_01_40        // 192.168.1.64
`define IP_MASK_DEF     32'hFF_FF_FF_00
`define ETH_TYPE_IPV4   16'h0800
`define ETH_TYPE_ARP    16'h0806
`define IP_PROTO_ICMP   8'd1
`define IP_PROTO_UDP    8'd17

// GigE Vision well-known ports
`define GVCP_PORT       16'd3956
`define GVSP_PORT_DEF   16'd20202

// Payload bytes per GVSP packet. 8960 leaves room for Eth+IP+UDP+GVSP
// headers inside a 9000-byte jumbo MTU. Set to 1400 for a 1500 MTU.
`define GVSP_PAYLOAD    16'd8912

// ---- frame buffer -------------------------------------------------
// Byte address space of the external DDR3L (1 Gb x16 = 128 MiB).
`define FB_ADDR_W       27
`define FB_DATA_W       64          // user-side width of the DDR bridge
`define FB_NUM_BUFS     4           // ring of frame slots

// ---- register map (GVCP custom area, byte addresses) ---------------
`define REG_CTRL        16'h0000
`define REG_STATUS      16'h0004
`define REG_WIDTH       16'h0008
`define REG_HEIGHT      16'h000C
`define REG_OFFX        16'h0010
`define REG_OFFY        16'h0014
`define REG_BINNING     16'h0018
`define REG_GAIN        16'h001C
`define REG_BLACK       16'h0020
`define REG_TRIG_MODE   16'h0024
`define REG_TRIG_DELAY  16'h0028
`define REG_STROBE_DUR  16'h002C
`define REG_TS_LO       16'h0030
`define REG_TS_HI       16'h0034
`define REG_FRAME_CNT   16'h0038
`define REG_ERR_CNT     16'h003C
`define REG_PHY_STAT    16'h0040
`define REG_SENS_STAT   16'h0044

`endif
