@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "LOGDIR=C:\ProgramData\CMP40HXGen2\windows\logs"
if not exist "%LOGDIR%" md "%LOGDIR%" >nul 2>&1
set "LOG=%LOGDIR%\postbind.log"
>>"%LOG%" echo ==== PostBind start %DATE% %TIME% ====

rem ---- NEW PATH (2026-09-29): inpoutx64 (MMIO) + WinRing0 (PCI config) retrain; ACE-BOOT is NEVER stopped ----
rem The tool verifies the baseline, writes only the two driver-clobbered policy registers, retrains the root port
rem and validates Gen2. It exits 0 only on a verified PASS, otherwise we fall back to the legacy ACE path below.
set "NEWTOOL=C:\ProgramData\CMP40HXGen2\windows\40hx-retrain-inpout.ps1"
if exist "%NEWTOOL%" (
  >>"%LOG%" echo ---- NewPath start: %NEWTOOL% -Apply %DATE% %TIME% ----
  powershell -NoProfile -ExecutionPolicy Bypass -File "%NEWTOOL%" -Apply >>"%LOG%" 2>&1
  set "NRC=!ERRORLEVEL!"
  >>"%LOG%" echo ---- NewPath EXIT=!NRC! %DATE% %TIME% ----
  if "!NRC!"=="0" (
    >>"%LOG%" echo ==== PostBind EXIT=0 %DATE% %TIME% ====
    >>"%LOG%" echo PASS: Gen2 reached on the new path - ACE-BOOT was never stopped
    exit /b 0
  )
  >>"%LOG%" echo NewPath did not PASS - exit=!NRC! - falling back to the legacy ACE path
) else (
  >>"%LOG%" echo NewPath: tool not found - using the legacy ACE path
)


rem ---- If the driver already loaded at boot stage (Start=0 Boot) ACE must not be touched at all ----
rem ACE-BOOT only blocks driver IMAGE LOAD; an already loaded driver keeps working, and leaving ACE-BOOT
rem in its boot-loaded state keeps the pre-boot anti-cheat mode valid, so games do not ask for a reboot.
set "ACE_STOPPED=1"
sc query "ThrottleStop" | findstr /I "RUNNING" >nul 2>&1
if not errorlevel 1 set "ACE_STOPPED=0"
if "!ACE_STOPPED!"=="0" >>"%LOG%" echo ACE-SKIP: ThrottleStop already RUNNING, ACE-BOOT left untouched

rem ---- ACE-BOOT (Tencent pre-boot anti-cheat) blocks driver IMAGE LOAD only: stop -> retrain -> restore ----
rem first ask ACE-Tray to step aside so it can not start inside the ACE-BOOT stop window (that is what pops up)
if "!ACE_STOPPED!"=="1" call :ace_toggle QuiesceTray
if "!ACE_STOPPED!"=="1" call :ace_toggle off

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
rem restore the anti-cheat only when Gen2 was reached AND we were the ones who stopped it
if "!RC!"=="0" if "!ACE_STOPPED!"=="1" call :ace_toggle on
rem restore ACE tray into the interactive session if it was started inside the ACE-BOOT stop window
if "!RC!"=="0" if "!ACE_STOPPED!"=="1" call :ace_toggle HealTray
exit /b !RC!

:heal
set "SYS=%SystemRoot%\System32\drivers"
rem ---- 1) normal driver source dirs: refresh every round (AV quarantines the .sys after it loads) ----
for %%S in ("C:\ProgramData\CMP40HXGen2\drivers" "C:\ProgramData\40HXUnlock\drivers") do (
  if not exist "%SYS%\ThrottleStop.sys" if exist "%%~S\ThrottleStop.sys" copy /y "%%~S\ThrottleStop.sys" "%SYS%\ThrottleStop.sys" >nul 2>&1
  if not exist "%SYS%\WinRing0x64.sys" if exist "%%~S\WinRing0x64.sys" copy /y "%%~S\WinRing0x64.sys" "%SYS%\WinRing0x64.sys" >nul 2>&1
)
rem ---- 2) fallback source: drv backup on the ESP (AV does not scan the EFI partition) ----
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
rem ---- 3) services must exist: vendor AutoRetrain only starts them, never creates (1060 observed) ----
sc query ThrottleStop >nul 2>&1
if errorlevel 1 (
  >>"%LOG%" echo heal: create service ThrottleStop
  sc create ThrottleStop type= kernel start= demand binPath= "\SystemRoot\System32\drivers\ThrottleStop.sys" >>"%LOG%" 2>&1
) else (
  rem 2026-09-30: service exists but its start type may have been changed to DISABLED by 360 / ACE / the vulnerable driver blocklist - put it back to demand
  sc qc ThrottleStop 2>nul | findstr /I "DEMAND_START" >nul 2>&1
  if errorlevel 1 (
    >>"%LOG%" echo heal: fix start type ThrottleStop
    sc config ThrottleStop start= demand >>"%LOG%" 2>&1
  )
)
sc query WinRing0_1_2_0 >nul 2>&1
if errorlevel 1 (
  >>"%LOG%" echo heal: create service WinRing0_1_2_0
  sc create WinRing0_1_2_0 type= kernel start= demand binPath= "\SystemRoot\System32\drivers\WinRing0x64.sys" >>"%LOG%" 2>&1
) else (
  sc qc WinRing0_1_2_0 2>nul | findstr /I "DEMAND_START" >nul 2>&1
  if errorlevel 1 (
    >>"%LOG%" echo heal: fix start type WinRing0_1_2_0
    sc config WinRing0_1_2_0 start= demand >>"%LOG%" 2>&1
  )
)
exit /b 0

:ace_toggle
rem param %1 = off / on
rem ACE (Tencent anti-cheat) locate/stop/restore is handled by ACE-Toggle.ps1: it matches on ImagePath
rem containing AntiCheatExpert, so no hardcoded service name / install dir; original start type is recorded for restore.
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\CMP40HXGen2\windows\ACE-Toggle.ps1" -Action %1 >>"%LOG%" 2>&1
exit /b 0
