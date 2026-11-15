"""Purpose: stage camera IP with one canonical DebugLib compilation unit.
Overview: preserve the licensed originals; union disjoint declarations in build output.
Revision: 11-14-2026.
"""
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys


def require_debug_off(bd_text):
    for cell in ('MIPI_CSI_2_RX_0', 'MIPI_D_PHY_RX_0'):
        blocks = re.findall(r'set_property -dict \[list \\\n([^]]*)\] \[get_bd_cells ' + cell + r'\]',
                            bd_text, re.DOTALL)
        if len(blocks) != 1 or re.findall(r'CONFIG\.kDebug\s+\{([^}]+)\}', blocks[0]) != ['false']:
            raise ValueError('XDC preparation requires explicit kDebug=false on ' + cell)


def prepare_xdc(root, manifest):
    evidence = []
    for relative, policy in manifest['files'].items():
        path = root / relative
        original = path.read_bytes()
        if hashlib.sha256(original).hexdigest() != policy['sha256']:
            raise ValueError('Unreviewed vendor XDC version: ' + relative)
        lines = original.splitlines(keepends=True)
        for item in policy['omit']:
            index = item['line'] - 1
            line = lines[index]
            text = line.rstrip(b'\r\n')
            if hashlib.sha256(text).hexdigest() != item['sha256']:
                raise ValueError('Unexpected ILA exception line: ' + relative + ':' + str(index + 1))
            if not text.startswith(b'set_false_path -from ') or b'allx_typeA_match_detection' not in text:
                raise ValueError('Manifest entry is not an ILA exception')
            ending = line[len(text):]
            lines[index] = b'# RTLNet: absent debug ILA exception omitted; see XDC manifest.' + ending
            evidence.append(f"omit {relative}:{index + 1} {item['sha256']} {item['reason']}")
        staged = b''.join(lines)
        path.write_bytes(staged)
        evidence.append(f"xdc {relative} input {policy['sha256']} output {hashlib.sha256(staged).hexdigest()}")
    return evidence


def prepare(build):
    board = Path(__file__).resolve().parents[1]
    build = build.resolve()
    build.relative_to((board / 'build').resolve())
    # The protocol reviews apply to exactly this pristine IP snapshot.
    pristine = board / 'ip/digilent'
    for line in (pristine / 'NOTICE.txt').read_text(encoding='utf-8').splitlines():
        if re.match(r'^[0-9a-f]{64}  ', line):
            digest, relative = line.split('  ', 1)
            if hashlib.sha256((pristine / relative).read_bytes()).hexdigest() != digest:
                raise ValueError('Unreviewed vendor source: ' + relative)
    require_debug_off((board / 'bd/rtlnet_camera.tcl').read_text(encoding='utf-8'))
    xdc_manifest = json.loads((board / 'scripts/rtlnet_camera_xdc_manifest.json').read_text(encoding='utf-8'))
    destination = build / 'ip_repo'
    # Re-copy the pristine inputs before each transformation so that a rerun starts from the originals.
    shutil.copytree(board / 'ip/digilent', destination, dirs_exist_ok=True)
    root = destination / 'vivado-library/ip'
    xdc_evidence = prepare_xdc(root, xdc_manifest)
    csi = root / 'MIPI_CSI_2_RX'
    dphy = root / 'MIPI_D_PHY_RX'
    sources = [p / 'hdl/DebugLib.vhd' for p in (csi, dphy)]
    texts = [p.read_text(encoding='utf-8') for p in sources]
    bodies = []
    names = set()
    for source in texts:
        match = re.fullmatch(r'(.*?package DebugLib is)(.*?)(end package;\s*)',
                             source, re.DOTALL)
        if not match:
            raise ValueError('Unexpected DebugLib package layout')
        body = match[2]
        declared = set(re.findall(r'^\s*(?:component|type|constant)\s+(\w+)',
                                  body, re.IGNORECASE | re.MULTILINE))
        folded = {n.lower() for n in declared}
        if names & folded:
            raise ValueError('DebugLib declarations overlap')
        names |= folded
        bodies.append(body)
    # Both original license headers remain in the canonical source.
    header = '\n'.join(t.split('package DebugLib is')[0] for t in texts)
    merged = header + '\npackage DebugLib is\n' + '\n'.join(bodies) + '\nend package;\n'
    (csi / 'hdl/rtlnet_camera_debuglib.vhd').write_text(merged, encoding='utf-8')
    metadata = csi / 'component.xml'
    metadata.write_text(metadata.read_text(encoding='utf-8').replace(
        'hdl/DebugLib.vhd', 'hdl/rtlnet_camera_debuglib.vhd'), encoding='utf-8')
    metadata = dphy / 'component.xml'
    xml, count = re.subn(
        r'<spirit:file>\s*<spirit:name>hdl/DebugLib\.vhd</spirit:name>.*?</spirit:file>',
        '', metadata.read_text(encoding='utf-8'), flags=re.DOTALL)
    if count != 2:
        raise ValueError('Expected synthesis and simulation DebugLib file entries')
    metadata.write_text(xml, encoding='utf-8')
    manifest = ['Purpose: canonical camera debug declarations; no logic changes.',
                'Revision: 11-14-2026.',
                'One compiled package: MIPI_CSI_2_RX/hdl/rtlnet_camera_debuglib.vhd.',
                'D-PHY file sets use the same work.DebugLib; original records and constants are exact.']
    manifest += [hashlib.sha256(p.read_bytes()).hexdigest() + ' ' +
                 p.relative_to(destination).as_posix() for p in sources]
    manifest.append(hashlib.sha256(merged.encode('utf-8')).hexdigest() + ' canonical UTF-8')
    manifest += xdc_evidence
    (build / 'camera_ip_preparation.txt').write_text('\n'.join(manifest) + '\n', encoding='utf-8')
    print('RTLNET_CAMERA_IP: PASS single DebugLib source; disjoint declarations preserved')
    print('RTLNET_CAMERA_XDC: PASS 4 exact ILA exceptions omitted; functional constraints preserved')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]))
