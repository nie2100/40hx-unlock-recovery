@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "LOGDIR=C:\ProgramData\CMP40HXGen2\windows\logs"
if not exist "%LOGDIR%" md "%LOGDIR%" >nul 2>&1
set "LOG=%LOGDIR%\postbind.log"
>>"%LOG%" echo ==== PostBind start %DATE% %TIME% ====
rem ---- 2026-10-01 FIX BUG: restore ACE UNCONDITIONALLY (customer: unlocked but ACE blocked) ----
rem old logic: ACE was restored only when Gen2 succeeded (RC==0) -> one failed round left ACE-BOOT
rem   permanently STOPPED (game cannot start its anti-cheat), and a later new-path success never fixed it.
rem now: heal ACE first thing on EVERY boot (no-op when there is no stop record).
set "NOACETOG="
if exist "C:\ProgramData\CMP40HXGen2\NO_ACE_TOGGLE" set "NOACETOG=1"
if defined NOACETOG >>"%LOG%" echo ACE-PRIORITY MODE: ACE-BOOT will NOT be stopped this round (cost: no Gen2 this boot if the new path fails)
>>"%LOG%" echo ---- ACE heal (unconditional) %DATE% %TIME% ----
call :ace_toggle on
call :ace_toggle HealTray

rem ---- 2026-10-01: TAKEOVER OF VENDOR LEFTOVERS (re-checked EVERY boot) ------------------
rem Why: vendor v3.x installers drop scheduled tasks / services / Run values that (re)deploy
rem      ThrottleStop.sys and re-arm their own Gen2 path. Those break the unlock and make
rem      Tencent ACE-BOOT pop up "incompatible software loaded" at every logon.
rem Policy: DISABLE only (never delete) + log every action, so it is fully reversible.
set "VNDSCAN=1"
for /f "delims=" %%T in ('schtasks /query /fo csv /nh 2^>nul ^| findstr /I "40HX Gen2 ThrottleStop 40HXUnlock"') do (
  echo %%T | findstr /I /C:"CMP40HX Gen2 PostBind" >nul 2>&1
  if errorlevel 1 (
    for /f "tokens=1 delims=," %%N in ("%%T") do (
      >>"%LOG%" echo vendor: disable task %%N
      schtasks /change /tn %%N /disable >>"%LOG%" 2>&1
    )
  )
)
for /f "tokens=1,2 delims=:" %%A in ('sc query type= driver state= all 2^>nul ^| findstr /I "SERVICE_NAME"') do (
  for /f "tokens=1,3" %%C in ("%%A %%B") do (
    sc qc %%C 2>nul | findstr /I "ThrottleStop 40HXUnlock" >nul 2>&1
    if not errorlevel 1 (
      sc query %%C 2>nul | findstr /I "RUNNING" >nul 2>&1
      if not errorlevel 1 ( >>"%LOG%" echo vendor: stop driver %%C & sc stop %%C >>"%LOG%" 2>&1 )
      >>"%LOG%" echo vendor: disable driver %%C
      sc config %%C start= disabled >>"%LOG%" 2>&1
    )
  )
)
rem NOTE: HKCU\...\Run cannot be edited by a SYSTEM task -> the ACE repair tool handles that side.

rem ---- 2026-10-01: THROTTLESTOP RETIREMENT ----
rem The new path (inpoutx64 + WinRing0) does NOT need ThrottleStop. Once loaded in the kernel, ACE-BOOT
rem pops up: "incompatible software loaded: C:\Windows\System32\drivers\ThrottleStop.sys" and the game will not start.
rem (keep this file ASCII-only: cmd.exe parses it as GBK)
rem Action: stop the service if running and set its start type to disabled so nothing loads it at boot.
rem We do not delete the service or the file: the legacy fallback re-enables it inside the ACE-off window.
sc query ThrottleStop >nul 2>&1
if not errorlevel 1 (
  sc query ThrottleStop | findstr /I "RUNNING" >nul 2>&1
  if not errorlevel 1 (
>>"%LOG%" echo throttle: stop ThrottleStop (ACE-BOOT compatibility)
    sc stop ThrottleStop >>"%LOG%" 2>&1
  )
  sc qc ThrottleStop 2>nul | findstr /I "DISABLED" >nul 2>&1
  if errorlevel 1 (
    >>"%LOG%" echo throttle: set ThrottleStop start= disabled
    sc config ThrottleStop start= disabled >>"%LOG%" 2>&1
  )
)


rem ---- NEW PATH (2026-09-29): inpoutx64 (MMIO) + WinRing0 (PCI config) retrain; ACE-BOOT is NEVER stopped ----
rem The tool verifies the baseline, writes only the two driver-clobbered policy registers, retrains the root port
rem and validates Gen2. It exits 0 only on a verified PASS, otherwise we fall back to the legacy ACE path below.
set "NRC=3"
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
rem (ascii-only rule)
if defined NOACETOG (
>>"%LOG%" echo ACE-PRIORITY: new path failed exit=!NRC! - no legacy fallback - done for this boot
  >>"%LOG%" echo ==== PostBind EXIT=!NRC! %DATE% %TIME% ====
  exit /b !NRC!
)


rem ---- If the driver already loaded at boot stage (Start=0 Boot) ACE must not be touched at all ----
rem ACE-BOOT only blocks driver IMAGE LOAD; an already loaded driver keeps working, and leaving ACE-BOOT
rem in its boot-loaded state keeps the pre-boot anti-cheat mode valid, so games do not ask for a reboot.
set "ACE_STOPPED=1"

rem ---- ACE-BOOT (Tencent pre-boot anti-cheat) blocks driver IMAGE LOAD only: stop -> retrain -> restore ----
rem first ask ACE-Tray to step aside so it can not start inside the ACE-BOOT stop window (that is what pops up)
if "!ACE_STOPPED!"=="1" call :ace_toggle QuiesceTray
if "!ACE_STOPPED!"=="1" call :ace_toggle off

set "RC=99"
for /L %%I in (1,1,3) do (
  if "!RC!"=="99" (
    call :heal
rem legacy path needs ThrottleStop: temporarily allow it inside the ACE-off window, retire it right after
    sc query ThrottleStop >nul 2>&1
    if errorlevel 1 (
      >>"%LOG%" echo throttle(legacy): create service ThrottleStop
      sc create ThrottleStop type= kernel start= demand binPath= "\SystemRoot\System32\drivers\ThrottleStop.sys" >>"%LOG%" 2>&1
      if not exist "%SYS%\ThrottleStop.sys" >>"%LOG%" echo throttle(legacy) WARN: ThrottleStop.sys missing
    )
    sc config ThrottleStop start= demand >>"%LOG%" 2>&1
    sc start ThrottleStop >>"%LOG%" 2>&1
    >>"%LOG%" echo ---- attempt %%I ----
    call "C:\ProgramData\CMP40HXGen2\windows\AutoRetrain.cmd" >>"%LOG%" 2>&1
    sc stop ThrottleStop >>"%LOG%" 2>&1
    sc config ThrottleStop start= disabled >>"%LOG%" 2>&1
    set "RC=!ERRORLEVEL!"
    if not "!RC!"=="0" if %%I LSS 3 ( >>"%LOG%" echo attempt %%I exit=!RC!, retry in 15s & ping -n 16 127.0.0.1 >nul 2>&1 )
  )
)
>>"%LOG%" echo ==== PostBind EXIT=!RC! %DATE% %TIME% ====
if "!RC!"=="0" ( >>"%LOG%" echo PASS: physical Gen2 post-bind step succeeded ) else ( >>"%LOG%" echo FAIL: post-bind step did not reach Gen2 )
rem 2026-10-01: restore UNCONDITIONALLY (regardless of Gen2 result) - never leave ACE-BOOT stopped
if "!ACE_STOPPED!"=="1" call :ace_toggle on
if "!ACE_STOPPED!"=="1" call :ace_toggle HealTray
if "!ACE_STOPPED!"=="1" ( sc query ACE-BOOT | findstr /I "STATE" >>"%LOG%" 2>&1 )
exit /b !RC!

:heal
set "SYS=%SystemRoot%\System32\drivers"
rem ---- 1) normal driver source dirs: refresh every round (AV quarantines the .sys after it loads) ----
for %%S in ("C:\ProgramData\CMP40HXGen2\drivers" "C:\ProgramData\40HXUnlock\drivers") do (
rem 2026-10-01: no longer self-heal ThrottleStop.sys (new path does not need it; loading it annoys ACE-BOOT)
  if not exist "%SYS%\WinRing0x64.sys" if exist "%%~S\WinRing0x64.sys" copy /y "%%~S\WinRing0x64.sys" "%SYS%\WinRing0x64.sys" >nul 2>&1
)
rem ---- 2) fallback source: drv backup on the ESP (AV does not scan the EFI partition) ----
if not exist "%SYS%\WinRing0x64.sys" (
  for %%L in (Y X W V U T S R Q) do (
    if not exist "%SYS%\WinRing0x64.sys" if not exist "%%L:\" (
      mountvol %%L: /s >nul 2>&1
      if exist "%%L:\EFI\40HX\drv\WinRing0x64.sys" (
        copy /y "%%L:\EFI\40HX\drv\WinRing0x64.sys" "%SYS%\WinRing0x64.sys" >nul 2>&1
        >>"%LOG%" echo heal: restored WinRing0 from ESP %%L:
      )
      mountvol %%L: /d >nul 2>&1
    )
  )
)
rem ThrottleStop.sys presence is irrelevant to the new path
if not exist "%SYS%\WinRing0x64.sys" >>"%LOG%" echo heal WARN: WinRing0x64.sys source not found
rem ---- 3) services must exist: vendor AutoRetrain only starts them, never creates (1060 observed) ----
rem 2026-10-01: never create/self-heal ThrottleStop; instead make SURE it does not load
sc query ThrottleStop >nul 2>&1
if not errorlevel 1 (
  sc query ThrottleStop | findstr /I "RUNNING" >nul 2>&1
  if not errorlevel 1 ( sc stop ThrottleStop >>"%LOG%" 2>&1 )
  sc qc ThrottleStop 2>nul | findstr /I "DISABLED" >nul 2>&1
  if errorlevel 1 ( sc config ThrottleStop start= disabled >>"%LOG%" 2>&1 )
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
