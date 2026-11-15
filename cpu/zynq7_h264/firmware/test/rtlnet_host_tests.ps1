<# Purpose: host compile/tests for portable firmware and new ARM CLI/PHY logic.
Overview: compiler and Python are resolved centrally; negative controls must fail.
Revision: 11-14-2026. Initial Zynq host runner. #>
$ErrorActionPreference='Stop'
$fw=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repo=(Resolve-Path (Join-Path $fw '../../..')).Path
. (Join-Path $repo 'scripts/rtlnet_tools.ps1')
$cc=Resolve-RtlnetHostCc
$py=Resolve-RtlnetPython
$out=Join-Path $fw 'build'
New-Item -ItemType Directory -Force $out | Out-Null
& $py "$fw/cli/gen_menu.py"
if($LASTEXITCODE){throw 'menu generation failed'}
& $py "$fw/cli/gen_menu.py" --check
if($LASTEXITCODE){throw 'menu reproducibility failed'}
& $py "$fw/cli/check_menu.py"
if($LASTEXITCODE){throw 'menu callback check failed'}
$includes=@("-I$fw/src","-I$fw/src/video","-I$fw/src/drivers","-I$fw/src/lwip","-I$fw/cli",
 "-I$repo/cores/rtlnet_common/driver","-I$repo/cores/rtlnet_framebuf/driver","-I$repo/cores/rtlnet_vdma_s2mm/driver")
$sources=@("$fw/test/rtlnet_cli_host_test.c","$fw/test/rtlnet_host_stubs.c","$fw/src/rtlnet_camera.c","$fw/src/rtlnet_dphy.c",
 "$fw/cli/menu.c","$fw/cli/menu_table.c","$fw/cli/rtlnet_commands.c")
$sources+=@(Get-ChildItem "$fw/src/video/*.c","$fw/src/drivers/*.c" | ForEach-Object {$_.FullName})
$sources+=@("$repo/cores/rtlnet_framebuf/driver/rtlnet_framebuf.c","$repo/cores/rtlnet_vdma_s2mm/driver/rtlnet_vdma_s2mm.c")
& $cc -std=c11 -O2 -Wall -Wextra -Werror -pedantic -DRTLNET_HOST_TEST @includes @sources -o "$out/menu.exe"
if($LASTEXITCODE){throw 'CLI host compile failed'}
& "$out/menu.exe"
if($LASTEXITCODE){throw 'CLI test failed'}
& "$out/menu.exe" --neg
if($LASTEXITCODE -eq 0){throw 'CLI negative failed to fail'}
& $cc -std=c11 -O2 -Wall -Wextra -Werror "-I$fw/src" "$fw/test/phy_host_test.c" -o "$out/rtlnet_phy_test.exe"
if($LASTEXITCODE){throw 'PHY test compile failed'}
& "$out/rtlnet_phy_test.exe"
if($LASTEXITCODE){throw 'PHY test failed'}
& "$out/rtlnet_phy_test.exe" --neg
if($LASTEXITCODE -eq 0){throw 'PHY negative failed to fail'}
& $py "$fw/test/rtlnet_extract_phy_test.py" $out
if($LASTEXITCODE){throw 'PHY function extraction failed'}
& $cc -std=c11 -O2 -Wall -Wextra -Werror "-I$fw/src" "-I$out" "$fw/test/rtlnet_phy_port_test.c" -o "$out/rtlnet_phy_port_test.exe"
if($LASTEXITCODE){throw 'PHY MDIO model compile failed'}
& "$out/rtlnet_phy_port_test.exe"
if($LASTEXITCODE){throw 'PHY MDIO model failed'}
& "$out/rtlnet_phy_port_test.exe" --neg
if($LASTEXITCODE -eq 0){throw 'PHY MDIO negative failed to fail'}
& $cc -std=c11 -O2 -Wall -Wextra -Werror "-I$fw/src/drivers" "$fw/test/test_rtlnet_ratectl.c" "$fw/src/drivers/rtlnet_ratectl.c" -o "$out/rtlnet_ratectl_test.exe"
if($LASTEXITCODE){throw 'ratectl test compile failed'}
& "$out/rtlnet_ratectl_test.exe"
if($LASTEXITCODE){throw 'ratectl test failed'}
Write-Output 'RTLNET_ARM_HOST: PASS CLI, PHY, rate control and negative controls'
