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
  * Resolve-RtlnetXilinx -> object Root, Vivado, Vitis, MbBin, Version
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
Revision: 11-06-2026
  * 11-06-2026: initial version (discovery replaces the fixed 2025.2 paths).
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
