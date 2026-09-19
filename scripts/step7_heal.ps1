$ErrorActionPreference='Continue'
$log='D:\40hx-unlock\step7_heal.txt'
if (Test-Path $log) { Remove-Item $log -Force }
function W($s){ ($s | Out-String) | Out-File -FilePath $log -Append -Encoding utf8 }
$bak='C:\ProgramData\40HXUnlock\drivers'
$DRV="$env:ProgramData\CMP40HXGen2\drivers"
$DST="$env:ProgramData\CMP40HXGen2\windows"
W ("=== 驱动自愈源测试 + 多源包装 " + (Get-Date) + " ===")

# 1) 复制到自愈目录, 跟踪 10 秒是否被删
foreach ($n in @('ThrottleStop.sys','WinRing0x64.sys')) { Copy-Item (Join-Path $bak $n) (Join-Path $DRV $n) -Force }
W ("复制后立即: " + ((Get-ChildItem $DRV | Select-Object -ExpandProperty Name) -join ', '))
Start-Sleep -Seconds 10
W ("10 秒后: " + ((Get-ChildItem $DRV -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '))
W ("System32 现状: " + ((Get-ChildItem "$env:SystemRoot\System32\drivers" -ErrorAction SilentlyContinue | Where-Object {$_.Name -match 'ThrottleStop|WinRing0'} | Select-Object -ExpandProperty Name) -join ', '))

# 2) 多源自愈包装
$wrap = @"
@echo off
setlocal
set "SYS=%SystemRoot%\System32\drivers"
for %%S in ("C:\ProgramData\40HXUnlock\drivers" "C:\ProgramData\CMP40HXGen2\drivers" "D:\40hx-unlock\onlyefi-v0.1.1\windows\drivers") do (
  if not exist "%SYS%\ThrottleStop.sys" if exist "%%~S\ThrottleStop.sys" copy /y "%%~S\ThrottleStop.sys" "%SYS%\ThrottleStop.sys" >nul 2>&1
  if not exist "%SYS%\WinRing0x64.sys" if exist "%%~S\WinRing0x64.sys" copy /y "%%~S\WinRing0x64.sys" "%SYS%\WinRing0x64.sys" >nul 2>&1
)
call "C:\ProgramData\CMP40HXGen2\windows\AutoRetrain.cmd"
exit /b %ERRORLEVEL%
"@
[System.IO.File]::WriteAllText("$DST\RunPostBind.cmd", $wrap, [System.Text.Encoding]::ASCII)
W ("多源 RunPostBind.cmd 已写入: " + (Test-Path "$DST\RunPostBind.cmd"))
$TASK='CMP40HX Gen2 PostBind'
W ((schtasks /query /tn $TASK /v /fo LIST 2>&1 | Select-String '要运行的任务|作为用户运行|计划类型' | Out-String))
W "step7 done"
