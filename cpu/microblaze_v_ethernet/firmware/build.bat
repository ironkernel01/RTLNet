@echo off
REM Build script for the RTLNet CLI desktop harness (Windows / GCC) and the
REM MicroBlaze firmware. Run from cpu\microblaze_v_ethernet\firmware. The source lists live
REM once, in build.ps1; this file only selects its options.
REM   build.bat           compile and link build\menu.exe (host harness)
REM   build.bat run       build + interactive mode
REM   build.bat demo      build + scripted --demo session (TEST PASS/FAIL)
REM   build.bat clean     remove build artifacts
REM   build.bat firmware <xsa>  MicroBlaze build\firmware.elf (BSP from the XSA)
REM Revision: 11-14-2026 (initial version; delegates to build.ps1)

setlocal
if "%1"=="clean"    goto clean
if "%1"=="demo"     goto demo
if "%1"=="run"      goto run
if "%1"=="firmware" goto firmware

:build
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -NoFirmware -HostHarness
if errorlevel 1 goto fail
goto end

:clean
if exist build\obj rmdir /s /q build\obj
del /q build\menu.exe build\firmware.elf build\firmware.map build\lscript.ld 2>nul
echo Clean done (the generated BSP in build\ws is kept; delete build\ws to regenerate it).
goto end

:demo
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -NoFirmware -Demo
if errorlevel 1 goto fail
goto end

:run
if not exist build\menu.exe powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -NoFirmware -HostHarness
build\menu.exe
goto end

:firmware
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Xsa %2
if errorlevel 1 goto fail
goto end

:fail
echo Build FAILED.
exit /b 1

:end
endlocal
