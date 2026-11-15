<# Purpose: build the independent bare-metal Cortex-A9 application from an XSA.
Overview: Vitis BSP and GNU compiler resolve from the central tool resolver.
Revision: 11-14-2026. Initial ARM ELF build; no device programming. #>
param([Parameter(Mandatory=$true)][string]$Xsa,
 [ValidatePattern('^[A-Za-z0-9_]{1,24}$')][string]$Tag='arm', [switch]$ReuseBsp)
$ErrorActionPreference='Stop'
$fw=$PSScriptRoot
$repo=(Resolve-Path (Join-Path $fw '../../..')).Path
. (Join-Path $repo 'scripts/rtlnet_tools.ps1')
$x=Resolve-RtlnetXilinx
$py=Resolve-RtlnetPython
$xsaPath=(Resolve-Path -LiteralPath $Xsa).Path
$out=Join-Path $fw "build/$Tag"
$ws=Join-Path $out 'workspace'
New-Item -ItemType Directory -Force $out | Out-Null
& $py "$fw/src/rtlnet_stage_sdk.py" $x.Vitis
if($LASTEXITCODE){throw 'SDK staging failed'}
& $py "$fw/cli/gen_menu.py" --check
if($LASTEXITCODE){throw 'MenuBuilder outputs stale; run cli/gen_menu.py'}
$cfg=Join-Path $out 'rtlnet_build_config.json'
$json=@{workspace=$ws;xsa=$xsaPath} | ConvertTo-Json
[System.IO.File]::WriteAllText($cfg,$json,(New-Object System.Text.UTF8Encoding($false)))
$previous=$env:RTLNET_ZYNQ_BUILD_CONFIG
try {
 $env:RTLNET_ZYNQ_BUILD_CONFIG=$cfg
 if(-not $ReuseBsp) {
  if(Test-Path -LiteralPath $ws){throw 'Workspace exists: choose a fresh tag or explicit -ReuseBsp'}
  & (Join-Path $x.Vitis 'bin/vitis.bat') -s "$fw/src/rtlnet_make_bsp.py"
  if($LASTEXITCODE){throw 'Vitis BSP build failed'}
 }
} finally {$env:RTLNET_ZYNQ_BUILD_CONFIG=$previous}
if(-not(Test-Path -LiteralPath (Join-Path $ws 'rtlnet_bsp_pass.txt'))){throw 'Vitis did not record a successful BSP build'}
$xsaDigest=(Get-FileHash -LiteralPath $xsaPath -Algorithm SHA256).Hash.ToLowerInvariant()
$marker=[System.IO.File]::ReadAllText((Join-Path $ws 'rtlnet_bsp_pass.txt'))
if($marker -notmatch "(?m)^xsa_sha256 $xsaDigest\s*$"){throw 'BSP marker does not match supplied XSA hash; choose a fresh tag'}
$bspRoot=Join-Path $ws 'rtlnet_zybo/ps7_cortexa9_0/rtlnet_arm/bsp'
$inc=Join-Path $bspRoot 'include'
if(-not(Test-Path -LiteralPath (Join-Path $inc 'xparameters.h'))){throw 'No generated ARM BSP include/xparameters.h'}
$lib=Join-Path $bspRoot 'lib'
if(-not(Test-Path -LiteralPath $lib)){throw 'No BSP library directory'}
$cc=Join-Path $x.Vitis 'gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe'
if(-not(Test-Path -LiteralPath $cc)){throw 'Resolved Vitis has no AArch32 GNU compiler'}
$includes=@("-I$out","-I$inc","-I$fw/src","-I$fw/src/video","-I$fw/src/drivers","-I$fw/src/lwip","-I$fw/cli",
 "-I$repo/cores/rtlnet_common/driver","-I$repo/cores/rtlnet_framebuf/driver","-I$repo/cores/rtlnet_vdma_s2mm/driver")
$sources=@(Get-ChildItem "$fw/src/*.c","$fw/src/video/*.c","$fw/src/drivers/*.c","$fw/src/lwip/*.c","$fw/cli/*.c" | ForEach-Object {$_.FullName})
$sources+=@("$repo/cores/rtlnet_framebuf/driver/rtlnet_framebuf.c","$repo/cores/rtlnet_vdma_s2mm/driver/rtlnet_vdma_s2mm.c")
$objects=@()
$buildId=(& git -C $repo rev-parse --short HEAD).Trim()
$dirty=if((& git -C $repo status --porcelain)){'1'}else{'0'}
[System.IO.File]::WriteAllText((Join-Path $out 'rtlnet_build_id.h'),"#define RTLNET_BUILD_ID `"$buildId dirty=$dirty`"`n",(New-Object System.Text.UTF8Encoding($false)))
$flags=@('-mcpu=cortex-a9','-mfpu=vfpv3','-mfloat-abi=hard','-DSDT','-DRTLNET_TARGET_BUILD','-std=c11','-O2','-g','-Wall','-Wextra','-Werror=implicit-function-declaration')
foreach($src in $sources) {
 $obj=Join-Path $out (([System.IO.Path]::GetFileNameWithoutExtension($src))+'.o')
 & $cc @flags @includes -c $src -o $obj
 if($LASTEXITCODE){throw "Compile failed: $src"}
 $objects+=$obj
}
$libs=@(Get-ChildItem -LiteralPath $lib -Filter '*.a' | ForEach-Object {$_.FullName})
if(-not $libs){throw 'No BSP static libraries'}
$elf=Join-Path $out 'rtlnet_zybo.elf'
& $cc @flags "-L$lib" "-specs=$bspRoot/Xilinx.spec" "-T$fw/src/rtlnet_linker.ld" @objects '-Wl,--start-group' @libs -lc -lgcc -lm '-Wl,--end-group' "-Wl,-Map=$out/rtlnet_zybo.map" -o $elf
if($LASTEXITCODE){throw 'ARM ELF link failed'}
& (Join-Path (Split-Path $cc) 'arm-none-eabi-size.exe') $elf
if($LASTEXITCODE){throw 'ELF inspection failed'}
Write-Output "RTLNET_ARM_ELF: PASS $elf"
