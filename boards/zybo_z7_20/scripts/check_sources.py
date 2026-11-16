"""Purpose: derive and audit the project source closure of the Zybo Z7-20 design before Vivado.
Overview: recursive repository filelists, include registration, package order and
module dependencies; generated Tcl is the project source-of-truth, not a second list.
The generated plain-Verilog module-reference boundary must equal the output of rtlnet_generate_video_wrapper.py.
This bounded lexical audit supplements the Active-HDL elaboration bench.
Usage: python check_sources.py [--manifest <file>]
Revision: 11-15-2026.
"""
import argparse
from pathlib import Path
import re
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from rtlnet_generate_video_wrapper import check as check_wrapper

# Root filelist, the Tcl recipe that creates the module reference, and the expected module-reference top.
ROOT_LIST = 'boards/zybo_z7_20/hdl/rtlnet_zybo_video.f'
RECIPE = 'rtlnet_zybo.tcl'
EXPECTED_TOP = 'rtlnet_zybo_video_bd'
# Exact external definitions provided by Vivado project XPM_LIBRARIES and
# the device's UNISIM library. Other unknown modules fail the check.
LIBRARY_MODULES = {'xpm_memory_sdpram': 'XPM_MEMORY', 'SRLC32E': 'UNISIM', 'IBUFDS': 'UNISIM', 'BUFIO': 'UNISIM', 'BUFR': 'UNISIM',
                   'IDELAYE2': 'UNISIM', 'IDELAYCTRL': 'UNISIM', 'ISERDESE2': 'UNISIM'}
KEYWORDS = set(('module endmodule package endpackage function endfunction task endtask '
                'automatic static input output inout wire logic reg bit int integer '
                'longint shortint byte string signed unsigned localparam parameter '
                'if else for foreach while repeat case casex casez begin end generate '
                'endgenerate return assign assert initial always always_ff always_comb '
                'always_latch typedef struct enum union void import export endcase '
                'endfunction endtask endproperty endsequence property sequence '
                'unique priority do forever disable wait fork join join_any join_none').split())


def uncomment(text):
    return re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"',
                  lambda m: m[0] if m[0].startswith('"') else ' ', text, flags=re.S)


def filelists(repo, relative=ROOT_LIST):
    sources, incdirs, defines, lists = [], [], [], []
    active = set()
    def add(path):
        if path in active:
            raise ValueError('Recursive filelist: ' + path)
        if path in lists:
            return
        active.add(path)
        for raw in (repo / path).read_text(encoding='utf-8').splitlines():
            line = re.split(r'#|//', raw, maxsplit=1)[0].strip()
            if not line:
                continue
            if line.startswith('-f '):
                add(line[3:].strip())
            elif line.startswith('+incdir+'):
                for directory in line[8:].split('+'):
                    if not (repo / directory).is_dir():
                        raise ValueError('Missing include directory: ' + directory)
                    if directory not in incdirs:
                        incdirs.append(directory)
            elif line.startswith('+define+'):
                defines.extend(d for d in line[8:].split('+') if d not in defines)
            elif line.startswith(('-', '+')):
                raise ValueError('Unsupported filelist directive: ' + line)
            else:
                if not (repo / line).is_file():
                    raise ValueError('Missing source: ' + line)
                if line not in sources:
                    sources.append(line)
        active.remove(path)
        lists.append(path)
    add(relative)
    return sources, incdirs, defines, lists


def closure(repo, sources, incdirs):
    headers, active = [], set()
    def visit(relative):
        if relative in active:
            return  # Include guards permit recursive includes; compiler checks them.
        active.add(relative)
        text = uncomment((repo / relative).read_text(encoding='utf-8'))
        for name in re.findall(r'`include\s+"([^"\n]+)"', text):
            candidates = [(repo / relative).parent / name] + [repo / d / name for d in incdirs]
            found = next((p for p in candidates if p.is_file()), None)
            if found is None:
                raise ValueError(f'Missing include {name} from {relative}')
            header = found.resolve().relative_to(repo.resolve()).as_posix()
            if header not in headers:
                headers.append(header)
                visit(header)
        active.remove(relative)
    for source in sources:
        visit(source)
    return headers


def references(text):
    # Strings/comments are opaque; balanced #(...) handles nested expressions
    # and named parameter overrides, unlike a one-line instantiation regex.
    tokens = re.findall(r'[A-Za-z_$][\w$]*|[^\s]', re.sub(r'"(?:\\.|[^"\\])*"', '""', uncomment(text)))
    found = set()
    for i, kind in enumerate(tokens[:-2]):
        if not re.fullmatch(r'[A-Za-z_]\w*', kind) or kind in KEYWORDS:
            continue
        if i and tokens[i-1] in ('.', ':', 'function', 'task'):
            continue
        j = i + 1
        if tokens[j] == '#':
            j += 1
            if tokens[j] != '(':
                raise ValueError('Unsupported parameter syntax near ' + kind)
            depth = 1
            j += 1
            while depth and j < len(tokens):
                depth += (tokens[j] == '(') - (tokens[j] == ')')
                j += 1
        if j < len(tokens) and re.fullmatch(r'[A-Za-z_]\w*', tokens[j]):
            j += 1
            while j < len(tokens) and tokens[j] == '[':
                while j < len(tokens) and tokens[j] != ']':
                    j += 1
                j += 1
            if j < len(tokens) and tokens[j] == '(':
                found.add(kind)
    return found


def audit(repo, sources, headers, incdirs):
    project = set(sources + headers)
    needed = set(closure(repo, sources, incdirs))
    if not needed <= project:
        raise ValueError('Includes absent from project: ' + ', '.join(sorted(needed - project)))
    modules, packages, texts = {}, {}, {}
    for index, source in enumerate(sources):
        text = uncomment((repo / source).read_text(encoding='utf-8'))
        texts[source] = text
        for name in re.findall(r'\bmodule\s+(\w+)', text):
            if name in modules:
                raise ValueError('Duplicate module: ' + name)
            modules[name] = source
        for name in re.findall(r'\bpackage\s+(\w+)\s*;', text):
            if name in packages:
                raise ValueError('Duplicate package: ' + name)
            packages[name] = index
    used_libs = set()
    for index, (source, text) in enumerate(texts.items()):
        for package in set(re.findall(r'\b(\w+)\s*::', text)):
            if package not in packages or packages[package] > index:
                raise ValueError(f'Missing or late package {package} used in {source}')
        for module in references(text):
            if module in LIBRARY_MODULES:
                used_libs.add(module)
            elif module not in modules:
                raise ValueError(f'Missing module {module} referenced in {source}')
    return modules, packages, used_libs


def tcl_list(values):
    # All paths originate in repository filelists; reject Tcl metacharacters.
    for value in values:
        if re.search(r'[{}\n\r\\$\[\];]', value):
            raise ValueError('Unsafe manifest value: ' + value)
    return '[list ' + ' '.join('{' + v + '}' for v in values) + ']'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', type=Path)
    args = parser.parse_args()
    root_list, recipe, expected_top = ROOT_LIST, RECIPE, EXPECTED_TOP
    board = Path(__file__).resolve().parents[1]
    repo = board.parents[1]
    check_wrapper(board)
    sources, incdirs, defines, lists = filelists(repo, root_list)
    # AMD technology is explicit for synthesis. No generic simulation substitute
    # replaces the production RAM/shift-register wrappers or their XPM/UNISIMs.
    if any(d.split('=')[0] in {'RTLNET_TECH_GENERIC', 'RTLNET_TECH_ALTERA', 'RTLNET_TECH_LATTICE'} for d in defines):
        raise ValueError('Synthesis filelist selects a non-AMD technology')
    if 'RTLNET_TECH_AMD' not in defines:
        defines.append('RTLNET_TECH_AMD')
    headers = closure(repo, sources, incdirs)
    modules, packages, libs = audit(repo, sources, headers, incdirs)
    bd = (board / 'bd' / recipe).read_text(encoding='utf-8')
    tops = re.findall(r'create_bd_cell\s+-type\s+module\s+-reference\s+(\w+)', bd)
    all_refs = []
    for path in sorted((board / 'bd').glob('*.tcl')):
        all_refs.extend(re.findall(r'create_bd_cell\s+-type\s+module\s+-reference\s+(\w+)', path.read_text(encoding='utf-8')))
    if all_refs != tops:
        raise ValueError('Additional module references require a boundary review')
    if tops != [expected_top]:
        raise ValueError('Module-reference inventory changes: review every boundary')
    for top in tops:
        path = modules.get(top, '')
        if not path.endswith('.v'):
            raise ValueError('Module reference must use a plain Verilog boundary: ' + top)
        header = uncomment((repo / path).read_text(encoding='utf-8')).split('\n);', 1)[0]
        header = re.sub(r'"(?:\\.|[^"\\])*"', '""', header)
        if re.search(r'\b(logic|interface|struct|typedef|import|bit|int)\b|::', header):
            raise ValueError('SystemVerilog type/package on module-reference boundary: ' + top)
    print('RTLNET_MODULE_REFS: PASS one plain Verilog top; simple parameters and scalar/vector wire ports; generated connections match SV implementation')
    print(f'RTLNET_SOURCES: PASS {len(sources)} RTL files, {len(headers)} headers, {len(packages)} packages, {len(modules)} modules; transitive includes/packages/modules resolved')
    print('RTLNET_LIBRARIES: ' + ', '.join(f'{m}={LIBRARY_MODULES[m]}' for m in sorted(libs)))
    # Negative controls exercise omission and ordering checks on the real list.
    for label, test_sources, test_headers in (
        ('header', sources, []),
        ('package', [s for s in sources if not s.endswith('/rtlnet_h264_pkg.sv')], headers),
        ('module', [s for s in sources if not s.endswith('/rtlnet_vdma_s2mm.sv')], headers),
        ('package order', list(reversed(sources)), headers)):
        try:
            audit(repo, test_sources, test_headers, incdirs)
        except ValueError:
            pass
        else:
            raise ValueError('Omission control does not fail: ' + label)
    print('RTLNET_SOURCES_NEG: PASS missing header/package/module and late package reject')
    if args.manifest:
        # Main build passes its own tag-local path; no other output is written.
        args.manifest.write_text('# Generated by check_sources.py; Revision: 11-15-2026.\n' +
            '\n'.join(f'set ::rtlnet_project_{key} {tcl_list(values)}' for key, values in
                      [('sources', sources), ('headers', headers), ('incdirs', incdirs), ('defines', defines), ('filelists', lists)]) + '\n', encoding='utf-8')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as exc:
        print('RTLNET_SOURCES: FAIL ' + str(exc), file=sys.stderr)
        sys.exit(1)
