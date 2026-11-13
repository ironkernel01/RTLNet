@echo off
rem ============================================================================
rem demorelease.bat - copy the built demo images into this demos folder
rem
rem Run it from anywhere:   demos\demorelease.bat
rem
rem What it does: every folder under demos\ that holds a release.txt is a demo.
rem For each of its lines it copies the bitstream and its build_info.txt from
rem the board build folder into
rem     demos\<demo name>\<board>\
rem so that every demo image is in one easy-to-find place.
rem It copies only. It builds nothing and it does not touch the board.
rem
rem release.txt (one line per board image of the demo, # starts a comment):
rem
rem   <board>  <build tag>
rem
rem   board      = folder under boards\ and under the demo (example nexys_video)
rem   build tag  = folder under boards\<board>\build\  (the -Tag of build.ps1)
rem
rem To add a demo: create demos\<demo name>\ with a release.txt and a README.md
rem that says how to run it. This file does not change.
rem
rem Bitstreams only. Never add a netlist or sources of a paid extension and
rem never add an image without its time limit here: this folder is public.
rem ============================================================================
setlocal EnableExtensions

set "DEMOS=%~dp0"
if "%DEMOS:~-1%"=="\" set "DEMOS=%DEMOS:~0,-1%"
for %%I in ("%DEMOS%\..") do set "REPO=%%~fI"

set /a COPIED=0
set /a MISSING=0

echo demorelease: repository %REPO%
echo.

rem ---------------------------------------------------------------------------
rem The demos: every demos\<name>\release.txt, one image per line.
rem ---------------------------------------------------------------------------
set /a DEMOCOUNT=0
for /d %%D in ("%DEMOS%\*") do if exist "%%D\release.txt" (
  set /a DEMOCOUNT+=1
  for /f "usebackq eol=# tokens=1,2" %%A in ("%%D\release.txt") do call :image "%%~nxD" %%A %%B
)
if %DEMOCOUNT% equ 0 (
  echo DEMORELEASE: FAIL no demos\*\release.txt found
  endlocal & exit /b 1
)

rem ---------------------------------------------------------------------------
echo.
echo demorelease: %COPIED% file(s) copied, %MISSING% source(s) missing
if %MISSING% gtr 0 (
  echo DEMORELEASE: FAIL
  endlocal & exit /b 1
)
echo DEMORELEASE: PASS
endlocal & exit /b 0

rem ===========================================================================
rem :image <demo name> <board> <build tag>
rem Copies the bitstream (firmware already merged in) and build_info.txt.
rem ===========================================================================
:image
set "SRC=%REPO%\boards\%~2\build\%~3"
set "DST=%DEMOS%\%~1\%~2"
echo [%~1 / %~2]  from boards\%~2\build\%~3
if not exist "%DST%" mkdir "%DST%"
call :copyone "%SRC%\rtlnet_%~2.bit" "%DST%\rtlnet_%~2.bit"
call :copyone "%SRC%\build_info.txt" "%DST%\build_info.txt"
if not exist "%DST%\README.md" echo   NOTE: no README.md in %DST% yet, write one
exit /b 0

rem ===========================================================================
rem :copyone <source file> <destination file>
rem ===========================================================================
:copyone
if not exist "%~1" (
  echo   MISSING  %~1
  set /a MISSING+=1
  exit /b 0
)
copy /y "%~1" "%~2" >nul
if errorlevel 1 (
  echo   FAILED   %~1
  set /a MISSING+=1
  exit /b 0
)
echo   copied   %~nx1
set /a COPIED+=1
exit /b 0
