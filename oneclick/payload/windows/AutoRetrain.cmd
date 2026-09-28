@echo off
setlocal EnableExtensions
set "BASE=%ProgramData%\CMP40HXGen2\windows"
set "LOGDIR=%BASE%\logs"
set "STARTED_TS=0"
set "STARTED_WR=0"

if not exist "%LOGDIR%" md "%LOGDIR%" >nul 2>&1
if exist "%LOGDIR%\last.log" copy /y "%LOGDIR%\last.log" "%LOGDIR%\previous.log" >nul 2>&1
>"%LOGDIR%\last.log" echo ==== CMP40HX Gen2 v0.1.1 package / v0.1.0 core auto run %DATE% %TIME% ====

rem Preserve any reader service that was already running before our task.
sc query "ThrottleStop" | findstr /I "RUNNING" >nul 2>&1
if errorlevel 1 (
  sc start "ThrottleStop" >>"%LOGDIR%\last.log" 2>&1
  if errorlevel 1 (
    >>"%LOGDIR%\last.log" echo FATAL: ThrottleStop service did not start.
    exit /b 30
  )
  set "STARTED_TS=1"
) else (
  >>"%LOGDIR%\last.log" echo ThrottleStop already running; reusing it.
)

sc query "WinRing0_1_2_0" | findstr /I "RUNNING" >nul 2>&1
if errorlevel 1 (
  sc start "WinRing0_1_2_0" >>"%LOGDIR%\last.log" 2>&1
  if errorlevel 1 (
    >>"%LOGDIR%\last.log" echo FATAL: WinRing0_1_2_0 service did not start.
    if "%STARTED_TS%"=="1" sc stop "ThrottleStop" >nul 2>&1
    exit /b 31
  )
  set "STARTED_WR=1"
) else (
  >>"%LOGDIR%\last.log" echo WinRing0_1_2_0 already running; reusing it.
)

ping 127.0.0.1 -n 2 >nul
"%BASE%\CMP40HXGen2.exe" >>"%LOGDIR%\last.log" 2>&1
set "RC=%ERRORLEVEL%"
>>"%LOGDIR%\last.log" echo ==== EXIT=%RC% %DATE% %TIME% ====

if "%STARTED_WR%"=="1" sc stop "WinRing0_1_2_0" >nul 2>&1
if "%STARTED_TS%"=="1" sc stop "ThrottleStop" >nul 2>&1
exit /b %RC%
