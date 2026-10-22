@echo off
REM Build script for the RTLNet CLI desktop harness (Windows / GCC) and the
REM MicroBlaze firmware. Run from firmware\nexys_video.
REM   build.bat           compile and link build\menu.exe (host harness)
REM   build.bat run       build + interactive mode
REM   build.bat demo      build + scripted --demo session (TEST PASS/FAIL)
REM   build.bat clean     remove build artifacts
REM   build.bat firmware  MicroBlaze build\firmware.elf (build.ps1)
REM Revision: 10-22-2026 (initial version)

setlocal
set CFLAGS=-std=c11 -Wall -Wextra -Werror -pedantic -O2 -DRTLNET_HOST_TEST -Isrc -Icli -Ihost -I..\..\cores\rtlnet_common\driver -I..\..\cores\rtlnet_cpu_microblaze\driver

if "%1"=="clean"    goto clean
if "%1"=="demo"     goto demo
if "%1"=="run"      goto run
if "%1"=="firmware" goto firmware

:build
if not exist build mkdir build
echo Compiling host\main.c...
gcc %CFLAGS% -c host\main.c -o build\main.o
if errorlevel 1 goto fail
echo Compiling host\host_platform.c...
gcc %CFLAGS% -c host\host_platform.c -o build\host_platform.o
if errorlevel 1 goto fail
echo Compiling cli\menu.c...
gcc %CFLAGS% -c cli\menu.c -o build\menu.o
if errorlevel 1 goto fail
echo Compiling cli\menu_table.c...
gcc %CFLAGS% -c cli\menu_table.c -o build\menu_table.o
if errorlevel 1 goto fail
echo Compiling cli\cli_commands.c...
gcc %CFLAGS% -c cli\cli_commands.c -o build\cli_commands.o
if errorlevel 1 goto fail
echo Compiling src\rtlnet_board.c...
gcc %CFLAGS% -c src\rtlnet_board.c -o build\rtlnet_board.o
if errorlevel 1 goto fail
echo Compiling src\rtlnet_fmt.c...
gcc %CFLAGS% -c src\rtlnet_fmt.c -o build\rtlnet_fmt.o
if errorlevel 1 goto fail
echo Linking build\menu.exe...
gcc %CFLAGS% -o build\menu.exe build\main.o build\host_platform.o build\menu.o build\menu_table.o build\cli_commands.o build\rtlnet_board.o build\rtlnet_fmt.o
if errorlevel 1 goto fail
echo Build succeeded.
if "%1"=="demo" goto demo_run
if "%1"=="run"  goto run_run
goto end

:clean
del /q build\*.o build\menu.exe build\firmware.elf build\firmware.map 2>nul
if exist build\obj rmdir /s /q build\obj
echo Clean done.
goto end

:demo
if not exist build\menu.exe goto build
:demo_run
build\menu.exe --demo
if errorlevel 1 goto fail
goto end

:run
if not exist build\menu.exe goto build
:run_run
build\menu.exe
goto end

:firmware
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
if errorlevel 1 goto fail
goto end

:fail
echo Build FAILED.
exit /b 1

:end
endlocal
