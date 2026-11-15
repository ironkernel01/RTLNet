"""Purpose: derive the own-receiver video wrapper (rtlnet_zybo_video_own) from rtlnet_zybo_video.sv.
Overview: the reference wrapper takes the post-gamma RGB stream of the vendored Digilent chain; the own variant takes the D-PHY
  pins and contains the rtlnet_csi2_rx camera receiver (YUV422 pairs, no RGB adapter). Everything else (capture DMA, frame
  buffer, encoder, arbiter, HP bridges, camera admission registers) is the same text, so the two variants cannot drift: this
  script applies exact text patches to rtlnet_zybo_video.sv (every anchor must occur exactly once) and writes
  hdl/rtlnet_zybo_video_own.sv and its plain Verilog boundary hdl/rtlnet_zybo_video_own_bd.v. The reference file is never edited.
Usage: python rtlnet_generate_own_video.py            (write both files)
       python rtlnet_generate_own_video.py --check    (fail when a committed file differs from the generated text)
Revision: 11-15-2026. Initial own-receiver variant.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rtlnet_generate_video_wrapper import render as render_boundary

HEADER_ADD = '''  // 200 MHz D-PHY delay reference and the camera pins (names equal the board pin constraints).
  (* X_INTERFACE_IGNORE = "true" *)
  input logic ref_clk,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic dphy_hs_clock_clk_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic dphy_hs_clock_clk_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic dphy_clk_lp_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic dphy_clk_lp_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic [1:0] dphy_data_hs_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic [1:0] dphy_data_hs_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic [1:0] dphy_data_lp_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic [1:0] dphy_data_lp_n,
'''

FRONT_OLD = '''  assign admit = s_axis_video_tuser ? (camera_enable && (!camera_mode || !skip_phase)) : frame_admit;
  assign s_axis_video_tready = !admit || adapter_ready;
'''
FRONT_NEW = '''  assign admit = rx_tuser ? (camera_enable && (!camera_mode || !skip_phase)) : frame_admit;
  assign rx_tready = !admit || adapter_ready;
'''

RGB_START = '  // u_rgb implements rtlnet_rgb_to_yuyv in its explicitly connected clock domain.\n'
RGB_END = '    .format_error(adapter_error)\n  );\n'
RX_NEW = '''  // u_rx is the IronKernel CSI-2 camera receiver (rtlnet_csi2_rx, CAMERA_RX = 1): D-PHY pins in, YUV422 pairs out in capture_clk.
  // It cannot be stalled: its byte-clock FIFO drops and counts entries when the capture path is not ready (OVF counter).
  // The camera admission above discards the frames that are not admitted (ready high), so a skipped frame never stalls it.
  // Register window 0x44A0_9000 (index 5 of u_decode); the window has its own clock crossing inside the core.
  assign adapter_ready = adp_ready;
  assign adapter_error = 1'b0;
  assign adp_valid = rx_tvalid && admit;
  assign adp_pair = rx_tdata;
  assign adp_sof = rx_tuser;
  assign adp_eol = rx_tlast;
  rtlnet_csi2_rx #(.CAMERA_RX(1'b1), .DPHY_TARGET("AMD"), .NONCONT_CLOCK(1'b0), .IDELAYCTRL_INST(1'b1), .HS_DIFF_TERM(1'b0),
                     .WIDTH_720(WIDTH_720), .HEIGHT_720(HEIGHT_720), .WIDTH_1080(WIDTH_1080), .HEIGHT_1080(HEIGHT_1080)) u_rx (
    .clk(capture_clk),
    .resetn(capture_resetn),
    .s_axi_aclk(s_axi_aclk),
    .s_axi_aresetn(s_axi_aresetn),
    .s_cam_tdata(32'd0),
    .s_cam_tvalid(1'b0),
    .s_cam_tready(),
    .s_cam_tlast(1'b0),
    .s_cam_tuser(1'b0),
    .cam_clk_running(1'b0),
    .ref_clk(ref_clk),
    .dphy_clk_p(dphy_hs_clock_clk_p),
    .dphy_clk_n(dphy_hs_clock_clk_n),
    .dphy_clk_lp_p(dphy_clk_lp_p),
    .dphy_clk_lp_n(dphy_clk_lp_n),
    .dphy_dat_p(dphy_data_hs_p),
    .dphy_dat_n(dphy_data_hs_n),
    .dphy_dat_lp_p(dphy_data_lp_p),
    .dphy_dat_lp_n(dphy_data_lp_n),
    .m_axis_tdata(rx_tdata),
    .m_axis_tvalid(rx_tvalid),
    .m_axis_tready(rx_tready),
    .m_axis_tlast(rx_tlast),
    .m_axis_tuser(rx_tuser),
    .m_frame_num(),
    .m_timestamp(),
    .m_width(),
    .m_height(),
    .m_src_pattern(),
    .s_axi_awaddr(d_awaddr[160 +: 12]),
    .s_axi_awvalid(d_awvalid[5 +: 1]),
    .s_axi_awready(d_awready[5 +: 1]),
    .s_axi_wdata(d_wdata[160 +: 32]),
    .s_axi_wstrb(d_wstrb[20 +: 4]),
    .s_axi_wvalid(d_wvalid[5 +: 1]),
    .s_axi_wready(d_wready[5 +: 1]),
    .s_axi_bresp(d_bresp[10 +: 2]),
    .s_axi_bvalid(d_bvalid[5 +: 1]),
    .s_axi_bready(d_bready[5 +: 1]),
    .s_axi_araddr(d_araddr[160 +: 12]),
    .s_axi_arvalid(d_arvalid[5 +: 1]),
    .s_axi_arready(d_arready[5 +: 1]),
    .s_axi_rdata(d_rdata[160 +: 32]),
    .s_axi_rresp(d_rresp[10 +: 2]),
    .s_axi_rvalid(d_rvalid[5 +: 1]),
    .s_axi_rready(d_rready[5 +: 1])
  );
'''

DECODER_OLD = ('rtlnet_axil_decoder #(.N(5), .SLAVE_BASE({32\'h44a08000,32\'h44a07000,32\'h44a06000,32\'h44a04000,32\'h44a05000}), '
               '.SLAVE_SIZE({5{32\'h1000}})) u_decode (')
DECODER_NEW = ('rtlnet_axil_decoder #(.N(6), .SLAVE_BASE({32\'h44a09000,32\'h44a08000,32\'h44a07000,32\'h44a06000,32\'h44a04000,32\'h44a05000}), '
               '.SLAVE_SIZE({6{32\'h1000}})) u_decode (')

# (old, new) exact single-occurrence patches; counts of generic replacements are checked separately.
PATCHES = [
    ('module rtlnet_zybo_video #(', 'module rtlnet_zybo_video_own #('),
    ('// Purpose: integrate camera capture and one Baseline H.264 engine with PS HP ports.\n',
     '// Purpose: integrate the IronKernel CSI-2 camera receiver, capture and one Baseline H.264 engine with PS HP ports.\n'
     '// GENERATED by boards/zybo_z7_20/scripts/rtlnet_generate_own_video.py from rtlnet_zybo_video.sv: do not edit; change the\n'
     '// script or the reference file and regenerate. Differences to the reference: D-PHY pins and ref_clk instead of the RGB\n'
     '// stream, rtlnet_csi2_rx in place of the RGB adapter, a sixth register window at 0x44A0_9000, camera VERSION and CAPS.\n'),
    ('  // Video clock (90 MHz, the same clock as enc_clk in the board design), RGB stream and capture HP bus; reset releases locally.\n'
     '  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS_VIDEO:M_AXI_CAP, ASSOCIATED_RESET capture_resetn" *)\n',
     '  // Video clock (90 MHz, the same clock as enc_clk in the board design), receiver and capture HP bus; reset releases locally.\n'
     '  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXI_CAP, ASSOCIATED_RESET capture_resetn" *)\n'),
    (DECODER_OLD, DECODER_NEW),
    ('  logic [159:0] d_awaddr;\n', '  logic [191:0] d_awaddr;\n'),
    ('  logic [159:0] d_wdata;\n', '  logic [191:0] d_wdata;\n'),
    ('  logic [159:0] d_araddr;\n', '  logic [191:0] d_araddr;\n'),
    ('  logic [159:0] d_rdata;\n', '  logic [191:0] d_rdata;\n'),
    ('  logic [19:0] d_wstrb;\n', '  logic [23:0] d_wstrb;\n'),
    ('  logic [9:0] d_bresp;\n', '  logic [11:0] d_bresp;\n'),
    ('  logic [9:0] d_rresp;\n', '  logic [11:0] d_rresp;\n'),
    ('  logic [4:0] slice_keep_unused;\n',
     '  logic [4:0] slice_keep_unused;\n'
     '  logic [31:0] rx_tdata;\n  logic rx_tvalid;\n  logic rx_tready;\n  logic rx_tlast;\n  logic rx_tuser;\n'),
    (FRONT_OLD, FRONT_NEW),
    ('12\'h004: cam_reg_q <= 32\'h11142026;', '12\'h004: cam_reg_q <= 32\'h11152026;'),
    ('12\'h008: cam_reg_q <= 32\'h00000002;', '12\'h008: cam_reg_q <= 32\'h00000012;'),
    ('if (s_axis_video_tvalid && s_axis_video_tready && s_axis_video_tuser) begin',
     'if (rx_tvalid && rx_tready && rx_tuser) begin'),
]
for _n in ('awvalid', 'awready', 'wvalid', 'wready', 'bvalid', 'bready', 'arvalid', 'arready', 'rvalid', 'rready'):
    PATCHES.append((f'  logic [4:0] d_{_n};\n', f'  logic [5:0] d_{_n};\n'))


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'anchor occurs {text.count(old)} times, expected 1: {old[:70]!r}')
    return text.replace(old, new)


def render_own(board):
    text = (board / 'hdl/rtlnet_zybo_video.sv').read_text(encoding='utf-8')
    for old, new in PATCHES:
        text = once(text, old, new)
    # The RGB stream ports (eleven lines, from the comment to the TLAST port) become the D-PHY ports.
    start = text.index('  // Post-gamma camera pixels, capture_clk: R[23:16], B[15:8], G[7:0], SOF/EOL.\n')
    end_marker = '  input logic s_axis_video_tlast,\n'
    end = text.index(end_marker) + len(end_marker)
    text = text[:start] + HEADER_ADD + text[end:]
    start = text.index(RGB_START)
    end = text.index(RGB_END) + len(RGB_END)
    text = text[:start] + RX_NEW + text[end:]
    if 's_axis_video' in text or 'u_rgb' in text:
        raise ValueError('reference stream remnants in the own wrapper')
    return text


def render_own_boundary(board, own_text):
    return render_boundary(board, source_text=own_text, module='rtlnet_zybo_video_own',
                           generator='rtlnet_generate_own_video.py')


def targets(board):
    own = render_own(board)
    boundary = render_own_boundary(board, own)
    return {board / 'hdl/rtlnet_zybo_video_own.sv': own, board / 'hdl/rtlnet_zybo_video_own_bd.v': boundary}


def check(board):
    for path, text in targets(board).items():
        if not path.is_file() or path.read_text(encoding='utf-8') != text:
            raise ValueError(f'{path.name} is stale; run rtlnet_generate_own_video.py')


def main():
    board = Path(__file__).resolve().parents[1]
    if '--check' in sys.argv:
        check(board)
        print('RTLNET_OWN_VIDEO: PASS generated own-receiver wrapper and boundary are current')
    else:
        for path, text in targets(board).items():
            path.write_text(text, encoding='utf-8', newline='\n')
        print('RTLNET_OWN_VIDEO: wrote hdl/rtlnet_zybo_video_own.sv and hdl/rtlnet_zybo_video_own_bd.v')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as exc:
        print('RTLNET_OWN_VIDEO: FAIL ' + str(exc), file=sys.stderr)
        sys.exit(1)
