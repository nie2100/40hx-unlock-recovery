#Requires -Version 5.1
<#
  CMP40HX 一键包 —— ACE「弹窗初始化失败」热修（2026-09-28）
  做两件事：
    1) 覆盖 C:\ProgramData\CMP40HXGen2\windows\{RunPostBind.cmd, ACE-Toggle.ps1}
       （新版：恢复 ACE-BOOT 之后把被"停窗"撞坏/被杀掉的 ACE 托盘恢复到用户会话）
    2) （加 -VerifyNow 时）立刻跑一次开机任务做端到端验证
  备份自动放 C:\ProgramData\CMP40HXGen2\windows\logs\pre-hotfix-<时间>\
#>
[CmdletBinding()]
param([switch]$VerifyNow)

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
  if ($VerifyNow) { $a += '-VerifyNow' }
  Write-Host '需要管理员权限，正在提权（UAC 请点“是”）...' -ForegroundColor Yellow
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $a | Out-Null
  exit
}

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }

Say ('================ CMP40HX 热修（ACE 托盘撞窗自愈）================') 'Cyan'
Say ('时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ''

$live = 'C:\ProgramData\CMP40HXGen2\windows'
$src  = Join-Path $PSScriptRoot 'payload'
if (-not (Test-Path -LiteralPath $live)) {
  Say ('没找到 ' + $live + ' —— 这台机器还没装过一键包？先跑一键安装，再回来跑热修。') 'Red'
  Read-Host '按回车关闭'; exit 2
}
if (-not (Test-Path -LiteralPath $src)) {
  Say ('载荷目录缺失: ' + $src + ' —— 请把整个文件夹一起拷过来（别只拷 .cmd）') 'Red'
  Read-Host '按回车关闭'; exit 2
}

# 备份
$bak = Join-Path $live ('logs\pre-hotfix-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $bak | Out-Null
foreach ($n in @('RunPostBind.cmd','ACE-Toggle.ps1')) {
  $f = Join-Path $live $n
  if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $bak $n) -Force }
}
Say ('已备份原文件到: ' + $bak) 'DarkGray'
Say ''

# 覆盖 + 校验
$ok = $true
foreach ($n in @('RunPostBind.cmd','ACE-Toggle.ps1')) {
  $s = Join-Path $src $n
  $d = Join-Path $live $n
  if (-not (Test-Path -LiteralPath $s)) { Say ('载荷缺失: ' + $s) 'Red'; $ok = $false; continue }
  Copy-Item -LiteralPath $s -Destination $d -Force
  $h1 = (Get-FileHash -LiteralPath $s).Hash
  $h2 = (Get-FileHash -LiteralPath $d).Hash
  if ($h1 -eq $h2) { Say ('[OK] ' + $n + '  ->  ' + $d + '   (' + (Get-Item $d).Length + ' B, ' + $h2.Substring(0,16) + ')') 'Green' }
  else { Say ('[失败] ' + $n + ' 复制后哈希不一致') 'Red'; $ok = $false }
}

# 语法校验
$e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $live 'ACE-Toggle.ps1'), [ref]$null, [ref]$e)
if ($e) { Say ('[失败] ACE-Toggle.ps1 语法错误: ' + (($e | ForEach-Object { $_.Message + '@' + $_.Extent.StartLineNumber }) -join ' ; ')) 'Red'; $ok = $false }
else { Say '[OK] ACE-Toggle.ps1 语法校验通过' 'Green' }
$raw = Get-Content -LiteralPath (Join-Path $live 'RunPostBind.cmd') -Raw
if ($raw -match 'ace_toggle HealTray') { Say '[OK] RunPostBind.cmd 已包含托盘自愈调用' 'Green' } else { Say '[失败] RunPostBind.cmd 里没有 HealTray 调用' 'Red'; $ok = $false }

Say ''
if (-not $ok) { Say '热修没有完全成功，请把上面输出发回给 Hermes。' 'Red'; Read-Host '按回车关闭'; exit 1 }
Say '热修已应用。下次开机（或下次重启）就会自动生效：' 'Cyan'
Say '  · Gen2 落地流程不变（停 ACE-BOOT → 重训 → 恢复 ACE-BOOT）'
Say '  · 新增：恢复 ACE-BOOT 之后，若发现 ACE 托盘是在“停窗”里启动的（初始化会失败），'
Say '          或托盘被停窗流程结束掉了，就自动把它重启回你的桌面会话 —— 不再需要手动重启托盘。'

if ($VerifyNow) {
  Say ''
  Say '================ 立刻端到端验证（会短暂停/起 ACE-BOOT，约 1 分钟）================' 'Cyan'
  $pb = Join-Path $live 'logs\postbind.log'
  $before = @()
  if (Test-Path -LiteralPath $pb) { $before = @(Get-Content -LiteralPath $pb -Encoding Default) }
  & cmd.exe /d /c (Join-Path $live 'RunPostBind.cmd')
  $rc = $LASTEXITCODE
  Say ('开机任务退出码 = ' + $rc + $(if ($rc -eq 0) { '  [OK]' } else { '  [失败]' })) $(if ($rc -eq 0) { 'Green' } else { 'Red' })
  Say '--- postbind.log 本次新增 ---'
  $after = @(Get-Content -LiteralPath $pb -Encoding Default)
  $newLines = @($after | Select-Object -Skip $before.Count)
  foreach ($l in $newLines) { if ($l.Trim()) { Say ('  | ' + $l) } }
  Say '--- 当前 ACE 托盘 ---'
  $trays = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Tray' -and $_.ExecutablePath -match 'AntiCheatExpert' })
  if ($trays.Count -eq 0) { Say '  （没有托盘进程 —— 若现在还没登录用户属正常）' 'Yellow' }
  foreach ($t in $trays) { Say ('  ' + $t.Name + ' PID=' + $t.ProcessId + ' session=' + $t.SessionId + ' 启动=' + $t.CreationDate) }
  Say ('--- ACE-BOOT ---')
  Say ((sc.exe query ACE-BOOT | Out-String).Trim())
}
Say ''
Say '完成。有异常就把本窗口内容发回给 Hermes。' 'Cyan'
Read-Host '按回车关闭'
