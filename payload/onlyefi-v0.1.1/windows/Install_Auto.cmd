@echo off
setlocal EnableExtensions
cd /d "%~dp0"

fltmc >nul 2>&1
if errorlevel 1 (
  echo [40HX] ERROR: Run Install_Auto.cmd as Administrator.
  pause
  exit /b 2
)

set "ROOT=%ProgramData%\CMP40HXGen2"
set "DST=%ROOT%\windows"
set "TASK=CMP40HX Gen2 PostBind"
set "TS_SVC=ThrottleStop"
set "WR_SVC=WinRing0_1_2_0"
set "TS_DST=%SystemRoot%\System32\drivers\ThrottleStop.sys"
set "WR_DST=%SystemRoot%\System32\drivers\WinRing0x64.sys"

if not exist "%~dp0CMP40HXGen2.exe" goto :missing
if not exist "%~dp0AutoRetrain.cmd" goto :missing
if not exist "%~dp0Uninstall_Auto.cmd" goto :missing
if not exist "%~dp0Status.cmd" goto :missing
if not exist "%~dp0drivers\ThrottleStop.sys" goto :missing
if not exist "%~dp0drivers\WinRing0x64.sys" goto :missing

if not exist "%ROOT%" md "%ROOT%" >nul 2>&1
if not exist "%DST%" md "%DST%" >nul 2>&1
if not exist "%DST%\logs" md "%DST%\logs" >nul 2>&1
if not exist "%DST%\state" md "%DST%\state" >nul 2>&1

copy /y "%~dp0CMP40HXGen2.exe" "%DST%\CMP40HXGen2.exe" >nul || goto :copy_fail
copy /y "%~dp0AutoRetrain.cmd" "%DST%\AutoRetrain.cmd" >nul || goto :copy_fail
copy /y "%~dp0Uninstall_Auto.cmd" "%DST%\Uninstall_Auto.cmd" >nul || goto :copy_fail
copy /y "%~dp0Status.cmd" "%DST%\Status.cmd" >nul || goto :copy_fail

rem Never overwrite a pre-existing canonical reader file/service.
if not exist "%TS_DST%" (
  copy /y "%~dp0drivers\ThrottleStop.sys" "%TS_DST%" >nul || goto :copy_fail
  >"%DST%\state\owned_ts_file" echo 1
)
if not exist "%WR_DST%" (
  copy /y "%~dp0drivers\WinRing0x64.sys" "%WR_DST%" >nul || goto :copy_fail
  >"%DST%\state\owned_wr_file" echo 1
)

sc query "%TS_SVC%" >nul 2>&1
if errorlevel 1 (
  sc create "%TS_SVC%" type= kernel start= demand binPath= "\SystemRoot\System32\drivers\ThrottleStop.sys"
  if errorlevel 1 goto :svc_fail
  >"%DST%\state\owned_ts_service" echo 1
)

sc query "%WR_SVC%" >nul 2>&1
if errorlevel 1 (
  sc create "%WR_SVC%" type= kernel start= demand binPath= "\SystemRoot\System32\drivers\WinRing0x64.sys"
  if errorlevel 1 goto :svc_fail
  >"%DST%\state\owned_wr_service" echo 1
)

schtasks /Delete /TN "%TASK%" /F >nul 2>&1
schtasks /Create /TN "%TASK%" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "cmd.exe /d /c C:\ProgramData\CMP40HXGen2\windows\AutoRetrain.cmd" /F
if errorlevel 1 goto :task_fail

echo.
echo [40HX] Installed CMP40HX Gen2 v0.1.1 package.
echo [40HX] Validated core: v0.1.0 unchanged.
echo [40HX] Task: %TASK%
echo [40HX] Runtime: native x64 CMD path, no PowerShell/.NET.
echo [40HX] Last log: %DST%\logs\last.log
echo [40HX] Reboot once and verify GPU-Z plus Status.cmd.
pause
exit /b 0

:missing
echo [40HX] ERROR: package is incomplete.
pause
exit /b 3
:copy_fail
echo [40HX] ERROR: file copy failed.
pause
exit /b 4
:svc_fail
echo [40HX] ERROR: canonical kernel service create failed.
pause
exit /b 5
:task_fail
echo [40HX] ERROR: scheduled task creation failed.
pause
exit /b 6
