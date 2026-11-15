"""Purpose: exercise the deviation gate and the reviewed-waiver policy of the build without Vivado.
Overview: exact-endpoint fixtures and negative controls for the timing gate (rtlnet_camera_timing_gate.tcl) and the reviewed CDC
  waivers (rtlnet_review_waivers.tcl) with object-command mocks; the source audit is not hardware proof.
Revision: 11-15-2026.
"""
from pathlib import Path
import re
import tempfile
import tkinter

ENDPOINTS = ('rtlnet_camera_i/u_video/inst/u_rtl/u_rx/g_cam.u_dphy/u_lane0/u_iser/ISERDESE2_inst/DDLY',
             'rtlnet_camera_i/u_video/inst/u_rtl/u_rx/g_cam.u_dphy/u_lane1/u_iser/ISERDESE2_inst/DDLY')


def main():
    board = Path(__file__).resolve().parents[1]
    gate = (board / 'scripts/rtlnet_camera_timing_gate.tcl').as_posix()
    tcl = tkinter.Tcl()
    tcl.call('source', gate)
    tcl.setvar('::rtlnet_camera_timing::endpoints', ' '.join('{' + e + '}' for e in ENDPOINTS))
    tcl.eval('set ::rtlnet_camera_timing::endpoints [list ' + ' '.join('{' + e + '}' for e in ENDPOINTS) + ']')
    endpoints = tcl.splitlist(tcl.eval('set ::rtlnet_camera_timing::endpoints'))
    assert len(endpoints) == 2
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

    # Netlist-query orchestration (endpoint discovery and per-endpoint path enumeration) with a complete endpoint model.
    query = tkinter.Tcl()
    query.call('source', gate)
    properties = {
        ('S0', 'ENDPOINT_PIN'): ENDPOINTS[1], ('S0', 'SLACK'): '-0.223',
        ('S1', 'ENDPOINT_PIN'): ENDPOINTS[0], ('S1', 'SLACK'): '-0.184',
        ('S2', 'ENDPOINT_PIN'): 'fabric/D', ('S2', 'SLACK'): '0.260',
        ('H0', 'ENDPOINT_PIN'): ENDPOINTS[0], ('H0', 'SLACK'): '-1.431',
        ('H1', 'ENDPOINT_PIN'): ENDPOINTS[1], ('H1', 'SLACK'): '-1.388',
        ('H2', 'ENDPOINT_PIN'): 'fabric/D', ('H2', 'SLACK'): '0.050',
    }
    state = {'ddly': ENDPOINTS}
    def paths(*args):
        names = ('S0', 'S1', 'S2') if '-setup' in args else ('H0', 'H1', 'H2')
        maximum = int(args[args.index('-max_paths') + 1])
        return names[:maximum]
    query.createcommand('get_cells', lambda *args: 'iserdes0 iserdes1')
    query.createcommand('get_pins', lambda *args: ' '.join('{' + e + '}' for e in state['ddly']))
    query.createcommand('get_property', lambda key, obj: obj if key == 'NAME' else properties[(obj, key)])
    query.createcommand('get_timing_paths', paths)
    scratch = tempfile.TemporaryDirectory(prefix='rtlnet_policy_')
    query_dir = Path(scratch.name)
    evaluated = query.call('rtlnet_camera_timing::evaluate', 0.264, 0, query_dir.as_posix())
    assert float(query.call('dict', 'get', evaluated, 'wns')) == 0.260
    assert float(query.call('dict', 'get', evaluated, 'whs')) == 0.050
    assert str(query.call('dict', 'get', evaluated, 'deviation')) == '1'
    for ddly, limit in ((ENDPOINTS[:1], 1000000), (ENDPOINTS + ('extra/DDLY',), 1000000), (ENDPOINTS, 2)):
        state['ddly'] = ddly
        query.setvar('::rtlnet_camera_timing::limit', limit)
        try:
            query.call('rtlnet_camera_timing::evaluate', 0.264, 0, query_dir.as_posix())
        except tkinter.TclError:
            pass
        else:
            raise AssertionError('Incomplete/wrong netlist evidence accepted')
    print('RTLNET_DPHY_QUERY_MOCK: PASS endpoint discovery and full path enumeration; a missing or extra DDLY pin and truncation reject')

    # Reviewed waivers: the full list is created for unique pins; an ambiguous or missing pin, an unreviewed methodology finding and a
    # grown inventory fail closed.
    review = tkinter.Tcl()
    review.call('source', (board / 'scripts/rtlnet_review_waivers.tcl').as_posix())
    review.eval('''
      set ::waived {}; set ::pin_count 1; set ::method_objects {}; array set fixture {}
      proc get_pins {args} {
        set name [regsub {^NAME == "(.*)"$} [lindex $args end] {\\1}]
        return [lrepeat $::pin_count $name]
      }
      proc create_waiver {args} {lappend ::waived $args}
      proc report_methodology {args} {}
      proc get_methodology_violations {args} {return $::method_objects}
      proc get_property {name object} {
        if {[info exists ::fixture($object,$name)]} {return $::fixture($object,$name)}
        return {}
      }
      proc get_cells {args} {return {}}
      proc get_pins_of {args} {return {}}
      proc get_ports {args} {return {}}
      proc puts {args} {}
    ''')
    review.call('rtlnet_review::apply', query_dir.as_posix(), 1)
    assert int(review.eval('llength $::waived')) == 12, review.eval('llength $::waived')
    review.setvar('::pin_count', 2)
    try:
        review.call('rtlnet_review::apply', query_dir.as_posix(), 1)
    except tkinter.TclError:
        pass
    else:
        raise AssertionError('Ambiguous CDC pin accepted')
    review.setvar('::pin_count', 1)
    review.setvar('::method_objects', 'vio0')
    for key, value in (('SEVERITY', 'Warning'), ('CHECK', 'LUTAR-1'), ('DESCRIPTION', 'unrelated net')):
        review.setvar(f'::fixture(vio0,{key})', value)
    try:
        review.call('rtlnet_review::apply', query_dir.as_posix(), 1)
    except tkinter.TclError:
        pass
    else:
        raise AssertionError('Unreviewed methodology finding accepted')
    print('RTLNET_REVIEW_WAIVER_TEST: PASS 12 reviewed CDC waivers for unique pins; ambiguous pin and unreviewed methodology finding reject')


if __name__ == '__main__':
    main()
