"""Purpose: import the unchanged Digilent camera IP and board files and emit the source-level BD recipe.
Overview: reads the published Digilent Pcam 5C demo hardware archive as data (the archive's project is never
  opened and none of its scripts runs). Writes ip/digilent, board_files, bd/rtlnet_camera.tcl and
  constraints/rtlnet_camera_pins.xdc under --out (default: the board folder).
Usage: python rtlnet_import_camera.py --hw-archive Zybo-Z7-20-Pcam-5C-hw.xpr.zip --board-files <vivado-boards>/new/board_files
  The archive and the board-file folder can also come from RTLNET_ZYBO_HW_ARCHIVE and RTLNET_ZYBO_BOARD_FILES.
Revision: 11-14-2026.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
from zipfile import ZipFile

# Digilent Zybo-Z7 release 20 / Pcam-5C / 2025.1-1 hardware project archive.
ARCHIVE_SHA256 = 'ae235e42e1956dff5269a4a1e1d78bfb3624bc2c6ec0bbc119bdb852da50ac13'
BOARD_FILE_NAMES = ('board.xml', 'part0_pins.xml', 'preset.xml')


def quote(value):
    if isinstance(value, list):
        value = ''.join(value)
    value = str(value)
    if any(c in value for c in '{}\n\r'):
        raise ValueError('Unsupported Tcl value')
    return '{' + value + '}'


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('Usage:')[0])
    parser.add_argument('--hw-archive', type=Path, default=os.environ.get('RTLNET_ZYBO_HW_ARCHIVE'))
    parser.add_argument('--board-files', type=Path, default=os.environ.get('RTLNET_ZYBO_BOARD_FILES'))
    parser.add_argument('--out', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    if not args.hw_archive or not Path(args.hw_archive).is_file():
        sys.exit('rtlnet_import_camera: missing Digilent hardware archive; pass --hw-archive or set '
                 'RTLNET_ZYBO_HW_ARCHIVE (Zybo-Z7-20-Pcam-5C-hw.xpr.zip of the Digilent Pcam 5C demo release)')
    if not args.board_files or not (Path(args.board_files) / 'zybo-z7-20/A.0/board.xml').is_file():
        sys.exit('rtlnet_import_camera: missing Digilent board files; pass --board-files or set '
                 'RTLNET_ZYBO_BOARD_FILES (a folder that contains zybo-z7-20/A.0/board.xml)')
    archive_bytes = Path(args.hw_archive).read_bytes()
    digest = hashlib.sha256(archive_bytes).hexdigest()
    if digest != ARCHIVE_SHA256:
        sys.exit('rtlnet_import_camera: archive SHA-256 ' + digest + ' differs from the expected ' + ARCHIVE_SHA256)
    board = args.out
    archive_path = Path(args.hw_archive)
    origins = ['local/ip/AXI_BayerToRGB', 'local/ip/AXI_GammaCorrection',
               'vivado-library/ip/MIPI_D_PHY_RX', 'vivado-library/ip/MIPI_CSI_2_RX']
    notices = ['Purpose: provenance of unchanged Digilent camera IP.',
               'Revision: 11-14-2026.',
               'Origin: Digilent Zybo-Z7 release 20/Pcam-5C/2025.1-1 hardware archive, SHA-256 ' + ARCHIVE_SHA256 + '.',
               'Hardware source snapshot: 4ae5bc1e84fb49a3fb806785486b3eb99fdae927.',
               'Nested IP commit is not established by the release archive; do not infer it.',
               'IP headers grant the MIT license. Original notices remain unchanged.',
               'Written by scripts/rtlnet_import_camera.py; scripts/rtlnet_prepare_camera_ip.py checks the file hashes.',
               'SHA256 manifest (paths relative to this directory):']
    with ZipFile(archive_path) as archive:
        design = json.loads(archive.read('hw/hw.srcs/sources_1/bd/system/system.bd').decode('utf-8'))['design']
        xdc = archive.read('hw/hw.srcs/constrs_1/imports/constraints/ZyboZ7_A.xdc').decode('utf-8').replace('\r\n', '\n')
        for member in archive.infolist():
            prefix = 'hw/hw.ipdefs/repo/'
            if member.is_dir() or not member.filename.startswith(prefix):
                continue
            relative = member.filename[len(prefix):]
            if not any(relative.startswith(origin + '/') for origin in origins):
                continue
            dst = (board / 'ip/digilent' / relative).resolve()
            dst.relative_to((board / 'ip/digilent').resolve())
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(archive.read(member))
    for origin in origins:
        dst = board / 'ip/digilent' / origin
        for path in sorted(dst.rglob('*')):
            if path.is_file():
                notices.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' +
                               path.relative_to(board / 'ip/digilent').as_posix())
    (board / 'ip/digilent').mkdir(parents=True, exist_ok=True)
    (board / 'ip/digilent/NOTICE.txt').write_text('\n'.join(notices) + '\n', encoding='utf-8', newline='\n')
    board_notice = ['Purpose: Digilent Zybo Z7-20 board-file provenance.',
                    'Revision: 11-14-2026.',
                    'Origin: Digilent vivado-boards, zybo-z7-20/A.0 (board.xml, part0_pins.xml, preset.xml).',
                    'The files keep their original MIT notices. Board identity: digilentinc.com:zybo-z7-20:part0:1.2,',
                    'xc7z020clg400-1. No processing-system preset is applied implicitly.',
                    'SHA256 manifest (paths relative to this directory):']
    for name in BOARD_FILE_NAMES:
        data = (Path(args.board_files) / 'zybo-z7-20/A.0' / name).read_bytes()
        dst = board / 'board_files/zybo-z7-20/A.0' / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(data)
        board_notice.append(hashlib.sha256(data).hexdigest() + '  zybo-z7-20/A.0/' + name)
    (board / 'board_files/NOTICE.txt').write_text('\n'.join(board_notice) + '\n', encoding='utf-8', newline='\n')
    keep = {'AXI_BayerToRGB_1', 'AXI_GammaCorrection_0', 'MIPI_CSI_2_RX_0',
            'MIPI_D_PHY_RX_0', 'processing_system7_0', 'rst_clk_wiz_0_50M',
            'axi_mem_intercon_1', 'axi_vdma_0', 'clk_wiz_0', 'ps7_0_axi_periph'}
    ext = set(design['ports']) | {'DDR', 'FIXED_IO', 'cam_gpio', 'cam_iic', 'dphy_hs_clock'}
    lines = ['# Purpose: reconstruct the camera-only BD in the installed Vivado.',
             '# Overview: generated from the published BD data; display path is absent.',
             '# Revision: 11-14-2026.', 'create_bd_design rtlnet_camera']
    for name, spec in design['interface_ports'].items():
        if name not in ext:
            continue
        lines.append(f'create_bd_intf_port -mode {spec["mode"]} -vlnv {quote(spec["vlnv"])} {name}')
        if name == 'dphy_hs_clock':
            lines.append('set_property CONFIG.FREQ_HZ 210000000 [get_bd_intf_ports dphy_hs_clock]')
    for name, spec in design['ports'].items():
        vector = f' -from {spec["left"]} -to {spec["right"]}' if 'left' in spec else ''
        lines.append(f'create_bd_port -dir {spec["direction"]}{vector} {name}')
    for name, spec in design['components'].items():
        if name not in keep:
            continue
        lines.append(f'create_bd_cell -type ip -vlnv {quote(spec["vlnv"])} {name}')
        params = {k: v['value'] for k, v in spec.get('parameters', {}).items()}
        if name == 'axi_vdma_0':
            params.update(c_include_mm2s='0')
            params.pop('c_s_axis_s2mm_tdata_width', None)  # propagated from gamma
            params.pop('c_mm2s_linebuffer_depth', None)  # MM2S is disabled
        if name == 'processing_system7_0':
            # The input snapshot includes derived GUI metadata; emit the hardware configuration only.
            params = {k: v for k, v in params.items() if not k.startswith('PCW_MIO_TREE_')}
            params.update(PCW_USE_S_AXI_HP0='0', PCW_USE_S_AXI_HP2='1')
            # Board manual Hardware errata: training already starts at zero for negative skew.
            for lane in range(4):
                params[f'PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_{lane}'] = '0.000'
        if name == 'ps7_0_axi_periph':
            params = {'NUM_MI': '4', 'NUM_SI': '1'}
        if params:
            lines.append('set_property -dict [list \\')
            lines.extend('  CONFIG.' + k + ' ' + quote(v) + ' \\' for k, v in params.items())
            lines.append(f'] [get_bd_cells {name}]')
    remap = {'ps7_0_axi_periph/M03_': 'ps7_0_axi_periph/M01_',
             'ps7_0_axi_periph/M04_': 'ps7_0_axi_periph/M02_',
             'ps7_0_axi_periph/M05_': 'ps7_0_axi_periph/M03_'}
    def retained(pin):
        if '/' not in pin:
            return pin in ext
        cell, port = pin.split('/', 1)
        if cell not in keep:
            return False
        if cell == 'axi_vdma_0' and ('mm2s' in port.lower() or port == 'M_AXI_MM2S'):
            return False
        if cell == 'processing_system7_0' and ('HP0' in port or port == 'IRQ_F2P'):
            return False
        return True
    for table, key, cmd, getpin, getport in [
            ('interface_nets', 'interface_ports', 'connect_bd_intf_net', 'get_bd_intf_pins', 'get_bd_intf_ports'),
            ('nets', 'ports', 'connect_bd_net', 'get_bd_pins', 'get_bd_ports')]:
        for name, spec in design[table].items():
            pins = [p for p in spec[key] if retained(p)]
            # The former display AXI ports disappear, then the camera ports compact.
            pins = [p for p in pins if not (p.startswith('ps7_0_axi_periph/M0') and
                    p.split('/')[1][1:3] in ('01', '02'))]
            pins = [next((p.replace(a, b) for a, b in remap.items() if p.startswith(a)), p) for p in pins]
            if len(pins) > 1:
                lines.append(cmd + ' ' + ' '.join(f'[{getpin if "/" in p else getport} {quote(p)}]' for p in pins))
    lines += ['create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 rtlnet_zero',
              'set_property -dict [list CONFIG.CONST_VAL 0 CONFIG.CONST_WIDTH 1] [get_bd_cells rtlnet_zero]',
              'connect_bd_net [get_bd_pins rtlnet_zero/dout] [get_bd_pins processing_system7_0/IRQ_F2P]',
              'create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rtlnet_rst_video',
              '# Reset polarity propagates from PS FCLK_RESET0_N; C_EXT_RESET_HIGH is derived.',
              'connect_bd_net [get_bd_pins rtlnet_video_clock/clk_out1] [get_bd_pins rtlnet_rst_video/slowest_sync_clk]',
              'connect_bd_net [get_bd_pins rtlnet_video_clock/locked] [get_bd_pins rtlnet_rst_video/dcm_locked]',
              'connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rtlnet_rst_video/ext_reset_in]',
              'foreach p {AXI_BayerToRGB_1/sStreamReset_n AXI_GammaCorrection_0/sStreamReset_n} {',
              '  disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins $p]] [get_bd_pins $p]',
              '  connect_bd_net [get_bd_pins rtlnet_rst_video/peripheral_aresetn] [get_bd_pins $p]',
              '}',
              '# Gamma selection and samples share the 90 MHz video clock; the interconnect converts GP0 control clocks.',
              'foreach p {AXI_GammaCorrection_0/AxiLiteClk ps7_0_axi_periph/M03_ACLK} {',
              '  disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins $p]] [get_bd_pins $p]',
              '  connect_bd_net [get_bd_pins rtlnet_video_clock/clk_out1] [get_bd_pins $p]',
              '}',
              'foreach p {AXI_GammaCorrection_0/aAxiLiteReset_n ps7_0_axi_periph/M03_ARESETN} {',
              '  disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins $p]] [get_bd_pins $p]',
              '  connect_bd_net [get_bd_pins rtlnet_rst_video/peripheral_aresetn] [get_bd_pins $p]',
              '}',
              '# The stage 0 capture interconnect runs on the video clock: its resets come from the video-clock reset controller',
              '# (a 50 MHz-domain reset has no common phase with the 90 MHz clock).',
              'foreach {p source} {axi_mem_intercon_1/ARESETN interconnect_aresetn axi_mem_intercon_1/S00_ARESETN peripheral_aresetn',
              '                    axi_mem_intercon_1/M00_ARESETN peripheral_aresetn} {',
              '  disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins $p]] [get_bd_pins $p]',
              '  connect_bd_net [get_bd_pins rtlnet_rst_video/$source] [get_bd_pins $p]',
              '}',
              'if {[info exists ::rtlnet_baseline] && $::rtlnet_baseline} {',
              '  source [file join [file dirname [info script]] rtlnet_baseline.tcl]',
              '}',
              'assign_bd_address -offset 0x43c00000 -range 0x10000 [get_bd_addr_segs MIPI_D_PHY_RX_0/S_AXI_LITE/S_AXI_LITE_reg]',
              'assign_bd_address -offset 0x43c10000 -range 0x10000 [get_bd_addr_segs MIPI_CSI_2_RX_0/S_AXI_LITE/S_AXI_LITE_reg]',
              'assign_bd_address -offset 0x43c20000 -range 0x10000 [get_bd_addr_segs AXI_GammaCorrection_0/s_axil/reg0]',
              'assign_bd_address', 'validate_bd_design',
              'if {$::rtlnet_baseline && [get_property CONFIG.PCW_NUM_F2P_INTR_INPUTS [get_bd_cells processing_system7_0]] != 16} {',
              '  error "Baseline IRQ_F2P must propagate to sixteen scalar concat inputs"',
              '}',
              'if {!$::rtlnet_baseline && [get_property CONFIG.c_s_axis_s2mm_tdata_width [get_bd_cells axi_vdma_0]] != 24} {',
              '  error "camera gamma-to-VDMA stream width must propagate to 24"',
              '}',
              'if {[get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells rtlnet_rst_video]] != 0} {',
              '  error "PS active-low reset polarity must propagate to video reset controller"',
              '}', 'save_bd_design']
    # Video clock plan (11-14-2026): clk_wiz_0 loses its 150 MHz output (50 MHz control and 200 MHz D-PHY
    # reference remain); a separate 90 MHz clock wizard serves the whole video stream path.
    video_clock = ['# Video clock plan (11-14-2026): the 150 MHz output of clk_wiz_0 is removed. The whole video stream path',
                   '# (CSI-2 receiver video side, Bayer, gamma, capture, HP capture port, encoder) runs on one 90 MHz clock.',
                   '# clk_wiz_0 keeps 50 MHz (control) and 200 MHz (D-PHY IDELAY reference); its former 150 MHz output stays',
                   '# unconnected and unbuffered so the wizard port numbering (clk_out3 = 200 MHz) is unchanged.',
                   'set_property CONFIG.CLKOUT2_DRIVES No_buffer [get_bd_cells clk_wiz_0]',
                   'create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 rtlnet_video_clock',
                   'set_property -dict [list CONFIG.PRIM_SOURCE Global_buffer CONFIG.PRIM_IN_FREQ 100 \\',
                   '  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 90 CONFIG.USE_RESET false] [get_bd_cells rtlnet_video_clock]']
    at = next(i for i, l in enumerate(lines) if 'ps7_0_axi_periph' in l and l.startswith('create_bd_cell'))
    lines[at:at] = video_clock
    lines = [l.replace('clk_wiz_0/clk_out2', 'rtlnet_video_clock/clk_out1').replace('{clk_wiz_0/clk_out2}', '{rtlnet_video_clock/clk_out1}') for l in lines]
    at = next(i for i, l in enumerate(lines) if 'FCLK_CLK0' in l and 'clk_wiz_0/clk_in1' in l)
    lines.insert(at + 1, 'connect_bd_net [get_bd_pins {processing_system7_0/FCLK_CLK0}] [get_bd_pins {rtlnet_video_clock/clk_in1}]')
    (board / 'bd').mkdir(exist_ok=True)
    (board / 'bd/rtlnet_camera.tcl').write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
    camera_pins = xdc[xdc.index('#MIPI'):xdc.index('#DUNNO')]
    (board / 'constraints').mkdir(exist_ok=True)
    (board / 'constraints/rtlnet_camera_pins.xdc').write_text(
        '# Purpose: Pcam pins from Digilent Zybo-Z7 release XDC.\n# Revision: 11-14-2026.\n' + camera_pins,
        encoding='utf-8', newline='\n')
    print('RTLNET_CAMERA_IMPORT: PASS unchanged IP copied; source-level Tcl emitted')


if __name__ == '__main__':
    main()
