"""Purpose: check staged camera constraints without starting Vivado.
Overview: exact byte preservation, fail-closed inputs and mocked Tcl clock ordering.
Revision: 11-14-2026.
"""
import hashlib
import contextlib
from collections import Counter
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import tkinter


def main():
    board = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('prep', board / 'scripts/rtlnet_prepare_camera_ip.py')
    prep = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prep)
    original = board / 'ip/digilent'
    if not (original / 'NOTICE.txt').is_file():
        print('RTLNET_CAMERA_PREP_CHECK: SKIPPED boards/zybo_z7_20/ip/digilent is absent (see the README, Third-party IP)')
        return
    vendor = original / 'vivado-library/ip'
    policy = json.loads((board / 'scripts/rtlnet_camera_xdc_manifest.json').read_text(encoding='utf-8'))
    bd = (board / 'bd/rtlnet_camera.tcl').read_text(encoding='utf-8')
    prep.require_debug_off(bd)
    # Either debug generic being enabled must reject the source before staging.
    for occurrence in (0, 1):
        match = list(re.finditer(r'CONFIG\.kDebug \{false\}', bd))[occurrence]
        mutated = bd[:match.start()] + 'CONFIG.kDebug {true}' + bd[match.end():]
        try:
            prep.require_debug_off(mutated)
        except ValueError:
            pass
        else:
            raise AssertionError('enabled debug generic accepted')
    for line in (original / 'NOTICE.txt').read_text(encoding='utf-8').splitlines():
        if re.match(r'^[0-9a-f]{64}  ', line):
            digest, relative = line.split('  ', 1)
            assert hashlib.sha256((original / relative).read_bytes()).hexdigest() == digest, relative
    # prepare() accepts only folders below boards/zybo_z7_20/build.
    (board / 'build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='prepcheck_', dir=board / 'build') as scratch:
        output = Path(scratch)
        prep.prepare(output)
        staged = output / 'ip_repo/vivado-library/ip'
        for relative, item in policy['files'].items():
            before = (vendor / relative).read_bytes().splitlines(keepends=True)
            after = (staged / relative).read_bytes().splitlines(keepends=True)
            assert len(before) == len(after)
            assert [n + 1 for n, (a, b) in enumerate(zip(before, after)) if a != b] == [v['line'] for v in item['omit']]
        merged = (staged / 'MIPI_CSI_2_RX/hdl/rtlnet_camera_debuglib.vhd').read_bytes()
        for name in ('MIPI_CSI_2_RX', 'MIPI_D_PHY_RX'):
            text = (vendor / name / 'hdl/DebugLib.vhd').read_text(encoding='utf-8')
            body = text.split('package DebugLib is', 1)[1].rsplit('end package;', 1)[0]
            assert body in merged.decode('utf-8').replace('\r\n', '\n')
        # A changed IP revision and a changed allowlisted line each fail closed.
        for change_line in (False, True):
            relative = 'MIPI_CSI_2_RX/hdl/mipi_csi2_rx.xdc'
            target = staged / relative
            data = (vendor / relative).read_bytes()
            mutated = data.replace(b'set_false_path -from', b'set_false_path  -from', 1)
            target.write_bytes(mutated)
            test_policy = json.loads(json.dumps(policy))
            if change_line:
                test_policy['files'][relative]['sha256'] = hashlib.sha256(mutated).hexdigest()
            try:
                prep.prepare_xdc(staged, test_policy)
            except ValueError:
                pass
            else:
                raise AssertionError('changed XDC accepted')
        prep.prepare(output)
        assert (staged / 'MIPI_CSI_2_RX/hdl/rtlnet_camera_debuglib.vhd').read_bytes() == merged
        # Tcl evaluates these exact constraints with a small clock/object model.
        # This checks syntax and read order, not Vivado object resolution/timing.
        tcl = tkinter.Tcl()
        tcl.eval('''
          set known_clock {}; set delay_count 0
          proc get_ports {args} {return [lindex $args end]}
          proc get_clocks {args} {return $::known_clock}
          proc create_clock {args} {set ::known_clock rtlnet_dphy_hs}
          proc set_input_delay {args} {
            set clk [lindex $args [expr {[lsearch -exact $args -clock] + 1}]]
            if {$clk eq {}} {error {missing forwarded clock}}
            incr ::delay_count
          }
        ''')
        dphy = (staged / 'MIPI_D_PHY_RX/hdl/MIPI_DPHY_Receiver_clocks.xdc').read_text(encoding='utf-8')
        try:
            tcl.eval(dphy)
        except tkinter.TclError:
            pass
        else:
            raise AssertionError('missing clock negative control passes')
        tcl.eval((board / 'constraints/rtlnet_camera_clocks.xdc').read_text(encoding='utf-8'))
        tcl.eval(dphy)
        tcl.eval((board / 'constraints/rtlnet_camera_timing.xdc').read_text(encoding='utf-8'))
        assert tcl.eval('set delay_count') == '12'
    print('RTLNET_CAMERA_PREP_CHECK: PASS 4 exact ILA edits; functional bytes and pristine hashes preserved')
    print('RTLNET_CAMERA_PREP_NEG: PASS debug-on, changed file, changed line and missing-clock controls reject')
    print('RTLNET_CAMERA_XDC_ORDER: PASS Tcl model applies 8 vendor and 4 mode input delays after clock creation')


if __name__ == '__main__':
    main()
