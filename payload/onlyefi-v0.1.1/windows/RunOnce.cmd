@echo off
setlocal EnableExtensions
cd /d "%~dp0"

fltmc >nul 2>&1
if errorlevel 1 (
  echo [40HX] ERROR: Run this file as Administrator.
  pause
  exit /b 2
)

set "TS_SVC=ThrottleStop"
set "WR_SVC=WinRing0_1_2_0"
set "TS_SRC=%~dp0drivers\ThrottleStop.sys"
set "WR_SRC=%~dp0drivers\WinRing0x64.sys"
set "TS_DST=%SystemRoot%\System32\drivers\ThrottleStop.sys"
set "WR_DST=%SystemRoot%\System32\drivers\WinRing0x64.sys"
set "CREATED_TS_SVC=0"
set "CREATED_WR_SVC=0"
set "COPIED_TS=0"
set "COPIED_WR=0"
set "STARTED_TS=0"
set "STARTED_WR=0"
set "RC=99"

if not exist "%~dp0CMP40HXGen2.exe" (
  echo [40HX] ERROR: missing CMP40HXGen2.exe
  set "RC=5"
  goto :cleanup
)
if not exist "%TS_SRC%" (
  echo [40HX] ERROR: missing drivers\ThrottleStop.sys
  set "RC=3"
  goto :cleanup
)
if not exist "%WR_SRC%" (
  echo [40HX] ERROR: missing drivers\WinRing0x64.sys
  set "RC=4"
  goto :cleanup
)

if not exist "%TS_DST%" (
  copy /y "%TS_SRC%" "%TS_DST%" >nul || (set "RC=6" & goto :cleanup)
  set "COPIED_TS=1"
)
if not exist "%WR_DST%" (
  copy /y "%WR_SRC%" "%WR_DST%" >nul || (set "RC=6" & goto :cleanup)
  set "COPIED_WR=1"
)

sc query "%TS_SVC%" >nul 2>&1
if errorlevel 1 (
  echo [40HX] Creating canonical service: %TS_SVC%
  sc create "%TS_SVC%" type= kernel start= demand binPath= "\SystemRoot\System32\drivers\ThrottleStop.sys"
  if errorlevel 1 (set "RC=7" & goto :cleanup)
  set "CREATED_TS_SVC=1"
)

sc query "%WR_SVC%" >nul 2>&1
if errorlevel 1 (
  echo [40HX] Creating canonical service: %WR_SVC%
  sc create "%WR_SVC%" type= kernel start= demand binPath= "\SystemRoot\System32\drivers\WinRing0x64.sys"
  if errorlevel 1 (set "RC=7" & goto :cleanup)
  set "CREATED_WR_SVC=1"
)

sc query "%TS_SVC%" | findstr /I "RUNNING" >nul 2>&1
if errorlevel 1 (
  echo [40HX] Starting %TS_SVC%...
  sc start "%TS_SVC%"
  if errorlevel 1 (set "RC=8" & goto :cleanup)
  set "STARTED_TS=1"
) else (
  echo [40HX] %TS_SVC% already running; reusing it.
)

sc query "%WR_SVC%" | findstr /I "RUNNING" >nul 2>&1
if errorlevel 1 (
  echo [40HX] Starting %WR_SVC%...
  sc start "%WR_SVC%"
  if errorlevel 1 (set "RC=8" & goto :cleanup)
  set "STARTED_WR=1"
) else (
  echo [40HX] %WR_SVC% already running; reusing it.
)

ping 127.0.0.1 -n 2 >nul

echo.
echo [40HX] Running production minimal Gen2 path...
"%~dp0CMP40HXGen2.exe"
set "RC=%ERRORLEVEL%"
echo.
echo [40HX] Helper exit code: %RC%

:cleanup
if "%STARTED_WR%"=="1" sc stop "%WR_SVC%" >nul 2>&1
if "%STARTED_TS%"=="1" sc stop "%TS_SVC%" >nul 2>&1
if "%CREATED_WR_SVC%"=="1" sc delete "%WR_SVC%" >nul 2>&1
if "%CREATED_TS_SVC%"=="1" sc delete "%TS_SVC%" >nul 2>&1
if "%COPIED_WR%"=="1" del /f /q "%WR_DST%" >nul 2>&1
if "%COPIED_TS%"=="1" del /f /q "%TS_DST%" >nul 2>&1

if "%RC%"=="0" (
  echo [40HX] PASS. Expected final link: PCIe x16 2.0 @ x16 2.0.
) else (
  echo [40HX] FAIL. Do not install auto-start yet. Keep this window/log for diagnosis.
)
pause
exit /b %RC%
