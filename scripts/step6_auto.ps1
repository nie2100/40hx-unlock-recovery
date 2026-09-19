$ErrorActionPreference='Continue'
$log='D:\40hx-unlock\step6_auto.txt'
if (Test-Path $log) { Remove-Item $log -Force }
function W($s){ ($s | Out-String) | Out-File -FilePath $log -Append -Encoding utf8 }
$pkg='D:\40hx-unlock\onlyefi-v0.1.1\windows'
$bak='C:\ProgramData\40HXUnlock\drivers'
$ROOT="$env:ProgramData\CMP40HXGen2"; $DST="$ROOT\windows"; $DRV="$ROOT\drivers"; $TASK='CMP40HX Gen2 PostBind'
W ("=== 装开机任务(带驱动自愈) + 复读状态 " + (Get-Date) + " ===")
foreach ($d in @($ROOT,$DST,"$DST\logs","$DST\state",$DRV)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
foreach ($f in @('CMP40HXGen2.exe','AutoRetrain.cmd','Uninstall_Auto.cmd','Status.cmd')) { Copy-Item (Join-Path $pkg $f) (Join-Path $DST $f) -Force }
# 驱动: 系统目录 + 自愈备份
$ts="$env:SystemRoot\System32\drivers\ThrottleStop.sys"; $wr="$env:SystemRoot\System32\drivers\WinRing0x64.sys"
foreach ($n in @('ThrottleStop.sys','WinRing0x64.sys')) {
  Copy-Item (Join-Path $bak $n) (Join-Path $DRV $n) -Force
  if (-not (Test-Path (Join-Path "$env:SystemRoot\System32\drivers" $n))) { Copy-Item (Join-Path $bak $n) (Join-Path "$env:SystemRoot\System32\drivers" $n) -Force }
  if (-not (Test-Path (Join-Path (Join-Path $pkg 'drivers') $n))) { Copy-Item (Join-Path $bak $n) (Join-Path (Join-Path $pkg 'drivers') $n) -Force }
}
W ("  System32 驱动: TS=" + (Test-Path $ts) + " WR=" + (Test-Path $wr) + " ; 自愈备份目录=" + ((Get-ChildItem $DRV | Measure-Object).Count) + " 个文件")

# 自愈包装脚本
$wrap = @"
@echo off
setlocal
set "SRC=C:\ProgramData\CMP40HXGen2\drivers"
if not exist "%SystemRoot%\System32\drivers\ThrottleStop.sys" copy /y "%SRC%\ThrottleStop.sys" "%SystemRoot%\System32\drivers\ThrottleStop.sys" >nul 2>&1
if not exist "%SystemRoot%\System32\drivers\WinRing0x64.sys" copy /y "%SRC%\WinRing0x64.sys" "%SystemRoot%\System32\drivers\WinRing0x64.sys" >nul 2>&1
call "C:\ProgramData\CMP40HXGen2\windows\AutoRetrain.cmd"
exit /b %ERRORLEVEL%
"@
[System.IO.File]::WriteAllText("$DST\RunPostBind.cmd", $wrap, [System.Text.Encoding]::ASCII)
W ("  RunPostBind.cmd 写入=" + (Test-Path "$DST\RunPostBind.cmd"))

W ((schtasks /delete /tn $TASK /f 2>&1 | Out-String))
W ((schtasks /create /tn $TASK /sc onstart /ru SYSTEM /rl HIGHEST /tr "cmd.exe /d /c C:\ProgramData\CMP40HXGen2\windows\RunPostBind.cmd" /f 2>&1 | Out-String))
W ((schtasks /query /tn $TASK /v /fo LIST 2>&1 | Out-String))

# 复读当前状态(他们的 helper 对已恢复状态也接受, 幂等)
W "`n--- 复读 CMP40HXGen2.exe (当前状态) ---"
$out = & (Join-Path $pkg 'CMP40HXGen2.exe') 2>&1 | Out-String
W $out
W ("退出码 = " + $LASTEXITCODE)
W ((& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,utilization.gpu --format=csv 2>&1 | Out-String))
W "step6 done"
