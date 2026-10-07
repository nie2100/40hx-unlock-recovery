@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "LOGDIR=C:\ProgramData\CMP40HXGen2\windows\logs"
if not exist "%LOGDIR%" md "%LOGDIR%" >nul 2>&1
set "LOG=%LOGDIR%\postbind.log"
if exist "C:\ProgramData\CMP40HXGen2\NO_PRIME" >>"%LOG%" echo NO_PRIME marker present: this boot will NOT pre-bake Gen2 (retrain only)
>>"%LOG%" echo ==== PostBind start !DATE! !TIME! ====
rem ---- 2026-10-02 (user request: keep the boot log small) ----------------------------------
rem The full hardware transcript now goes to logs\retrain-last.log (rewritten every boot).
rem This file keeps only the short verdict lines; trim it when it grows past 64 KB.
for %%A in ("%LOG%") do set "LOGSZ=%%~zA"
if not defined LOGSZ set "LOGSZ=0"
if !LOGSZ! GTR 65536 call :trim
rem ---- 2026-10-05 FIX (customer machine + review): false PASS / concurrent rounds / ACE left stopped ----
rem Symptom: two rounds (boot task + logon task) redirected their tool output into the same logs\newpath-last.out.
rem   The second cmd could not open that file, the command was skipped, ERRORLEVEL kept the previous value (0)
rem   and the log printed "PASS: Gen2 reached" while GPU final was Gen1. The legacy fallback also died with 255
rem   (a bracket inside echo text closed an if-block) and left ACE-BOOT stopped.
rem Fix: (1) per-round private output file, (2) findstr for the tool own PASS line runs UNCONDITIONALLY and is
rem   required (missing file = failure), (3) rounds are serialized by an atomic lock taken AFTER the ACE heal.
rem ---- 2026-10-01 FIX BUG: restore ACE UNCONDITIONALLY (customer: unlocked but ACE blocked) ----
rem old logic: ACE was restored only when Gen2 succeeded (RC==0) -> one failed round left ACE-BOOT
rem   permanently STOPPED (game cannot start its anti-cheat), and a later new-path success never fixed it.
rem now: heal ACE first thing on EVERY boot (no-op when there is no stop record).
set "NOACETOG="
if exist "C:\ProgramData\CMP40HXGen2\NO_ACE_TOGGLE" set "NOACETOG=1"
if defined NOACETOG >>"%LOG%" echo ACE-PRIORITY MODE: ACE-BOOT will NOT be stopped this round - cost: no Gen2 this boot if the new path fails
>>"%LOG%" echo ---- ACE heal (unconditional) !DATE! !TIME! ----
call :ace_toggle on
call :ace_toggle HealTray
rem ---- 2026-10-05 (review H3): lock AFTER the heal - a round that skips must have healed ACE first ----
set "LOCKD=%LOGDIR%\postbind.lock"
rem 2026-10-07b (review T1): per-round verdict file - two rounds starting at the same time must never
rem   delete/overwrite each other's lock-res.txt (that could turn a lost race into a false verdict).
set "LOCKRESF=%LOGDIR%\lock-res-!RANDOM!-!RANDOM!.txt"
del "!LOCKRESF!" >nul 2>&1
set "LOCKRES="
set "LOCKED="
call :lock
if not "!LOCKED!"=="1" (
  >>"%LOG%" echo ==== PostBind SKIP: another round is already running - ACE was healed, nothing else changed !DATE! !TIME! ====
  >>"%LOG%" echo SKIP reason: !LOCKWHY!
  exit /b 75
)
>>"%LOG%" echo round lock taken !DATE! !TIME!
rem 2026-10-07: the lock helper now returns the reason on line 2 of lock-res.txt - log it so a
rem remote diagnosis can tell "no lock" from "stale lock taken over from an earlier boot session".
if defined LOCKWHY >>"%LOG%" echo lock note: !LOCKWHY!
rem 2026-10-05: an installer run may not have been able to replace a helper file that was in use; it then
rem   drops <name>.new next to the target. Finish that INSIDE the round lock (review r4 H1: running it before
rem   the lock let a SKIP round taskkill a helper the winning round was working with) and only when one exists.
call :swapnew

rem ---- 2026-10-01: TAKEOVER OF VENDOR LEFTOVERS (re-checked EVERY boot) ------------------
rem Why: vendor v3.x installers drop scheduled tasks / services / Run values that (re)deploy
rem      ThrottleStop.sys and re-arm their own Gen2 path. Those break the unlock and make
rem      Tencent ACE-BOOT pop up "incompatible software loaded" at every logon.
rem Policy: DISABLE only (never delete) + log every action, so it is fully reversible.
set "VNDSCAN=1"
for /f "delims=" %%T in ('schtasks /query /fo csv /nh 2^>nul ^| findstr /I "40HX ThrottleStop 40HXUnlock"') do (
  echo %%T | findstr /I /C:"CMP40HX Gen2 PostBind" >nul 2>&1
  if errorlevel 1 (
    for /f "tokens=1 delims=," %%N in ("%%T") do (
      >>"%LOG%" echo vendor: disable task %%N
      schtasks /change /tn %%N /disable >>"%LOG%" 2>&1
    )
  )
)
for /f "tokens=1,2 delims=:" %%A in ('sc query type= driver state= all 2^>nul ^| findstr /I "SERVICE_NAME"') do (
  rem 2026-10-01b (audit H9): this loop used to declare only %%C with "tokens=1,3" -> %%C always got
  rem   token1 ("SERVICE_NAME") so "sc qc SERVICE_NAME" always failed and the whole block was dead code.
  for /f "tokens=2" %%C in ("%%A %%B") do (
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
>>"%LOG%" echo throttle: stop ThrottleStop - ACE-BOOT compatibility
    sc stop ThrottleStop >>"%LOG%" 2>&1
  )
  sc qc ThrottleStop 2>nul | findstr /I "DISABLED" >nul 2>&1
  if errorlevel 1 (
    >>"%LOG%" echo throttle: set ThrottleStop start= disabled
    sc config ThrottleStop start= disabled >>"%LOG%" 2>&1
  )
)


rem ---- 2026-10-01: heal the driver files BEFORE the new path ----
rem Why: the new path needs WinRing0x64.sys / inpoutx64.sys exactly like the legacy one, but :heal was
rem only called from inside the legacy fallback. On a machine where the AV had quarantined the .sys files
rem the new path failed on every boot; the next manual run worked only because the legacy round restored them.
call :heal

rem ---- NEW PATH (2026-09-29): inpoutx64 (MMIO) + WinRing0 (PCI config) retrain; ACE-BOOT is NEVER stopped ----
rem The tool verifies the baseline, writes only the two driver-clobbered policy registers, retrains the root port
rem and validates Gen2. It exits 0 only on a verified PASS, otherwise we fall back to the legacy ACE path below.
rem 2026-10-05 (.06 batch, customer machine): some cards' unlock firmware aborts its Gen2 pre-bake (the ESP log
rem   says "baseline mismatch"), so XVE_OVR and the whole Gen2 capability block are never written and the link
rem   can never train to Gen2 no matter how often we retrain. The tool can now do that pre-bake itself with
rem   -AllowPrime; verified in the field on such a card: XVE_OVR 0 -> 6 made VSEC/LNKCAP/LNKCAP2/TLS flip by
rem   themselves (PRIMER_GAPS_POST = none) and the link came up Gen2 x16. These registers are volatile, so the
rem   pre-bake has to run on EVERY boot - that is why it is wired in here. On a healthy card the prime branch
rem   writes nothing (gaps = none). Escape hatch: create C:\ProgramData\CMP40HXGen2\NO_PRIME to switch it off.
rem 2026-10-05 (review r3 H1): when NO_PRIME exists the flag must stay a REAL switch, never an empty/unset
rem   variable - with delayed expansion an UNSET variable expands to the literal text "!PRIMEFLAG!", which the
rem   tool would bind to its positional -GpuBdf parameter (lost auto-detection -> exit 11 -> legacy path ->
rem   ACE stopped on every boot). -NoAutoPrime is a real switch of the tool and means "do not pre-bake".
set "PRIMEFLAG=-AllowPrime"
if exist "C:\ProgramData\CMP40HXGen2\NO_PRIME" set "PRIMEFLAG=-NoAutoPrime"
set "NRC=3"
set "NEWTOOL=C:\ProgramData\CMP40HXGen2\windows\40hx-retrain-inpout.ps1"
set "NOUT=%LOGDIR%\newpath-run-!RANDOM!-!RANDOM!.out"
set "NOUTOK="
if exist "%NEWTOOL%" (
  >>"%LOG%" echo ---- NewPath start: %NEWTOOL% !PRIMEFLAG! -Apply !DATE! !TIME! ----
  rem 2026-10-02: run the tool into its own file. On success only the verdict lines reach this log;
  rem   the full transcript stays in logs\retrain-last.log, which the tool rewrites on every boot.
  powershell -NoProfile -ExecutionPolicy Bypass -File "%NEWTOOL%" !PRIMEFLAG! -Apply > "!NOUT!" 2>&1
  set "NRC=!ERRORLEVEL!"
  >>"%LOG%" echo ---- NewPath EXIT=!NRC! !DATE! !TIME! ----
rem 2026-10-05 FIX: exit code 0 alone is not proof - the tool must have printed its own PASS line into
rem   THIS round private file. A stale/blocked redirect used to produce a false PASS here.
rem 2026-10-05 (review H1): run findstr UNCONDITIONALLY - with "if exist" a missing output file skipped the check,
rem   errorlevel kept the previous value (0) and NOUTOK got set -> false PASS. findstr on a missing file = errorlevel 1.
  findstr /C:"PASS: physical Gen2 x16" "!NOUT!" >nul 2>&1
  if not errorlevel 1 set "NOUTOK=1"
  if "!NRC!"=="0" if not defined NOUTOK (
    >>"%LOG%" echo WARN: tool exit=0 but no PASS line in this round output - false PASS guard tripped
    set "NRC=90"
  )
  if "!NRC!"=="0" (
    for /f "usebackq delims=" %%L in (`findstr /C:"GPU final" /C:"ROOT final" /C:"GUARD = " "!NOUT!"`) do >>"%LOG%" echo %%L
    >>"%LOG%" echo ==== PostBind EXIT=0 !DATE! !TIME! ====
    >>"%LOG%" echo PASS: Gen2 reached on the new path - ACE-BOOT was never stopped
    >>"%LOG%" echo OK: full hardware readings are in logs\retrain-last.log
    copy /y "!NOUT!" "%LOGDIR%\newpath-last.out" >nul 2>&1
    del "!NOUT!" >nul 2>&1
    call :unlock
    exit /b 0
  )
  rem failure: keep the whole transcript here AND archive it - a later boot must not wipe the evidence
  findstr /C:"PRIMER_GAPS" /C:"GUARD = " /C:"GPU final" /C:"ROOT final" "!NOUT!" >>"%LOG%" 2>nul
  type "!NOUT!" >>"%LOG%"
  copy /y "!NOUT!" "%LOGDIR%\newpath-last.out" >nul 2>&1
  call :keepfail !NRC!
  del "!NOUT!" >nul 2>&1
  >>"%LOG%" echo NewPath did not PASS - exit=!NRC! - falling back to the legacy ACE path
) else (
  >>"%LOG%" echo NewPath: tool not found - using the legacy ACE path
)
rem (ascii-only rule)
if defined NOACETOG (
>>"%LOG%" echo ACE-PRIORITY: new path failed exit=!NRC! - no legacy fallback - done for this boot
  >>"%LOG%" echo ==== PostBind EXIT=!NRC! !DATE! !TIME! ====
  call :unlock
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
>>"%LOG%" echo legacy: ACE-BOOT off - starting the retrain attempts !DATE! !TIME!

set "RC=99"
rem 2026-10-01b (audit H1): the retry gate must be "not yet successful", not "== 99".
rem   With "== 99" the 2nd/3rd attempt never ran (RC is the real code after round 1), i.e. dead retry loop.
for /L %%I in (1,1,3) do (
  if not "!RC!"=="0" (
    call :heal
rem legacy path needs ThrottleStop: temporarily allow it inside the ACE-off window, retire it right after
    sc query ThrottleStop >nul 2>&1
    if errorlevel 1 (
      >>"%LOG%" echo throttle-legacy: create service ThrottleStop
      sc create ThrottleStop type= kernel start= demand binPath= "\SystemRoot\System32\drivers\ThrottleStop.sys" >>"%LOG%" 2>&1
      if not exist "%SYS%\ThrottleStop.sys" >>"%LOG%" echo throttle-legacy WARN: ThrottleStop.sys missing
    )
    sc config ThrottleStop start= demand >>"%LOG%" 2>&1
    sc start ThrottleStop >>"%LOG%" 2>&1
    >>"%LOG%" echo ---- attempt %%I ----
    call "C:\ProgramData\CMP40HXGen2\windows\AutoRetrain.cmd" >>"%LOG%" 2>&1
rem 2026-10-01b (audit H1): take the retrain exit code FIRST, then do the sc cleanup.
rem   Otherwise RC is overwritten by "sc config"'s 0 and a failed retrain is reported as PASS.
    set "RC=!ERRORLEVEL!"
    sc stop ThrottleStop >>"%LOG%" 2>&1
    sc config ThrottleStop start= disabled >>"%LOG%" 2>&1
    if not "!RC!"=="0" if %%I LSS 3 ( >>"%LOG%" echo attempt %%I exit=!RC!, retry in 15s & ping -n 16 127.0.0.1 >nul 2>&1 )
  )
)
>>"%LOG%" echo ==== PostBind EXIT=!RC! !DATE! !TIME! ====
if "!RC!"=="0" ( >>"%LOG%" echo PASS: physical Gen2 post-bind step succeeded ) else ( >>"%LOG%" echo FAIL: post-bind step did not reach Gen2 )
rem 2026-10-01: restore UNCONDITIONALLY (regardless of Gen2 result) - never leave ACE-BOOT stopped
if "!ACE_STOPPED!"=="1" call :ace_toggle on
if "!ACE_STOPPED!"=="1" call :ace_toggle HealTray
if "!ACE_STOPPED!"=="1" ( sc query ACE-BOOT | findstr /I "STATE" >>"%LOG%" 2>&1 )
call :unlock
exit /b !RC!

:heal
set "SYS=%SystemRoot%\System32\drivers"
rem ---- 1) normal driver source dirs: refresh every round (AV quarantines the .sys after it loads) ----
for %%S in ("C:\ProgramData\CMP40HXGen2\drivers" "C:\ProgramData\40HXUnlock\drivers") do (
rem 2026-10-01: no longer self-heal ThrottleStop.sys (new path does not need it; loading it annoys ACE-BOOT)
  if not exist "%SYS%\WinRing0x64.sys" if exist "%%~S\WinRing0x64.sys" copy /y "%%~S\WinRing0x64.sys" "%SYS%\WinRing0x64.sys" >nul 2>&1
rem 2026-10-01: the new path needs inpoutx64 as well (sys into System32\drivers, dll into our drivers dir)
  if not exist "%SYS%\inpoutx64.sys" if exist "%%~S\inpoutx64.sys" copy /y "%%~S\inpoutx64.sys" "%SYS%\inpoutx64.sys" >nul 2>&1
  if not exist "%SYS%\inpoutx64.dll" if exist "%%~S\inpoutx64.dll" copy /y "%%~S\inpoutx64.dll" "%SYS%\inpoutx64.dll" >nul 2>&1
  if not exist "C:\ProgramData\CMP40HXGen2\drivers\inpoutx64.dll" if exist "%%~S\inpoutx64.dll" copy /y "%%~S\inpoutx64.dll" "C:\ProgramData\CMP40HXGen2\drivers\inpoutx64.dll" >nul 2>&1
)
rem ---- 2) fallback source: drv backup on the ESP (AV does not scan the EFI partition) ----
rem ---- 2026-10-01b: the sources are stored as base64 text (*.b64) now -> let the helper decode what is missing ----
rem It only writes the missing file(s) into System32\drivers / our drivers dir, verifies sha256, and deletes nothing.
if not exist "%SYS%\WinRing0x64.sys" powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\CMP40HXGen2\windows\Unpack-Drivers.ps1" -Name WinRing0x64.sys >>"%LOG%" 2>&1
if not exist "%SYS%\inpoutx64.sys" powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\CMP40HXGen2\windows\Unpack-Drivers.ps1" -Name inpoutx64.sys >>"%LOG%" 2>&1
if not exist "C:\ProgramData\CMP40HXGen2\drivers\inpoutx64.dll" powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\CMP40HXGen2\windows\Unpack-Drivers.ps1" -Name inpoutx64.dll >>"%LOG%" 2>&1
set "NEEDHEAL="
if not exist "%SYS%\WinRing0x64.sys" set "NEEDHEAL=1"
if not exist "%SYS%\inpoutx64.sys" set "NEEDHEAL=1"
if not exist "C:\ProgramData\CMP40HXGen2\drivers\inpoutx64.dll" set "NEEDHEAL=1"
if defined NEEDHEAL (
  for %%L in (Y X W V U T S R Q) do (
    if not exist "%%L:\" (
      mountvol %%L: /s >nul 2>&1
      if exist "%%L:\EFI\40HX\drv\WinRing0x64.sys" (
        copy /y "%%L:\EFI\40HX\drv\WinRing0x64.sys" "%SYS%\WinRing0x64.sys" >nul 2>&1
        copy /y "%%L:\EFI\40HX\drv\inpoutx64.sys" "%SYS%\inpoutx64.sys" >nul 2>&1
        copy /y "%%L:\EFI\40HX\drv\inpoutx64.dll" "%SYS%\inpoutx64.dll" >nul 2>&1
        if not exist "C:\ProgramData\CMP40HXGen2\drivers\inpoutx64.dll" copy /y "%%L:\EFI\40HX\drv\inpoutx64.dll" "C:\ProgramData\CMP40HXGen2\drivers\inpoutx64.dll" >nul 2>&1
        >>"%LOG%" echo heal: restored drivers from ESP %%L:
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
rem 2026-10-01b audit H8: this service name is often owned by another product - e.g. iGame Center.
rem   NEVER change a foreign service start type - only fix it when binPath points at OUR driver.
sc query WinRing0_1_2_0 >nul 2>&1
if errorlevel 1 (
  >>"%LOG%" echo heal: create service WinRing0_1_2_0
  sc create WinRing0_1_2_0 type= kernel start= demand binPath= "\SystemRoot\System32\drivers\WinRing0x64.sys" >>"%LOG%" 2>&1
) else (
  sc qc WinRing0_1_2_0 2>nul | findstr /I /C:"System32\drivers\WinRing0x64.sys" >nul 2>&1
  if errorlevel 1 (
    >>"%LOG%" echo heal: WinRing0_1_2_0 points elsewhere - left untouched
  ) else (
    sc qc WinRing0_1_2_0 2>nul | findstr /I "DEMAND_START" >nul 2>&1
    if errorlevel 1 (
      >>"%LOG%" echo heal: fix start type WinRing0_1_2_0 - binPath points to our driver
      sc config WinRing0_1_2_0 start= demand >>"%LOG%" 2>&1
    )
  )
)
exit /b 0

:ace_toggle
rem param %1 = off / on
rem ACE (Tencent anti-cheat) locate/stop/restore is handled by ACE-Toggle.ps1: it matches on ImagePath
rem containing AntiCheatExpert, so no hardcoded service name / install dir; original start type is recorded for restore.
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\CMP40HXGen2\windows\ACE-Toggle.ps1" -Action %1 >>"%LOG%" 2>&1
exit /b 0

:lock
rem 2026-10-07 FIX v4 (after the second third-party review - the takeover was still not atomic):
rem   round A and round B both judge an old lock stale; A then creates its fresh lock; if B now just
rem   deletes "the directory" it deletes A's fresh lock and both rounds run (double retrain = false PASS /
rem   ACE state damage). v4 therefore:
rem     (a) takes over only the EXACT lock it judged (owner text + directory timestamp must still match),
rem     (b) claims it with an atomic Move-Item (only one round can move that name away),
rem     (c) writes its own owner record, then READS IT BACK and only then answers TAKEN,
rem     (d) records the holder's process start time as well, so a reused PID cannot look like a live round.
rem Decision order (first match wins); we only run when nobody provably holds the lock:
rem   1 boot session differs (only when the record's first field is really our numeric ticks)  -> stale
rem   2 the lock is older than this boot session (mtime vs LastBootUpTime, >=90s margin;
rem     fallback: age > uptime + 2 min)                                                           -> stale
rem   3 recorded holder is gone (PID + start time) AND corroborated (predates/ticks/age>=2min)    -> stale
rem   4 holder alive and age < 30 min                                                            -> BUSY
rem   5 age < 0 (clock rollback) or age >= 20 min                                                -> stale
rem   6 no owner record at all                                                                   -> stale
rem   7 otherwise (fresh lock without a usable record)                                           -> BUSY
rem Verdict line 1 = TAKEN/BUSY; line 2 = reason, logged by the caller. No helper -> we run (fail-open).
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d='%LOCKD%'; $ttl=20; $hard=30; $bootT=$null; $bt=''; try { $bootT=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime; $bt=[string]$bootT.Ticks } catch { $bootT=$null; $bt='' }; $me=0; $myStart=''; try { $me=[int](Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID) -ErrorAction Stop).ParentProcessId } catch { $me=0 }; if ($me -gt 0) { try { $myStart=(Get-Process -Id $me -ErrorAction Stop).StartTime.ToString('s') } catch { $myStart='' } }; $take=$true; $why='no lock was present'; if (Test-Path -LiteralPath $d) { $owner=''; $lockM=$null; try { $all=[System.IO.File]::ReadAllText((Join-Path $d 'started.txt')); $nl=$all.IndexOf([char]10); if ($nl -lt 0) { $owner=$all.Trim() } else { $owner=$all.Substring(0,$nl).Trim() } } catch { $owner='' }; try { $lockM=(Get-Item -LiteralPath $d).LastWriteTime } catch { $lockM=$null }; $f=($owner -split '\|'); $obt=[string]$f[0]; $num=$false; if ($obt -match '^[0-9]{15,}$') { $num=$true }; $hp=0; if ($f.Count -ge 4) { try { $hp=[int]$f[3] } catch { $hp=0 } }; $hs=''; if ($f.Count -ge 5) { $hs=[string]$f[4] }; $alive=$false; if ($hp -gt 0) { try { $q=Get-Process -Id $hp -ErrorAction Stop; if ([string]$q.ProcessName -like 'cmd*') { $alive=$true; if ($hs -ne '') { $qs=$q.StartTime.ToString('s'); if ($qs -ne $hs) { $alive=$false } } } } catch { $alive=$false } }; $age=(Get-Date)-$lockM; $am=[math]::Round($age.TotalMinutes,1); $predates=$false; if ($bootT -ne $null -and $lockM -lt $bootT.AddSeconds(-90)) { $predates=$true } else { $up=0; try { $up=[int64][System.Environment]::TickCount } catch { $up=0 }; if ($up -le 0) { try { $up=[int64]((Get-CimInstance Win32_PerfFormattedData_PerfOS_System -ErrorAction Stop).SystemUpTime) * 1000 } catch { $up=0 } }; if ($up -gt 60000 -and $up -lt 5184000000 -and $age.TotalMilliseconds -gt ($up + 120000)) { $predates=$true } }; $corrob=$false; if ($predates) { $corrob=$true }; if ($num -and $bt -ne '' -and $obt -ne $bt) { $corrob=$true }; if ($am -ge 2) { $corrob=$true }; if ($num -and $bt -ne '' -and $obt -ne $bt) { $why=('stale: lock from an earlier boot session (' + $owner + ')') } elseif ($predates) { $why=('stale: the lock is older than this boot session (' + $owner + ', age ' + $am + ' min)') } elseif ($hp -gt 0 -and -not $alive -and $corrob) { $why=('stale: holder pid ' + $hp + ' is gone (' + $owner + ', age ' + $am + ' min)') } elseif ($alive -and $am -ge 0 -and $am -lt $hard) { $take=$false; $why=('held by a live round: ' + $owner + ', age ' + $am + ' min') } elseif ($am -lt 0 -or $am -ge $ttl) { $why=('stale: age ' + $am + ' min') } elseif ($obt -eq '' -and $am -lt 1) { $take=$false; $why=('empty lock record appeared moments ago - another round may be writing its record right now (age ' + $am + ' min)') } elseif ($obt -eq '') { $why='stale: lock has no owner record' } else { $take=$false; $why=('held (holder not identifiable): ' + $owner + ', age ' + $am + ' min') } }; if ($take) { $claimed=$false; if (Test-Path -LiteralPath $d) { $same=$false; $nowOwner=''; try { $t2=[System.IO.File]::ReadAllText((Join-Path $d 'started.txt')); $nl2=$t2.IndexOf([char]10); if ($nl2 -lt 0) { $nowOwner=$t2.Trim() } else { $nowOwner=$t2.Substring(0,$nl2).Trim() } } catch { $nowOwner='' }; $nowM=$null; try { $nowM=(Get-Item -LiteralPath $d).LastWriteTime } catch { $nowM=$null }; if ($null -ne $nowM -and $null -ne $lockM -and $nowM -eq $lockM -and $nowOwner -eq $owner) { $same=$true }; if ($same) { $aside=($d + '.stale-' + [string]$PID + '-' + [string](Get-Random)); try { Move-Item -LiteralPath $d -Destination $aside -ErrorAction Stop; Remove-Item -LiteralPath $aside -Recurse -Force -ErrorAction SilentlyContinue; $claimed=$true } catch { $claimed=$false; $why=('stale lock could not be claimed atomically (' + $_.Exception.Message + ')') } } else { $claimed=$false; $why='the lock changed while we were judging it - another round holds the lock now' } } else { $claimed=$true }; if (-not $claimed) { 'BUSY'; $why } else { $made=$false; try { New-Item -ItemType Directory -Path $d -ErrorAction Stop | Out-Null; $made=$true } catch { $made=$false }; if (-not $made) { if (Test-Path -LiteralPath $d) { 'BUSY'; ('another round won the lock while we were taking it over - ' + $why) } else { 'TAKEN'; ('could not create the lock, continuing anyway - ' + $_.Exception.Message) } } else { $val=($bt + '|' + (Get-Date).ToString('s') + '|' + $env:COMPUTERNAME + '|' + [string]$me + '|' + $myStart); $wrote=$false; for ($tryNo=1; $tryNo -le 2; $tryNo++) { try { Set-Content -LiteralPath (Join-Path $d 'started.txt') -Value $val -ErrorAction Stop; $wrote=$true; break } catch { Start-Sleep -Milliseconds 300 } }; if (-not $wrote) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue; 'TAKEN'; 'created the lock directory but could not write the owner record - continuing anyway' } else { $back=''; try { $all3=[System.IO.File]::ReadAllText((Join-Path $d 'started.txt')); $nl3=$all3.IndexOf([char]10); if ($nl3 -lt 0) { $back=$all3.Trim() } else { $back=$all3.Substring(0,$nl3).Trim() } } catch { $back='' }; if ($back -eq $val) { 'TAKEN'; ('took the lock - ' + $why) } else { 'BUSY'; 'the owner record did not stick - treating this as a lost race' } } } } } else { 'BUSY'; $why }" > "%LOCKRESF%" 2>nul
if exist "%LOCKRESF%" set /p LOCKRES=<"%LOCKRESF%"
rem 2026-10-07: line 2 = reason. usebackq so the quoted token is read as a FILE, not as a string.
if exist "%LOCKRESF%" for /f "usebackq skip=1 delims=" %%R in ("%LOCKRESF%") do set "LOCKWHY=%%R"
del "%LOCKRESF%" >nul 2>&1
if "!LOCKRES!"=="TAKEN" set "LOCKED=1"
if not defined LOCKRES set "LOCKED=1"
exit /b 0

:unlock
rem 2026-10-05: never leave OUR round lock behind.
rem 2026-10-05 (review low-3): only delete it when THIS round took it (LOCKRES=TAKEN) - a SKIP round
rem   must never delete the winner's lock, otherwise the winner and a later round can run at once.
if not "!LOCKRES!"=="TAKEN" exit /b 0
if exist "%LOCKD%" rd /s /q "%LOCKD%" >nul 2>&1
exit /b 0

:swapnew
rem Best effort, ASCII only, never fatal: move pending *.new over their targets.
rem 2026-10-05 (review r4 H1): do nothing at all when there is no pending file - never kill a working helper.
rem 2026-10-05 (review r5 N2): only real FILES count - a directory whose name ends in .new must not arm the taskkill.
set "HAVENEW="
for %%F in ("C:\ProgramData\CMP40HXGen2\windows\*.new") do if not exist "%%~fF\" set "HAVENEW=1"
if not defined HAVENEW exit /b 0
taskkill /f /im CMP40HXGen2.exe >nul 2>&1
for %%F in ("C:\ProgramData\CMP40HXGen2\windows\*.new") do (
  move /y "%%~fF" "%%~dpnF" >nul 2>&1
  if exist "%%~fF" >>"%LOG%" echo PENDING-SWAP still blocked: %%~nxF
  if not exist "%%~fF" >>"%LOG%" echo SWAP done: %%~nxF
)
exit /b 0

:trim
rem 2026-10-02: only called when postbind.log passed 64 KB. Keeps the last 200 lines,
rem moves the previous content to postbind.log.1 (full readings live in retrain-last.log anyway).
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='%LOG%'; if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p).Length -gt 65536)){ Copy-Item -LiteralPath $p ($p + '.1') -Force; Set-Content -LiteralPath $p -Value (@(Get-Content -LiteralPath $p -Tail 200)) -Encoding Default }" >nul 2>&1
exit /b 0

:keepfail
rem 2026-10-02: archive a failed round so later boots cannot wipe it. %1 = exit code of the tool.
rem logs\failures\ keeps the newest 20 rounds.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d='%LOGDIR%\failures'; if(-not (Test-Path -LiteralPath $d)){ New-Item -ItemType Directory -Path $d | Out-Null }; $s=Get-Date -Format 'yyyyMMdd-HHmmss'; if(Test-Path -LiteralPath '%NOUT%'){ Copy-Item -LiteralPath '%NOUT%' (Join-Path $d ('newpath-'+$s+'-exit%1.out')) -Force }; if(Test-Path -LiteralPath '%LOGDIR%\retrain-last.log'){ Copy-Item -LiteralPath '%LOGDIR%\retrain-last.log' (Join-Path $d ('retrain-'+$s+'-exit%1.log')) -Force }; Get-ChildItem -LiteralPath $d -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | Remove-Item -Force" >nul 2>&1
exit /b 0
