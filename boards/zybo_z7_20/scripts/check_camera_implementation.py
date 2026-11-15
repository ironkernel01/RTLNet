"""Purpose: check camera implementation choices and extract routed timing evidence.
Overview: execute Tcl helpers with command mocks; do not start Vivado or qualify timing.
Revision: 11-15-2026.
"""
from pathlib import Path
import re
import tempfile
import tkinter


def main():
    board = Path(__file__).resolve().parents[1]
    tcl = tkinter.Tcl()
    for path in list((board / 'scripts').glob('*.tcl')) + list((board / 'bd').glob('*.tcl')) + list((board / 'constraints').glob('*.xdc')):
        if not tcl.call('info', 'complete', path.read_text(encoding='utf-8')):
            raise AssertionError('Incomplete Tcl script: ' + str(path))
    tcl.eval('''
      set settings {}; set optimizations {}
      proc set_property {args} {lappend ::settings $args}
      proc phys_opt_design {args} {lappend ::optimizations $args}
    ''')
    tcl.call('source', (board / 'scripts/rtlnet_camera_implementation.tcl').as_posix())
    for mode, route, pre, post in (
        ('original', None, None, None),
        ('explore', 'Explore', 'Explore', 'ExploreWithHoldFix'),
        ('holdfix', 'AggressiveExplore', 'ExploreWithAggressiveHoldFix', 'ExploreWithAggressiveHoldFix'),
    ):
        tcl.eval('set settings {}; set optimizations {}')
        tcl.call('rtlnet_camera_impl::configure', 'impl_1', mode)
        tcl.call('rtlnet_camera_impl::post_route', mode)
        if mode == 'original':
            assert tcl.eval('llength $settings') == '0'
            assert tcl.eval('llength $optimizations') == '0'
        else:
            assert tcl.eval('llength $settings') == '4'
            assert tcl.eval('lindex $settings 0') == 'STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore impl_1'
            assert tcl.eval('lindex $settings 1') == 'STEPS.PHYS_OPT_DESIGN.IS_ENABLED true impl_1'
            assert tcl.eval('lindex $settings 2') == f'STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE {pre} impl_1'
            assert tcl.eval('lindex $settings 3') == f'STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE {route} impl_1'
            assert tcl.eval('lindex $optimizations 0') == f'-directive {post}'
    for command in ('rtlnet_camera_impl::configure impl_1 invalid',
                    'rtlnet_camera_impl::post_route invalid'):
        try:
            tcl.eval(command)
        except tkinter.TclError:
            pass
        else:
            raise AssertionError('Unknown implementation choice accepted')
    build = (board / 'scripts/build_bitstream.tcl').read_text(encoding='utf-8')
    assert build.index('rtlnet_camera_timing::evaluate') < build.index('set crit_impl_run [audit_run_critical_warnings impl_1]')
    assert '$::rtlnet_dphy_deviation && $id eq {Timing 38-282}' in build
    assert '$::rtlnet_dphy_deviation && $id eq {Route 35-39}' in build
    print('RTLNET_CAMERA_IMPL_CHECK: PASS Tcl completeness; implementation commands; invalid choices reject; deviation predicate precedes warning audit')
    audit = 'proc audit_run_critical_warnings' + build.split('proc audit_run_critical_warnings', 1)[1].split('\nforeach artifact', 1)[0]
    policy = tkinter.Tcl()
    policy.eval(audit)
    policy.eval('proc fail {code message} {error "$code $message"}')
    # Keep mocked build counters distinct from actual executed build evidence.
    policy.eval('rename puts real_puts; proc puts {args} {if {[llength $args] > 1} {real_puts {*}$args}}')
    scratch = tempfile.TemporaryDirectory(prefix='rtlnet_impl_')
    fixture = Path(scratch.name) / 'warning_policy'
    reports = fixture / 'reports'
    reports.mkdir(parents=True, exist_ok=True)
    policy.setvar('build', fixture.as_posix())
    policy.setvar('reports', reports.as_posix())
    timing = 'CRITICAL WARNING: [Timing 38-282] The design failed to meet the timing requirements. Please see the timing summary report for details on the timing violations.'
    route = 'CRITICAL WARNING: [Route 35-39] The design did not meet timing requirements. Please run report_timing_summary for detailed reports. Note: this situation might be resolved in the second pass of route design.'
    for run, deviation, lines, expected in (
        ('impl_1', 1, [timing, route], 0),
        ('parent', 1, [timing, route], 0),
        ('impl_1', 0, [timing, route], 2),
        ('synth_1', 1, [timing, route], 2),
        ('impl_1', 1, [route.replace('35-39', '35-40')], 1),
        ('impl_1', 1, [route.replace('The design did not meet timing requirements.', 'Different router condition.')], 1),
    ):
        log = fixture / 'build_bitstream.log' if run == 'parent' else fixture / f'project/rtlnet_camera.runs/{run}/runme.log'
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        policy.setvar('::rtlnet_dphy_deviation', deviation)
        assert int(policy.call('audit_run_critical_warnings', run)) == expected
    print('RTLNET_TIMING_SUMMARY_WAIVER_TEST: PASS Timing 38-282 and Route 35-39 only with the deviation in implementation/parent; changed IDs/messages and synthesis reject')
    utilization = tkinter.Tcl()
    utilization.eval('proc fail {code message} {error "$code $message"}; proc report_utilization {args} {return $::fixture_util}; proc puts {args} {}')
    gate = 'set util [report_utilization -return_string]' + build.split('set util [report_utilization -return_string]', 1)[1].split('set latches ', 1)[0]
    for used, pct, expected in ((45220, '85.00', True), (45221, '85.00', False), (45220, '85.01', False)):
        rows = [f'| Slice LUTs | {used} | 0 | 0 | 53200 | {pct} |',
                '| Slice Registers | 4429 | 0 | 0 | 106400 | 4.16 |',
                '| Block RAM Tile | 6.5 | 0 | 0 | 140 | 4.64 |',
                '| DSPs | 0 | 0 | 0 | 220 | 0.00 |']
        utilization.setvar('fixture_util', '\n'.join(rows))
        assert (int(utilization.call('catch', gate, 'failure')) == 0) == expected
    print('RTLNET_UTIL_GATE_TEST: PASS exact 45,220-LUT limit; 45,221 rejects even when percentage rounds to 85.00')


if __name__ == '__main__':
    main()
