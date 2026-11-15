"""Purpose: exercise the deviation and vendor-review policies without Vivado.
Overview: exact-path fixtures and negative controls; source audit is not hardware proof.
Revision: 11-14-2026.
"""
from pathlib import Path
import re
import tempfile
import tkinter


def main():
    board = Path(__file__).resolve().parents[1]
    tcl = tkinter.Tcl()
    tcl.call('source', (board / 'scripts/rtlnet_camera_timing_gate.tcl').as_posix())
    tcl.call('source', (board / 'scripts/rtlnet_camera_waivers.tcl').as_posix())
    endpoints = tcl.splitlist(tcl.eval('set ::rtlnet_camera_timing::endpoints'))
    good_setup = (endpoints[0], -0.184, endpoints[1], -0.223, 'fabric/D', 0.260)
    good_hold = (endpoints[0], -1.431, endpoints[1], -1.388, 'fabric/D', 0.050)
    result = tcl.call('rtlnet_camera_timing::classify', good_setup, good_hold, 0.264, 0)
    assert str(tcl.call('dict', 'get', result, 'deviation')) == '1'
    assert float(tcl.call('dict', 'get', result, 'wns')) == 0.260
    assert float(tcl.call('dict', 'get', result, 'whs')) == 0.050
    for setup, hold, pulse, count in (
        (good_setup + ('unexpected/D', -0.001), good_hold, 0.264, 0),
        (good_setup, good_hold + ('unexpected/CLR', -0.001), 0.264, 0),
        ((endpoints[0], -0.2, 'fabric/D', 0.2), (endpoints[0], -1.4, 'fabric/D', 0.1), 0.2, 0),
        (good_setup, good_hold, -0.001, 1),
        (good_setup, good_hold, 0.2, 1),
        ((), good_hold, 0.2, 0),
    ):
        try:
            tcl.call('rtlnet_camera_timing::classify', setup, hold, pulse, count)
        except tkinter.TclError:
            pass
        else:
            raise AssertionError('Unsafe timing fixture accepted')
    # No failing paths means no deviation, rather than a fabricated exception.
    result = tcl.call('rtlnet_camera_timing::classify', ('fabric/D', 0.2), ('fabric/D', 0.1), 0.2, 0)
    assert str(tcl.call('dict', 'get', result, 'deviation')) == '0'
    print('RTLNET_DPHY_GATE_TEST: PASS exact two-endpoint deviation; other setup/hold, missing endpoint, empty evidence and pulse failures reject')
    # Execute actual netlist-query orchestration with a complete endpoint model.
    query = tkinter.Tcl()
    query.call('source', (board / 'scripts/rtlnet_camera_timing_gate.tcl').as_posix())
    properties = {
        ('S0', 'ENDPOINT_PIN'): endpoints[1], ('S0', 'SLACK'): '-0.223',
        ('S1', 'ENDPOINT_PIN'): endpoints[0], ('S1', 'SLACK'): '-0.184',
        ('S2', 'ENDPOINT_PIN'): 'fabric/D', ('S2', 'SLACK'): '0.260',
        ('H0', 'ENDPOINT_PIN'): endpoints[0], ('H0', 'SLACK'): '-1.431',
        ('H1', 'ENDPOINT_PIN'): endpoints[1], ('H1', 'SLACK'): '-1.388',
        ('H2', 'ENDPOINT_PIN'): 'fabric/D', ('H2', 'SLACK'): '0.050',
    }
    state = {'missing': False, 'primitive': 'ISERDESE2'}
    def pins(*args):
        name = re.fullmatch(r'NAME == "(.*)"', args[-1])[1]
        return () if state['missing'] and name == endpoints[1] else (name,)
    def paths(*args):
        names = ('S0', 'S1', 'S2') if '-setup' in args else ('H0', 'H1', 'H2')
        maximum = int(args[args.index('-max_paths') + 1])
        return names[:maximum]
    query.createcommand('get_pins', pins)
    query.createcommand('get_cells', lambda *args: 'primitive')
    query.createcommand('get_property', lambda key, obj: state['primitive'] if key == 'REF_NAME' else properties[(obj, key)])
    query.createcommand('get_timing_paths', paths)
    scratch = tempfile.TemporaryDirectory(prefix='rtlnet_policy_')
    query_dir = Path(scratch.name)
    evaluated = query.call('rtlnet_camera_timing::evaluate', 0.264, 0, query_dir.as_posix())
    assert float(query.call('dict', 'get', evaluated, 'wns')) == 0.260
    assert float(query.call('dict', 'get', evaluated, 'whs')) == 0.050
    for missing, primitive, limit in ((True, 'ISERDESE2', 1000000), (False, 'FDRE', 1000000), (False, 'ISERDESE2', 2)):
        state.update(missing=missing, primitive=primitive)
        query.setvar('::rtlnet_camera_timing::limit', limit)
        try:
            query.call('rtlnet_camera_timing::evaluate', 0.264, 0, query_dir.as_posix())
        except tkinter.TclError:
            pass
        else:
            raise AssertionError('Incomplete/wrong netlist evidence accepted')
    print('RTLNET_DPHY_QUERY_MOCK: PASS full endpoint enumeration; missing pin, changed primitive and truncation reject')

    report = board / 'testbench/fixtures/vendor_cdc_findings.txt'
    counts = {}
    cdc_fixtures = []
    assert report.is_file(), 'missing fixture ' + str(report)
    if True:
        for line in report.read_text(encoding='utf-8').splitlines():
            match = re.match(r'\s*\d+\s+(CDC-\d+)\s+(Critical|Warning)\s+.*?\s+\d+\s+False Path\s+(\S+)\s+(\S+)\s*$', line)
            if not match:
                continue
            ident, _, source, destination = match.groups()
            cdc_fixtures.append((ident, match[2], source, destination))
            assert str(tcl.call('rtlnet_camera_review::cdc_reason', ident, source, destination)) != '', line
            counts[ident] = counts.get(ident, 0) + 1
            rejected = tcl.call('rtlnet_camera_review::cdc_reason', ident, source, 'unrelated/D')
            assert str(rejected) == '', (ident, source, str(rejected))
        assert counts == {'CDC-7': 2, 'CDC-11': 2, 'CDC-15': 37, 'CDC-10': 3}, counts
    method = board / 'testbench/fixtures/vendor_methodology_findings.txt'
    method_fixtures = []
    assert method.is_file(), 'missing fixture ' + str(method)
    if True:
        blocks = re.split(r'(?=^[A-Z]+[A-Z0-9]*-\d+#\d+ Warning$)', method.read_text(encoding='utf-8'), flags=re.MULTILINE)[1:]
        assert len(blocks) == 8, len(blocks)
        for block in blocks:
            ident = block.split('#')[0]
            method_fixtures.append((ident, block))
            if ident == 'TIMING-9':
                continue  # apply() requires the full CDC inventory first.
            assert str(tcl.call('rtlnet_camera_review::method_reason', ident, block, 1)) != '', block
            assert str(tcl.call('rtlnet_camera_review::method_reason', ident, 'unrelated input/reset', 1)) == ''
            if ident == 'TIMING-15':
                assert str(tcl.call('rtlnet_camera_review::method_reason', ident, block, 0)) == ''
    print('RTLNET_VENDOR_REVIEW_TEST: PASS all 44 routed-design CDC findings and 7 scoped methodology fixtures; changed endpoints and deviation-off reject')
    # Execute the complete native-waiver orchestration with object-command mocks.
    # This checks Tcl/property/control flow, not real Vivado violation objects.
    tcl.eval('''
      array set fixture {}; set cdc_objects {}; set method_objects {}; set waived {}
      proc get_property {name object} {
        if {[info exists ::fixture($object,$name)]} {return $::fixture($object,$name)}
        return {}
      }
      proc report_cdc {args} {}
      proc report_methodology {args} {}
      proc get_cdc_violations {args} {return $::cdc_objects}
      proc get_methodology_violations {args} {return $::method_objects}
      proc get_cells {args} {return {}}
      proc get_pins {args} {return {}}
      proc get_ports {args} {return {}}
      proc create_waiver {args} {lappend ::waived [lindex $args 1]}
      proc write_waivers {args} {}
    ''')
    for n, (ident, severity, source, destination) in enumerate(cdc_fixtures):
        obj = f'cdc{n}'
        for key, value in [('CHECK', ident), ('SEVERITY', severity), ('STARTPOINT_PIN', source), ('ENDPOINT_PIN', destination)]:
            tcl.setvar(f'::fixture({obj},{key})', value)
        tcl.call('lappend', '::cdc_objects', obj)
    for n, (ident, block) in enumerate(method_fixtures):
        obj = f'method{n}'
        for key, value in [('CHECK', ident), ('SEVERITY', 'Warning'), ('DESCRIPTION', block)]:
            tcl.setvar(f'::fixture({obj},{key})', value)
        tcl.call('lappend', '::method_objects', obj)
    policy_dir = query_dir
    tcl.call('rtlnet_camera_review::apply', policy_dir.as_posix(), 1)
    assert int(tcl.eval('llength $waived')) == 52
    tcl.setvar('::fixture(cdc0,ENDPOINT_PIN)', 'unrelated/D')
    try:
        tcl.call('rtlnet_camera_review::apply', policy_dir.as_posix(), 1)
    except tkinter.TclError:
        pass
    else:
        raise AssertionError('Unreviewed native CDC object accepted')
    print('RTLNET_VENDOR_NATIVE_MOCK: PASS 52 individual waiver commands; unknown native crossing rejects')

    root = board / 'ip/digilent/vivado-library/ip/MIPI_D_PHY_RX'
    if not root.is_dir():
        print('RTLNET_DPHY_SOURCE_AUDIT: SKIPPED boards/zybo_z7_20/ip/digilent is absent (see the README, Third-party IP)')
        return
    lane = (root / 'hdl/DPHY_LaneSFEN.vhd').read_text(encoding='utf-8')
    for name in ('LD', 'CE', 'INC'):
        assert re.search(r'cIDLY_' + name + r"\s*=>\s*'0'", lane)
    assert re.search(r'cIDLY_CNT\s*=>\s*open', lane)
    receiver = (root / 'hdl/HS_Deserializer.vhd').read_text(encoding='utf-8')
    assert re.search(r'IDELAY_TYPE\s*=>\s*"VARIABLE"', receiver)
    assert 'constant kDelayTaps : natural := 12 + kAddDelayTaps;' in receiver
    assert 'dAlignment_int : natural range 0 to 7' in receiver
    axi = (root / 'hdl/S_AXI_Lite.vhd').read_text(encoding='utf-8')
    assert 'reg_data_out <= control_reg;' in axi and 'reg_data_out <= kVersion;' in axi
    assert not re.search(r'(train|tap)', (root / 'xgui/MIPI_D_PHY_RX_v1_3.tcl').read_text(encoding='utf-8'), re.I)
    print('RTLNET_DPHY_SOURCE_AUDIT: variable IDELAY capability 0..31; LD/CE/INC tied 0; CNT open; configured tap 12; no tap training generic; burst byte alignment 0..7; AXI readback control/version only')


if __name__ == '__main__':
    main()
