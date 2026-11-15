"""Purpose: exercise publication, coded failures and both stage preflights without Vivado.
Overview: isolated mock runs in a temporary folder; ZIP verification uses real Python stdlib.
Revision: 11-14-2026.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import tkinter
from zipfile import ZipFile


def check_tcl(board, root):
    source = (board / 'scripts/build_bitstream.tcl').read_text(encoding='utf-8')
    failure = source.split('set ::rtlnet_failure_code 99', 1)[0]
    tail = source.split('# Publication uses the same gated checkpoint for both stage values.', 1)[1].split('\nexit 0', 1)[0]
    cases = {'good': 0, 'run_failure': 40, 'missing_bit': 40, 'stale_bit': 40,
             'wrong_top': 40, 'hw_error': 41, 'wrong_bit': 42, 'missing_hwh': 42,
             'bad_zip': 42, 'critical': 24}
    for stage in ('camera', 'baseline'):
        for case, expected in cases.items():
            build = root / f'{stage}_{case}'
            build.mkdir(parents=True, exist_ok=True)
            checkpoint = build / 'post_route.dcp'
            checkpoint.write_bytes(b'MOCK gated checkpoint, not FPGA data')
            info = build / 'build_info.txt'
            info.write_text(f'stage {stage}\nwns_ns -0.223\nwhs_ns -1.431\n'
                            'qualified_wns_ns 0.272\nqualified_whs_ns 0.050\n'
                            'deviation_DPHY_HS_INPUT 1\n', encoding='utf-8')
            run_dir = build / 'project/rtlnet_camera.runs/impl_1'
            run_dir.mkdir(parents=True, exist_ok=True)
            native_bit = run_dir / 'rtlnet_camera_wrapper.bit'
            if native_bit.exists():
                native_bit.unlink()
            tcl = tkinter.Tcl()
            tcl.eval(failure)
            tcl.eval('proc exit {code} {return -code error -errorcode [list MOCK_EXIT $code] "MOCK_EXIT $code"}')
            tcl.call('source', (board / 'scripts/rtlnet_camera_export.tcl').as_posix())
            for name, value in [('board', board.as_posix()), ('build', build.as_posix()),
                                ('opt(stage)', stage), ('opt(python)', sys.executable),
                                ('::rtlnet_dphy_deviation', 1), ('::rtlnet_failure_code', 99)]:
                tcl.setvar(name, value)
            settings = {}
            events = []
            output = []
            tcl.eval('rename puts real_puts')
            def puts(*args):
                if len(args) == 1:
                    output.append(str(args[0]))
                else:
                    return tcl.call('real_puts', *args)
                return ''
            tcl.createcommand('puts', puts)
            tcl.createcommand('get_runs', lambda *args: 'impl_1')
            tcl.createcommand('get_filesets', lambda *args: 'sources_1')
            def prop(key, obj):
                return {'TOP': 'wrong_top' if obj == 'design' and case == 'wrong_top' else 'rtlnet_camera_wrapper', 'DIRECTORY': run_dir.as_posix(),
                        'STATUS': 'write_bitstream Failed' if case == 'run_failure' else 'write_bitstream Complete!',
                        'PROGRESS': '50%' if case == 'run_failure' else '100%',
                        'NAME': 'post_route_checkpoint_design'}[key]
            tcl.createcommand('get_property', prop)
            tcl.createcommand('set_property', lambda key, val, obj: settings.update({key: val}) or '')
            tcl.createcommand('close_design', lambda: events.append('close') or '')
            def open_checkpoint(path):
                assert Path(path).read_bytes() == checkpoint.read_bytes()
                events.append('gated_checkpoint')
                return ''
            tcl.createcommand('open_checkpoint', open_checkpoint)
            tcl.createcommand('current_design', lambda *args: 'design')
            def launch(*args):
                assert args == ('impl_1', '-to_step', 'write_bitstream', '-jobs', '2')
                tcl.call('source', settings['STEPS.WRITE_BITSTREAM.TCL.PRE'])
                if case != 'missing_bit':
                    native_bit.write_bytes(b'MOCK bitstream: same gated design')
                    if case == 'stale_bit':
                        old = checkpoint.stat().st_mtime - 10
                        os.utime(native_bit, (old, old))
                events.append('run_bit')
                return ''
            tcl.createcommand('launch_runs', launch)
            tcl.createcommand('wait_on_run', lambda run: '')
            tcl.createcommand('current_run', lambda *args: events.append('select_impl') or '')
            def hw(*args):
                assert '-include_bit' in args and events.index('gated_checkpoint') < events.index('run_bit')
                if case == 'hw_error':
                    return tcl.eval('error {Unable to get BIT file from implementation run}')
                xsa = Path(args[args.index('-file') + 1])
                if case == 'bad_zip':
                    xsa.write_bytes(b'not a ZIP')
                else:
                    with ZipFile(xsa, 'w') as archive:
                        data = native_bit.read_bytes()
                        archive.writestr('rtlnet_camera_wrapper.bit', data + (b'bad' if case == 'wrong_bit' else b''))
                        if case != 'missing_hwh':
                            archive.writestr('rtlnet_camera.hwh', '<MOCK_HARDWARE/>')
                events.append('xsa')
                return ''
            tcl.createcommand('write_hw_platform', hw)
            tcl.createcommand('audit_run_critical_warnings', lambda run: 1 if case == 'critical' else 0)
            result = int(tcl.call('catch', tail, 'caught'))
            if result:
                code = int(tcl.getvar('::rtlnet_failure_code'))
                try:
                    tcl.call('fail', code, tcl.getvar('caught'))
                except tkinter.TclError:
                    pass
                assert code == expected, (stage, case, code, tcl.getvar('caught'))
                assert f'rtlnet_build: FAIL ({expected})' in output[-1]
                assert not (build / 'rtlnet_zybo_z7_20.bit').exists()
                assert not (build / 'rtlnet_zybo_z7_20.xsa').exists()
                assert 'gate_pass 1' not in info.read_text(encoding='utf-8')
                assert not any(line.startswith('rtlnet_build: PASS') for line in output)
            else:
                assert expected == 0, (stage, case)
                metadata = info.read_text(encoding='utf-8')
                assert 'gate_pass 1' in metadata and 'export_verified 1' in metadata
                assert 'qualified_wns_ns 0.272' in metadata and 'deviation_DPHY_HS_INPUT 1' in metadata
                assert output[-1] == 'rtlnet_build: PASS with deviation DPHY_HS_INPUT (2 endpoints, reference configuration; hardware verification open)'
    print('RTLNET_EXPORT_FLOW_MOCK: PASS both stages; gated checkpoint, run-owned bit, embedded-byte verification, final verdict and coded cleanup failures')
    print('RTLNET_CHECKPOINT_TOP_MOCK: PASS checkpoint design NAME differs from module TOP; matching TOP accepts and wrong TOP rejects')


def check_ps(board, root):
    script = (board / 'scripts/build.ps1').read_text(encoding='utf-8')
    fixture = root / 'powershell/repo'
    port = fixture / 'boards/zybo_z7_20'
    (fixture / 'scripts').mkdir(parents=True, exist_ok=True)
    (port / 'scripts').mkdir(parents=True, exist_ok=True)
    (port / 'scripts/build.ps1').write_text(script, encoding='utf-8')
    (port / 'ip/digilent').mkdir(parents=True, exist_ok=True)
    (port / 'ip/digilent/NOTICE.txt').write_text('mock\n', encoding='utf-8')
    (port / 'board_files/zybo-z7-20/A.0').mkdir(parents=True, exist_ok=True)
    (port / 'board_files/zybo-z7-20/A.0/board.xml').write_text('mock\n', encoding='utf-8')
    # sys.executable comes from the real central resolver running this test.
    python = sys.executable.replace("'", "''")
    (fixture / 'scripts/rtlnet_tools.ps1').write_text(
        "function Resolve-RtlnetXilinx { return 'MOCK' }\n"
        f"function Resolve-RtlnetPython {{ return '{python}' }}\n", encoding='utf-8')
    (port / 'scripts/rtlnet_prepare_camera_ip.py').write_text("print('MOCK IP preparation')\n", encoding='utf-8')
    (port / 'scripts/check_baseline_sources.py').write_text("import os, sys\nprint('MOCK source closure preflight')\nsys.exit(1 if os.environ.get('RTLNET_EXPORT_MOCK') == 'source_error' else 0)\n", encoding='utf-8')
    (fixture / 'scripts/rtlnet_vivado.ps1').write_text(r'''
param($MaxSlots,$Tcl,$Log,$TclArgs)
$b=Split-Path -Parent $Log
[IO.File]::WriteAllText((Join-Path $b 'launched.txt'),'mock launcher')
if($env:RTLNET_EXPORT_MOCK -eq 'launcher_error'){throw 'mock launcher error'}
if($env:RTLNET_EXPORT_MOCK -eq 'run_error'){exit 41}
$stage=if($TclArgs -match 'stage,baseline,'){'baseline'}else{'camera'}
foreach($name in 'rtlnet_zybo_z7_20.bit','rtlnet_zybo_z7_20.xsa','export_manifest.txt'){
 if($env:RTLNET_EXPORT_MOCK -ne 'missing_bit' -or $name -ne 'rtlnet_zybo_z7_20.bit'){
  [IO.File]::WriteAllText((Join-Path $b $name),'MOCK artifact')
 }
}
$nl=[Environment]::NewLine
$marker=if($env:RTLNET_EXPORT_MOCK -eq 'missing_marker'){''}else{"gate_pass 1$nl"}
[IO.File]::WriteAllText((Join-Path $b 'build_info.txt'),"stage $stage$nl$marker")
exit 0
''', encoding='utf-8')
    camera = port / 'build/prerequisite'
    camera.mkdir(parents=True, exist_ok=True)
    for stage in ('camera', 'baseline'):
        cases = [('good', 0), ('launcher_error', 1), ('run_error', 41), ('missing_bit', 44), ('missing_marker', 44)]
        if stage == 'baseline':
            cases.append(('source_error', 1))
        for case, expected in cases:
            camera.joinpath('build_info.txt').unlink(missing_ok=True)
            if stage == 'baseline':
                camera.joinpath('build_info.txt').write_text('stage camera\npart xc7z020clg400-1\ngate_pass 1\n', encoding='utf-8')
                # Deliberately no prerequisite .bit/.xsa/.dcp: Baseline rebuilds.
                assert list(camera.iterdir()) == [camera / 'build_info.txt']
            tag = stage + '_' + case
            output_dir = port / 'build' / tag
            if output_dir.exists():
                for name in ('rtlnet_zybo_z7_20.bit', 'rtlnet_zybo_z7_20.xsa', 'export_manifest.txt', 'build_info.txt', 'launched.txt'):
                    output_dir.joinpath(name).unlink(missing_ok=True)
            command = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(port / 'scripts/build.ps1'),
                       '-Stage', stage, '-CameraTag', 'prerequisite', '-Tag', tag, '-HighProfile', 'none']
            environment = os.environ.copy()
            environment['RTLNET_EXPORT_MOCK'] = case
            completed = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=30)
            assert completed.returncode == expected, (stage, case, completed.stdout, completed.stderr)
            verdict = f'RTLNET_BUILD: PASS stage {stage} tag {tag}' if expected == 0 else f'RTLNET_BUILD: FAIL ({expected}) stage {stage} tag {tag}'
            assert verdict in completed.stdout, (case, completed.stdout, completed.stderr)
            if expected:
                assert not output_dir.joinpath('rtlnet_zybo_z7_20.bit').exists()
                assert not output_dir.joinpath('rtlnet_zybo_z7_20.xsa').exists()
            if case == 'source_error':
                assert not output_dir.joinpath('launched.txt').exists()
            if stage == 'baseline':
                assert 'gate_pass 1' in camera.joinpath('build_info.txt').read_text(encoding='utf-8')
    camera.joinpath('build_info.txt').unlink()
    for name in ('no_camera', 'wrong_stage'):
        if name == 'wrong_stage':
            camera.joinpath('build_info.txt').write_text('stage baseline\npart xc7z020clg400-1\ngate_pass 1\n', encoding='utf-8')
        completed = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(port / 'scripts/build.ps1'),
                                    '-Stage', 'baseline', '-CameraTag', 'prerequisite', '-Tag', name], capture_output=True, text=True, timeout=30)
        assert completed.returncode == 1 and 'RTLNET_BUILD: FAIL (1)' in completed.stdout
        assert not (port / 'build' / name / 'launched.txt').exists()
    # Without the third-party folders the build stops before Vivado and names the import script.
    (port / 'ip/digilent/NOTICE.txt').unlink()
    completed = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(port / 'scripts/build.ps1'),
                                '-Stage', 'camera', '-Tag', 'no_third_party'], capture_output=True, text=True, timeout=30)
    assert completed.returncode == 1 and 'rtlnet_import_camera.py' in completed.stdout, completed.stdout
    assert not (port / 'build/no_third_party/launched.txt').exists()
    (port / 'ip/digilent/NOTICE.txt').write_text('mock\n', encoding='utf-8')
    print('RTLNET_THIRD_PARTY_GUARD: PASS missing Digilent files stop the build before Vivado with the import command')
    print('RTLNET_STAGE_PREFLIGHT_MOCK: PASS both PowerShell verdicts; missing exports/marker and launcher errors reject; Baseline consumes only camera stage/part/gate metadata')
    print('RTLNET_SOURCE_PREFLIGHT_ORDER: PASS source-check failure stops Baseline before Vivado launcher')


def main():
    board = Path(__file__).resolve().parents[1]
    scratch = tempfile.TemporaryDirectory(prefix='rtlnet_export_')
    root = Path(scratch.name)
    # Execute the real manifest generator and project registration helper.
    completed = subprocess.run([sys.executable, '-I', str(board / 'scripts/check_baseline_sources.py'),
                                '--manifest', str(root / 'baseline_sources.tcl')], capture_output=True, text=True)
    assert completed.returncode == 0, completed.stderr
    tcl = tkinter.Tcl()
    tcl.eval('set ::rtlnet_hp 0; set sources {}; set settings {}; set ordered 0')
    tcl.eval('proc current_project {} {return project}; proc get_filesets {args} {return sources_1}; proc get_files {path} {return $path}; proc set_property {args} {lappend ::settings $args}; proc add_files {args} {foreach f [lindex $args end] {lappend ::sources $f}}; proc update_compile_order {args} {set ::ordered 1}')
    tcl.call('source', (board / 'scripts/rtlnet_add_baseline_sources.tcl').as_posix())
    tcl.call('rtlnet_add_baseline_sources', board.parents[1].as_posix(), root.as_posix())
    tcl.eval('source ' + (root / 'baseline_sources.tcl').as_posix())
    expected = int(tcl.eval('expr {[llength $::rtlnet_project_headers] + [llength $::rtlnet_project_sources]}'))
    assert int(tcl.eval('llength $sources')) == expected > 50
    assert tcl.eval('file tail [lindex $sources 0]') == 'rtlnet_technology.svh'
    assert tcl.eval('set ::ordered') == '1'
    settings = tcl.eval('set settings')
    assert 'IS_GLOBAL_INCLUDE true' in settings and '{Verilog Header}' in settings
    assert 'verilog_define RTLNET_TECH_AMD' in settings and 'XPM_MEMORY XPM_CDC' in settings
    assert 'FILE_TYPE Verilog' in settings and 'FILE_TYPE SystemVerilog' in settings
    for relative in ('scripts/rtlnet_constrain_cdc.tcl', 'boards/zybo_z7_20/scripts/rtlnet_cdc_hook.tcl',
                     'cpu/zynq7_h264/firmware/build.ps1', 'cpu/zynq7_h264/firmware/src/rtlnet_make_bsp.py',
                     'cpu/zynq7_h264/firmware/src/rtlnet_linker.ld', 'cpu/zynq7_h264/firmware/src/rtlnet_stage_sdk.py'):
        assert (board.parents[1] / relative).is_file(), relative
    print('RTLNET_BASELINE_INPUTS: PASS recursive RTL file lists and CDC hooks exist; HighProfile none needs no private delivery')
    check_tcl(board, root)
    check_ps(board, root)


if __name__ == '__main__':
    main()
