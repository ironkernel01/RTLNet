@echo off
REM Purpose: MenuBuilder host build/demo/run using the central compiler resolver.
REM Overview: positive and negative controls precede interactive mode.
REM Revision: 11-14-2026.
if /I "%~1"=="clean" goto clean
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\test\rtlnet_host_tests.ps1"
if errorlevel 1 exit /b 1
if /I "%~1"=="run" "%~dp0..\build\menu.exe" --run
exit /b %errorlevel%
:clean
powershell -NoProfile -ExecutionPolicy Bypass -Command "Remove-Item -LiteralPath '%~dp0..\build\menu.exe' -Force -ErrorAction SilentlyContinue"
exit /b 0
