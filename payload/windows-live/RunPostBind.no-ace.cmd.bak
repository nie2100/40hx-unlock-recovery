@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "LOGDIR=C:\ProgramData\CMP40HXGen2\windows\logs"
if not exist "%LOGDIR%" md "%LOGDIR%" >nul 2>&1
set "LOG=%LOGDIR%\postbind.log"
>>"%LOG%" echo ==== PostBind start %DATE% %TIME% ====

set "RC=99"
for /L %%I in (1,1,3) do (
  if "!RC!"=="99" (
    call :heal
    >>"%LOG%" echo ---- attempt %%I ----
    call "C:\ProgramData\CMP40HXGen2\windows\AutoRetrain.cmd" >>"%LOG%" 2>&1
    set "RC=!ERRORLEVEL!"
    if not "!RC!"=="0" if %%I LSS 3 ( >>"%LOG%" echo attempt %%I exit=!RC!, retry in 15s & ping -n 16 127.0.0.1 >nul 2>&1 )
  )
)
>>"%LOG%" echo ==== PostBind EXIT=!RC! %DATE% %TIME% ====
if "!RC!"=="0" ( >>"%LOG%" echo PASS: physical Gen2 post-bind step succeeded ) else ( >>"%LOG%" echo FAIL: post-bind step did not reach Gen2 )
exit /b !RC!

:heal
set "SYS=%SystemRoot%\System32\drivers"
rem ---- 1) 普通目录源: 每轮都补(火绒会在驱动加载后隔离文件并删服务) ----
for %%S in ("D:\40hx-unlock\drv" "C:\ProgramData\CMP40HXGen2\drivers" "C:\ProgramData\40HXUnlock\drivers" "D:\40hx-unlock\onlyefi-v0.1.1\windows\drivers") do (
  if not exist "%SYS%\ThrottleStop.sys" if exist "%%~S\ThrottleStop.sys" copy /y "%%~S\ThrottleStop.sys" "%SYS%\ThrottleStop.sys" >nul 2>&1
  if not exist "%SYS%\WinRing0x64.sys" if exist "%%~S\WinRing0x64.sys" copy /y "%%~S\WinRing0x64.sys" "%SYS%\WinRing0x64.sys" >nul 2>&1
)
rem ---- 2) 兜底源: ESP(EFI 分区, 杀软不扫) 下的 drv 备份 ----
if not exist "%SYS%\ThrottleStop.sys" (
  for %%L in (Y X W V U T S R Q) do (
    if not exist "%SYS%\ThrottleStop.sys" if not exist "%%L:\" (
      mountvol %%L: /s >nul 2>&1
      if exist "%%L:\EFI\40HX\drv\ThrottleStop.sys" (
        copy /y "%%L:\EFI\40HX\drv\ThrottleStop.sys" "%SYS%\ThrottleStop.sys" >nul 2>&1
        copy /y "%%L:\EFI\40HX\drv\WinRing0x64.sys" "%SYS%\WinRing0x64.sys" >nul 2>&1
        >>"%LOG%" echo heal: restored from ESP %%L:
      )
      mountvol %%L: /d >nul 2>&1
    )
  )
)
if not exist "%SYS%\ThrottleStop.sys" >>"%LOG%" echo heal WARN: ThrottleStop.sys source not found
if not exist "%SYS%\WinRing0x64.sys" >>"%LOG%" echo heal WARN: WinRing0x64.sys source not found
rem ---- 3) 服务必须存在: 厂商 AutoRetrain 只启动不创建(实测 1060) ----
sc query ThrottleStop >nul 2>&1
if errorlevel 1 ( >>"%LOG%" echo heal: create service ThrottleStop & sc create ThrottleStop type= kernel start= demand binPath= "\SystemRoot\System32\drivers\ThrottleStop.sys" >>"%LOG%" 2>&1 )
sc query WinRing0_1_2_0 >nul 2>&1
if errorlevel 1 ( >>"%LOG%" echo heal: create service WinRing0_1_2_0 & sc create WinRing0_1_2_0 type= kernel start= demand binPath= "\SystemRoot\System32\drivers\WinRing0x64.sys" >>"%LOG%" 2>&1 )
exit /b 0
