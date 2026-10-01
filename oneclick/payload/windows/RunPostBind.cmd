@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "LOGDIR=C:\ProgramData\CMP40HXGen2\windows\logs"
if not exist "%LOGDIR%" md "%LOGDIR%" >nul 2>&1
set "LOG=%LOGDIR%\postbind.log"
>>"%LOG%" echo ==== PostBind start %DATE% %TIME% ====
rem ---- 2026-10-01 修 BUG（客户实测「解锁成功但 ACE 过不了」的根因）--------------
rem 旧逻辑：ACE 的恢复只在 Gen2 成功(RC==0)时才执行 → 只要某一轮旧路径重训失败(exit!=0)，
rem   ACE-BOOT 就永久停在 STOPPED（游戏里 ACE 起不来）；而下一轮若走新路径直接 exit 0，
rem   更不会去恢复它。现在改成：**每轮开机先无条件自愈一次**（没有停机记录时是空操作，安全）。
set "NOACETOG="
if exist "C:\ProgramData\CMP40HXGen2\NO_ACE_TOGGLE" set "NOACETOG=1"
if defined NOACETOG >>"%LOG%" echo ACE-PRIORITY MODE: 本轮绝不停止 ACE-BOOT（代价：新路径不通时本轮不落地 Gen2）
>>"%LOG%" echo ---- ACE heal (unconditional) %DATE% %TIME% ----
call :ace_toggle on
call :ace_toggle HealTray

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
rem ---- ACE 优先模式：新路径没通过也不回落旧路径（旧路径要临时停 ACE-BOOT）----
if defined NOACETOG (
  >>"%LOG%" echo ACE-PRIORITY: 新路径未通过(exit=!NRC!) → 不回落到会停 ACE 的旧路径，本轮结束
  >>"%LOG%" echo ==== PostBind EXIT=!NRC! %DATE% %TIME% ====
  exit /b !NRC!
)


rem ---- If the driver already loaded at boot stage (Start=0 Boot) ACE must not be touched at all ----
rem ACE-BOOT only blocks driver IMAGE LOAD; an already loaded driver keeps working, and leaving ACE-BOOT
rem in its boot-loaded state keeps the pre-boot anti-cheat mode valid, so games do not ask for a reboot.
rem ---- 2026-10-01：**ThrottleStop 退场** ----------------------------------------
rem 新路径（inpoutx64 + WinRing0）根本不需要 ThrottleStop；而它一旦**加载在内核里**，
rem 腾讯 ACE-BOOT 会在游戏启动时报「检测到与游戏可能存在兼容问题的软件程序加载:
rem C:\Windows\System32\drivers\ThrottleStop.sys」→ 游戏进不去。
rem 处理：服务在跑就停掉（卸下映像）、启动类型设为 disabled（不再随开机加载）。
rem 不删服务、不删文件（旧路径 fallback 需要时由本脚本临时放行，见下方 legacy 段）。
sc query ThrottleStop >nul 2>&1
if not errorlevel 1 (
  sc query ThrottleStop | findstr /I "RUNNING" >nul 2>&1
  if not errorlevel 1 (
    >>"%LOG%" echo throttle: stop ThrottleStop (腾讯 ACE-BOOT 兼容性)
    sc stop ThrottleStop >>"%LOG%" 2>&1
  )
  sc qc ThrottleStop 2>nul | findstr /I "DISABLED" >nul 2>&1
  if errorlevel 1 (
    >>"%LOG%" echo throttle: set ThrottleStop start= disabled
    sc config ThrottleStop start= disabled >>"%LOG%" 2>&1
  )
)
set "ACE_STOPPED=1"

rem ---- ACE-BOOT (Tencent pre-boot anti-cheat) blocks driver IMAGE LOAD only: stop -> retrain -> restore ----
rem first ask ACE-Tray to step aside so it can not start inside the ACE-BOOT stop window (that is what pops up)
if "!ACE_STOPPED!"=="1" call :ace_toggle QuiesceTray
if "!ACE_STOPPED!"=="1" call :ace_toggle off

set "RC=99"
for /L %%I in (1,1,3) do (
  if "!RC!"=="99" (
    call :heal
    rem legacy 路径需要 ThrottleStop：在 ACE 已停的窗口内临时放行（服务缺失就重建），跑完立刻退场
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
rem 2026-10-01：**无条件恢复**（不论 Gen2 成功与否）—— 反作弊必须始终被恢复，绝不留 STOPPED
if "!ACE_STOPPED!"=="1" call :ace_toggle on
if "!ACE_STOPPED!"=="1" call :ace_toggle HealTray
if "!ACE_STOPPED!"=="1" ( sc query ACE-BOOT | findstr /I "STATE" >>"%LOG%" 2>&1 )
exit /b !RC!

:heal
set "SYS=%SystemRoot%\System32\drivers"
rem ---- 1) normal driver source dirs: refresh every round (AV quarantines the .sys after it loads) ----
for %%S in ("C:\ProgramData\CMP40HXGen2\drivers" "C:\ProgramData\40HXUnlock\drivers") do (
rem 2026-10-01：不再自愈 ThrottleStop.sys —— 新路径不需要它，且它加载后会惹 ACE-BOOT
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
rem ThrottleStop.sys 是否存在都不影响新路径（不需要它）
if not exist "%SYS%\WinRing0x64.sys" >>"%LOG%" echo heal WARN: WinRing0x64.sys source not found
rem ---- 3) services must exist: vendor AutoRetrain only starts them, never creates (1060 observed) ----
rem 2026-10-01：ThrottleStop 不再被自愈/创建 —— 反而要确保它**不加载**（否则 ACE-BOOT 报兼容性问题）
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
