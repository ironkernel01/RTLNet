"""Purpose: verify that an XSA contains the exact bitstream produced for its gated DCP.
Overview: read-only ZIP/CRC/content checks; write provenance only after complete validation.
Revision: 11-14-2026.
"""
import hashlib
from pathlib import Path
import sys
from zipfile import ZipFile


def verify(bit, xsa, checkpoint, manifest):
    for path in (bit, xsa, checkpoint):
        if not path.is_file() or not path.stat().st_size:
            raise ValueError('Missing or empty export input: ' + str(path))
    data = bit.read_bytes()
    with ZipFile(xsa) as archive:
        if archive.testzip() is not None:
            raise ValueError('XSA CRC check fails')
        names = archive.namelist()
        bits = [name for name in names if name.lower().endswith('.bit')]
        if len(bits) != 1:
            raise ValueError('XSA must contain exactly one bitstream')
        if not any(name.lower().endswith('.hwh') for name in names):
            raise ValueError('XSA hardware handoff is absent')
        if archive.read(bits[0]) != data:
            raise ValueError('XSA bitstream differs from the run-generated bitstream')
    lines = [f'bitstream_sha256 {hashlib.sha256(data).hexdigest()}',
             f'xsa_sha256 {hashlib.sha256(xsa.read_bytes()).hexdigest()}',
             f'gated_checkpoint_sha256 {hashlib.sha256(checkpoint.read_bytes()).hexdigest()}',
             f'xsa_bitstream_entry {bits[0]}', 'export_verified 1']
    manifest.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('RTLNET_EXPORT_ARTIFACTS: PASS XSA contains the exact run-generated bitstream and hardware handoff')


if __name__ == '__main__':
    verify(*(Path(arg) for arg in sys.argv[1:]))
