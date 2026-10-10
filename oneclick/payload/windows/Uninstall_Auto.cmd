@echo off
setlocal EnableExtensions

fltmc >nul 2>&1
if errorlevel 1 (
  echo [40HX] ERROR: Run Uninstall_Auto.cmd as Administrator.
  pause
  exit /b 2
)

set "ROOT=%ProgramData%\CMP40HXGen2"
set "DST=%ROOT%\windows"
set "TASK=CMP40HX Gen2 PostBind"

schtasks /Delete /TN "%TASK%" /F >nul 2>&1

rem Stop/delete only what the Windows-task installer owns.
if exist "%DST%\state\owned_wr_service" (
  sc stop "WinRing0_1_2_0" >nul 2>&1
  sc delete "WinRing0_1_2_0" >nul 2>&1
)
if exist "%DST%\state\owned_ts_service" (
  sc stop "ThrottleStop" >nul 2>&1
  sc delete "ThrottleStop" >nul 2>&1
)
if exist "%DST%\state\owned_wr_file" del /f /q "%SystemRoot%\System32\drivers\WinRing0x64.sys" >nul 2>&1
if exist "%DST%\state\owned_ts_file" del /f /q "%SystemRoot%\System32\drivers\ThrottleStop.sys" >nul 2>&1

rd /s /q "%DST%" >nul 2>&1
echo [40HX] Removed Windows task and package-owned Windows reader state.
echo [40HX] EFI boot-entry state under %ROOT%\efi was preserved.
pause
exit /b 0
