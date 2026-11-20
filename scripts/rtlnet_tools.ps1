<#
-------------------------------------------------------------------------------
File: rtlnet_tools.ps1
Purpose: locate the external tools of the RTLNet scripts (AMD Vivado/Vitis
  install, Aldec Active-HDL, iperf 2) on whatever machine the checkout is on;
  no script holds an absolute tool path.
Overview:
  * Dot-source it, then call the resolver(s) the script needs:
      . (Join-Path <repo>/scripts 'rtlnet_tools.ps1')
      $x = Resolve-RtlnetXilinx    # throws when no install is found
  * Resolve-RtlnetXilinx -> object Root, Vivado, Vitis, MbBin, RvBin, Version
    (forward slashes). Search order, first hit wins:
      1. $env:RTLNET_XILINX (install root, e.g. <drive>/AMDDesignTools/2026.1)
      2. $env:XILINX_VIVADO (set by the install's settings64 script)
      3. vivado.bat on PATH
      4. <every fixed drive>/AMDDesignTools/<release> and /Xilinx/<release>,
         highest release that holds Vivado/bin/vivado.bat
  * Resolve-RtlnetAldec -> Active-HDL BIN directory: $env:RTLNET_ALDEC (BIN
    or install root), vsimsa.exe on PATH, <drive>/Aldec/Active-HDL*/BIN
    (highest version).
  * Resolve-RtlnetPython -> python.exe: $env:RTLNET_PYTHON, python on PATH
    (not the Store alias), the py launcher, Python3* folders under
    %LOCALAPPDATA%/Programs/Python, Program Files and drive roots.
  * Resolve-RtlnetHostCc -> host gcc for the desktop harnesses and driver host
    tests: $env:RTLNET_HOST_CC, gcc on PATH, the newest MinGW gcc of the AMD
    install (<root>/tps/mingw/<ver>/win64.o/nt/bin).
  * Resolve-RtlnetIperf -> iperf 2 executable or $null: $env:RTLNET_IPERF,
    iperf.exe on PATH, <repo>/../tools/iperf/iperf.exe.
    RvBin is the RISC-V GNU toolchain bin folder of the install
    (<Root>/gnu/riscv/nt/bin, riscv64-unknown-elf-*); the install root
    found through RTLNET_XILINX moves it with the rest of the install.
  * Resolve-RtlnetHostCxx -> host g++ next to the resolved gcc (or
    $env:RTLNET_HOST_CXX), for the OpenH264 decoder build.
  * Resolve-RtlnetFfmpeg -> object Ffmpeg, Ffprobe (or throws): $env:RTLNET_FFMPEG
    (ffmpeg.exe, or the folder holding it), ffmpeg on PATH, the winget package
    folder %LOCALAPPDATA%/Microsoft/WinGet/Packages/Gyan.FFmpeg*/ffmpeg-*/bin.
  * Resolve-RtlnetVlc -> vlc.exe or $null: $env:RTLNET_VLC, vlc.exe on PATH,
    <Program Files>/VideoLAN/VLC/vlc.exe.
  * Get-RtlnetToolDir <name> -> %LOCALAPPDATA%/RTLNet/tools/<name> (created);
    $env:RTLNET_TOOLS_DIR replaces the %LOCALAPPDATA%/RTLNet/tools root.
  * Resolve-RtlnetLdecod / Resolve-RtlnetH264dec -> the JM ldecod and OpenH264
    h264dec executables built by ip/rtlnet_h264_enc/testbench/h264_build_decoders.ps1:
    $env:RTLNET_LDECOD / $env:RTLNET_H264DEC, else the tool directory; $null when
    not built.
  * Resolve-RtlnetVerilator -> object Root, Bash of the MSYS2 install holding ucrt64/bin/verilator
    ($env:RTLNET_MSYS2 or <drive>/msys64); run it as Bash -lc with MSYSTEM=UCRT64.
  * Python scripts run as: python -I <script>.
Revision: 11-09-2026
  * 11-06-2026: initial version (discovery replaces the fixed 2025.2 paths).
  * 11-09-2026: RvBin member (RISC-V toolchain for the MicroBlaze V firmware).
  * 11-09-2026: ffmpeg/ffprobe, VLC, g++, decoder-build resolvers (H.264 encoder harness).
-------------------------------------------------------------------------------
#>

function ConvertTo-RtlnetFwd([string]$p) { return ($p -replace '\\', '/').TrimEnd('/') }

function Get-RtlnetDriveRoots {
    return @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
             ForEach-Object { $_.RootDirectory.FullName })
}

# Sort key of a release folder name ("2026.1" -> [version]2026.1); non-releases sort last.
function Get-RtlnetReleaseKey([string]$name) {
    $v = $null
    if ([version]::TryParse(($name -replace '[^0-9.]', ''), [ref]$v)) { return $v }
    return [version]'0.0'
}

function New-RtlnetXilinx([string]$root, [string]$source) {
    $root = ConvertTo-RtlnetFwd $root
    if (-not (Test-Path -LiteralPath "$root/Vivado/bin/vivado.bat")) { return $null }
    return [pscustomobject]@{
        Root    = $root
        Vivado  = "$root/Vivado"
        Vitis   = "$root/Vitis"
        MbBin   = "$root/gnu/microblaze/nt/bin"
        RvBin   = "$root/gnu/riscv/nt/bin"
        Version = Split-Path -Leaf $root
        Source  = $source
    }
}

function Resolve-RtlnetXilinx {
    $cands = @()
    if ($env:RTLNET_XILINX) { $cands += ,@($env:RTLNET_XILINX, 'RTLNET_XILINX') }
    if ($env:XILINX_VIVADO) { $cands += ,@((Split-Path -Parent $env:XILINX_VIVADO), 'XILINX_VIVADO') }
    $onPath = Get-Command vivado.bat -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $cands += ,@((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $onPath.Source))), 'PATH') }
    foreach ($c in $cands) {
        $x = New-RtlnetXilinx $c[0] $c[1]
        if ($x) { return $x }
        if ($c[1] -eq 'RTLNET_XILINX') { throw "RTLNET_XILINX=$($c[0]) holds no Vivado/bin/vivado.bat" }
    }
    $found = foreach ($d in Get-RtlnetDriveRoots) {
        foreach ($base in 'AMDDesignTools', 'Xilinx') {
            Get-ChildItem -LiteralPath (Join-Path $d $base) -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Vivado\bin\vivado.bat') }
        }
    }
    $best = $found | Sort-Object { Get-RtlnetReleaseKey $_.Name } -Descending | Select-Object -First 1
    if ($best) { return (New-RtlnetXilinx $best.FullName 'search') }
    throw 'no AMD Vivado install found: set RTLNET_XILINX to the install root (the folder holding Vivado/ and Vitis/)'
}

function Resolve-RtlnetAldec {
    if ($env:RTLNET_ALDEC) {
        foreach ($b in @($env:RTLNET_ALDEC, (Join-Path $env:RTLNET_ALDEC 'BIN'))) {
            if (Test-Path -LiteralPath (Join-Path $b 'vsimsa.exe')) { return (ConvertTo-RtlnetFwd $b) }
        }
        throw "RTLNET_ALDEC=$($env:RTLNET_ALDEC) holds no vsimsa.exe"
    }
    $onPath = Get-Command vsimsa.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return (ConvertTo-RtlnetFwd (Split-Path -Parent $onPath.Source)) }
    $found = foreach ($d in Get-RtlnetDriveRoots) {
        Get-ChildItem -LiteralPath (Join-Path $d 'Aldec') -Directory -Filter 'Active-HDL*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'BIN\vsimsa.exe') }
    }
    $best = $found | Sort-Object { Get-RtlnetReleaseKey $_.Name } -Descending | Select-Object -First 1
    if ($best) { return (ConvertTo-RtlnetFwd (Join-Path $best.FullName 'BIN')) }
    throw 'no Aldec Active-HDL install found: set RTLNET_ALDEC to its BIN folder or put vsimsa.exe on PATH'
}

function Resolve-RtlnetPython {
    if ($env:RTLNET_PYTHON) { return $env:RTLNET_PYTHON }
    # Skip the Windows Store alias (WindowsApps\python.exe), which only opens the Store.
    $onPath = Get-Command python.exe, python3.exe -ErrorAction SilentlyContinue |
              Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    $py = Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) {
        $exe = & $py.Source -3 -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) { return "$exe".Trim() }
    }
    $roots = @("$env:LOCALAPPDATA\Programs\Python", $env:ProgramFiles) + (Get-RtlnetDriveRoots)
    $found = foreach ($r in $roots) {
        Get-ChildItem -LiteralPath $r -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'python.exe') }
    }
    $best = $found | Sort-Object { [int](($_.Name -replace '[^0-9]', '') + '0') } -Descending | Select-Object -First 1
    if ($best) { return (Join-Path $best.FullName 'python.exe') }
    throw 'no Python 3 found: set RTLNET_PYTHON to python.exe or put it on PATH'
}

function Resolve-RtlnetHostCc {
    if ($env:RTLNET_HOST_CC) { return $env:RTLNET_HOST_CC }
    $onPath = Get-Command gcc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    # Fallback: the MinGW gcc shipped inside the AMD install (newest version).
    $x = Resolve-RtlnetXilinx
    $found = Get-ChildItem -LiteralPath "$($x.Root)/tps/mingw" -Directory -ErrorAction SilentlyContinue |
             Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'win64.o\nt\bin\gcc.exe') }
    $best = $found | Sort-Object { Get-RtlnetReleaseKey $_.Name } -Descending | Select-Object -First 1
    if ($best) { return (ConvertTo-RtlnetFwd (Join-Path $best.FullName 'win64.o\nt\bin\gcc.exe')) }
    throw 'no host C compiler found: set RTLNET_HOST_CC to gcc.exe or put gcc on PATH'
}

function Resolve-RtlnetIperf {
    if ($env:RTLNET_IPERF) { return $env:RTLNET_IPERF }
    $onPath = Get-Command iperf.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    $sib = Join-Path $PSScriptRoot '..\..\tools\iperf\iperf.exe'
    if (Test-Path -LiteralPath $sib) { return (Resolve-Path -LiteralPath $sib).Path }
    return $null
}

function Resolve-RtlnetHostCxx {
    if ($env:RTLNET_HOST_CXX) { return $env:RTLNET_HOST_CXX }
    $cc = Resolve-RtlnetHostCc
    $cxx = Join-Path (Split-Path -Parent $cc) 'g++.exe'
    if (Test-Path -LiteralPath $cxx) { return (ConvertTo-RtlnetFwd $cxx) }
    $onPath = Get-Command g++.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    throw 'no host C++ compiler found: set RTLNET_HOST_CXX to g++.exe or put g++ on PATH'
}

function Resolve-RtlnetFfmpeg {
    $dirs = @()
    if ($env:RTLNET_FFMPEG) {
        $e = $env:RTLNET_FFMPEG
        if ($e -match '\.exe$') { $dirs += (Split-Path -Parent $e) } else { $dirs += $e }
    }
    $onPath = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $dirs += (Split-Path -Parent $onPath.Source) }
    $pk = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    foreach ($d in @(Get-ChildItem -LiteralPath $pk -Directory -Filter 'Gyan.FFmpeg*' -ErrorAction SilentlyContinue)) {
        foreach ($v in @(Get-ChildItem -LiteralPath $d.FullName -Directory -Filter 'ffmpeg-*' -ErrorAction SilentlyContinue |
                         Sort-Object Name -Descending)) { $dirs += (Join-Path $v.FullName 'bin') }
    }
    foreach ($d in $dirs) {
        if ((Test-Path -LiteralPath (Join-Path $d 'ffmpeg.exe')) -and (Test-Path -LiteralPath (Join-Path $d 'ffprobe.exe'))) {
            return [pscustomobject]@{ Ffmpeg = (ConvertTo-RtlnetFwd (Join-Path $d 'ffmpeg.exe'));
                                      Ffprobe = (ConvertTo-RtlnetFwd (Join-Path $d 'ffprobe.exe')) }
        }
    }
    throw 'no ffmpeg/ffprobe found: set RTLNET_FFMPEG to ffmpeg.exe (or its folder) or put ffmpeg on PATH'
}

function Resolve-RtlnetVlc {
    if ($env:RTLNET_VLC) { return $env:RTLNET_VLC }
    $onPath = Get-Command vlc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $pf) { continue }
        $v = Join-Path $pf 'VideoLAN\VLC\vlc.exe'
        if (Test-Path -LiteralPath $v) { return (ConvertTo-RtlnetFwd $v) }
    }
    return $null
}

function Get-RtlnetToolDir([string]$name) {
    $root = if ($env:RTLNET_TOOLS_DIR) { $env:RTLNET_TOOLS_DIR } else { Join-Path $env:LOCALAPPDATA 'RTLNet\tools' }
    $d = Join-Path $root $name
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return (ConvertTo-RtlnetFwd $d)
}

function Resolve-RtlnetLdecod {
    if ($env:RTLNET_LDECOD) { return $env:RTLNET_LDECOD }
    $exe = Join-Path (Get-RtlnetToolDir 'jm') 'bin/ldecod.exe'
    if (Test-Path -LiteralPath $exe) { return (ConvertTo-RtlnetFwd $exe) }
    return $null
}

function Resolve-RtlnetH264dec {
    if ($env:RTLNET_H264DEC) { return $env:RTLNET_H264DEC }
    $exe = Join-Path (Get-RtlnetToolDir 'openh264') 'bin/h264dec.exe'
    if (Test-Path -LiteralPath $exe) { return (ConvertTo-RtlnetFwd $exe) }
    return $null
}

function Resolve-RtlnetVerilator {
    $roots = @()
    if ($env:RTLNET_MSYS2) { $roots += $env:RTLNET_MSYS2 }
    foreach ($d in Get-RtlnetDriveRoots) { $roots += (Join-Path $d 'msys64') }
    foreach ($r in $roots) {
        $bash = Join-Path $r 'usr\bin\bash.exe'
        $vl = Join-Path $r 'ucrt64\bin\verilator'
        if ((Test-Path -LiteralPath $bash) -and (Test-Path -LiteralPath $vl)) {
            return [pscustomobject]@{ Root = (ConvertTo-RtlnetFwd $r); Bash = (ConvertTo-RtlnetFwd $bash) }
        }
        if ($env:RTLNET_MSYS2 -and ($r -eq $env:RTLNET_MSYS2)) { throw "RTLNET_MSYS2=$r holds no ucrt64/bin/verilator" }
    }
    throw 'no MSYS2 Verilator found: install verilator in MSYS2 UCRT64 or set RTLNET_MSYS2 to the MSYS2 root'
}
