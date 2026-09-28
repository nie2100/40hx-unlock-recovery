# ACE-Toggle.ps1 —— 只在开机任务需要落地 Gen2 的那十几秒里，临时停掉腾讯 ACE-BOOT 引导驱动
#
# 为什么需要：ACE-BOOT 是 Boot/System 启动的反作弊驱动，会在**映像加载阶段**拦 ThrottleStop.sys
#   → 驱动起不来 → AutoRetrain 报 `StartService 失败 31` / EXIT=30 → Gen2 那次开机不落地。
# 停掉它 → 重训成功 → 再把反作弊恢复原样（Gen2 是链路寄存器状态，恢复反作弊不会撤销它，2026-09-22 实测）。
#
# 安装位置无关性（本脚本的设计目标）：
#   不写死服务名，也不写死安装目录。定位顺序：
#     ① 正在运行、且 ImagePath 含 AntiCheatExpert、且名字是 ACE-BOOT 的内核驱动
#     ② 正在运行、且 ImagePath 含 AntiCheatExpert 的内核驱动
#     ③ 正在运行、且名字是 ACE-BOOT 的驱动
#   托盘进程同样按 **可执行文件完整路径** 匹配 AntiCheatExpert 定位（回退按映像名 ACE-Tray.exe）。
#   因此腾讯换安装目录（D:\、Program Files (x86)、任何自定义目录）都不影响。
#   恢复时用的是**记录下来的原始启动类型**，不写死 `start= system`。
#
[CmdletBinding()]
param(
  [ValidateSet('Locate', 'Off', 'On')] [string]$Action = 'Locate',
  [string]$Log = '',
  [string]$StateFile = "$env:ProgramData\CMP40HXGen2\windows\logs\ace-state.json",
  [object[]]$ServiceList = $null,   # 仅供自测：注入伪服务列表（配合 -Action Locate，只读不动作）
  [object[]]$ProcessList = $null,   # 仅供自测：注入伪进程列表
  [int]$WaitStopSeconds = 20,
  [int]$WaitKillSeconds = 40,
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$script:LogPath = $Log
# 只列“非腾讯 ACE”的其它厂商反作弊：ACE 自己的组件（ACE-GAME/SGuard/ACE-ADVT…）不算“其它”
$script:OtherAc = @('vgk', 'vgc', 'EasyAntiCheat', 'BEDaisy', 'BEService', 'XIGNCODE', 'nProtect', 'TenProtect')

function Write-AceLog {
  param([string]$Text, [string]$Level = 'INFO')
  $line = ('[{0}] ACE {1}: {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Text)
  if ($script:LogPath) {
    # 注意：RunPostBind.cmd 调用本脚本时自己持有 "%LOG%" 的 >> 句柄，
    # 这里再 Add-Content 同一个文件会报“文件正由另一进程使用” → 失败就回退到标准输出，
    # 由 cmd 的 >> 重定向把这一行写进日志（RunPostBind 已按此方式调用：不带 -Log）。
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Output $line }
  }
  else { Write-Output $line }
}

function Get-AceServiceData {
  if ($ServiceList) { return $ServiceList }
  $drv = Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
    Select-Object Name, State, StartMode, PathName, @{ n = 'Kind'; e = { 'driver' } }
  $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^ACE' -or $_.PathName -match 'AntiCheatExpert' } |
    Select-Object Name, State, StartMode, PathName, @{ n = 'Kind'; e = { 'service' } }
  return @($drv) + @($svc)
}

function Select-AceBootService {
  param([object[]]$List)
  $running = @($List | Where-Object { $_.State -eq 'Running' })
  # ①
  $hit = $running | Where-Object { $_.Name -eq 'ACE-BOOT' -and $_.PathName -match 'AntiCheatExpert' } | Select-Object -First 1
  if ($hit) { return $hit }
  # ②
  $hit = $running | Where-Object { $_.PathName -match 'AntiCheatExpert' } | Select-Object -First 1
  if ($hit) { return $hit }
  # ③
  $hit = $List | Where-Object { $_.Name -eq 'ACE-BOOT' } | Select-Object -First 1
  return $hit
}

function Get-AceTrayProcess {
  if ($ProcessList) { return $ProcessList }
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -match 'AntiCheatExpert' } |
    Select-Object ProcessId, Name, ExecutablePath)
}

function Get-StartKeyword {
  param([string]$StartMode)
  switch ($StartMode) {
    'Boot' { return 'boot' }
    'System' { return 'system' }
    'Auto' { return 'auto' }
    'Manual' { return 'demand' }
    'Disabled' { return 'disabled' }
    default { return $null }     # 未知 → 不写，避免把启动类型改坏
  }
}

function Get-AceState {
  if (Test-Path $StateFile) {
    try { return (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
  }
  return $null
}

function Save-AceState {
  param($Obj)
  $dir = Split-Path -Parent $StateFile
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  ($Obj | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Warn-OtherAntiCheat {
  param([object[]]$List, [string]$Exclude)
  $hits = @()
  foreach ($s in $List) {
    if ($s.State -ne 'Running') { continue }
    if ($Exclude -and $s.Name -eq $Exclude) { continue }
    foreach ($k in $script:OtherAc) {
      # 只用“完全相等 或 前缀”匹配：子串匹配会把 Windows 自己的 HTTP/TPM/WindowsTrustedRTProxy 误报
      if ($s.Name -eq $k -or $s.Name -like ($k + '*')) { $hits += $s.Name; break }
    }
  }
  if ($hits.Count -gt 0) {
    Write-AceLog ('检测到其它厂商反作弊正在运行（本脚本不处理；若它们也拦 ThrottleStop.sys，需人工放行或换方案）: ' + (($hits | Select-Object -Unique) -join ', ')) 'WARN'
  }
}

# ------------------------------------------------------------------ 动作
$all = Get-AceServiceData
$boot = Select-AceBootService -List $all

if ($Action -eq 'Locate') {
  if ($boot) {
    Write-AceLog ("定位到: " + $boot.Name + "  state=" + $boot.State + "  start=" + $boot.StartMode + "  path=" + $boot.PathName)
  } else {
    Write-AceLog '未发现 ACE 引导驱动（未安装或未运行）'
  }
  Warn-OtherAntiCheat -List $all -Exclude $boot.Name
  exit 0
}

if ($Action -eq 'Off') {
  if (-not $boot) {
    Write-AceLog '未发现 ACE 引导驱动 —— 跳过（不改任何启动类型）'
    Warn-OtherAntiCheat -List $all -Exclude $boot.Name
    exit 0
  }
  if ($boot.State -ne 'Running') {
    Write-AceLog ($boot.Name + " 当前不是 Running（state=" + $boot.State + "）—— 跳过，不改启动类型")
    Warn-OtherAntiCheat -List $all -Exclude $boot.Name
    exit 0
  }
  $startKw = Get-StartKeyword $boot.StartMode
  Write-AceLog ($boot.Name + ' 正在运行（start=' + $boot.StartMode + '）—— 临时停掉，好让 Gen2 驱动加载')
  Save-AceState @{ Name = $boot.Name; StartMode = $boot.StartMode; StartKeyword = $startKw; Stopped = $false; Time = (Get-Date).ToString('s') }
  if ($DryRun) { Write-AceLog 'DryRun：不实际停止'; exit 0 }

  & sc.exe stop $boot.Name | Out-Null
  $stopped = $false
  $deadline = (Get-Date).AddSeconds($WaitStopSeconds)
  while ((Get-Date) -lt $deadline) {
    if ((sc.exe query $boot.Name | Out-String) -match 'STOPPED') { $stopped = $true; break }
    Start-Sleep -Seconds 3
  }
  if ($stopped) {
    Write-AceLog ($boot.Name + ' 已停止')
  } else {
    Write-AceLog ($boot.Name + ' 仍是 STOP_PENDING —— 托盘进程持有它，按路径定位并结束托盘')
    $trays = Get-AceTrayProcess
    foreach ($t in $trays) {
      $exe = if ($t.ExecutablePath) { $t.ExecutablePath } else { '?' }
      Write-AceLog ('结束托盘: PID=' + $t.ProcessId + ' ' + $exe)
      if (-not $DryRun) { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    if ($trays.Count -eq 0) {
      Write-AceLog '按路径没找到托盘进程 —— 回退按映像名 ACE-Tray.exe 结束'
      if (-not $DryRun) { & taskkill.exe /IM ACE-Tray.exe /F 2>&1 | Out-Null }
    }
    if (-not $DryRun) { & sc.exe stop $boot.Name | Out-Null }
    $deadline = (Get-Date).AddSeconds($WaitKillSeconds)
    while ((Get-Date) -lt $deadline) {
      if ((sc.exe query $boot.Name | Out-String) -match 'STOPPED') { $stopped = $true; break }
      Start-Sleep -Seconds 3
    }
    if ($stopped) { Write-AceLog ($boot.Name + ' 结束托盘后已停止') }
    else { Write-AceLog ($boot.Name + ' 仍未停止 —— 本次重训很可能 EXIT=30，下次开机会重试') 'WARN' }
  }
  $st = Get-AceState
  if ($st) { $st.Stopped = $stopped; Save-AceState $st }
  Warn-OtherAntiCheat -List $all -Exclude $boot.Name
  exit 0
}

if ($Action -eq 'On') {
  $st = Get-AceState
  if (-not $st -or -not $st.Name) {
    Write-AceLog '没有本次停止的记录 —— 不动任何服务'
    exit 0
  }
  if ($DryRun) { Write-AceLog ('DryRun：会恢复 ' + $st.Name + '（start=' + $st.StartMode + '）'); exit 0 }
  if ($st.StartKeyword) {
    & sc.exe config $st.Name ('start= ' + $st.StartKeyword) | Out-Null
    Write-AceLog ('已恢复原始启动类型: ' + $st.Name + ' start= ' + $st.StartKeyword + '（原 ' + $st.StartMode + '）')
  } else {
    Write-AceLog ('原始启动类型未知（' + $st.StartMode + '）—— 只启动服务，不改启动类型') 'WARN'
  }
  & sc.exe start $st.Name | Out-Null
  Start-Sleep -Seconds 2
  $now = (sc.exe query $st.Name | Out-String)
  if ($now -match 'RUNNING') { Write-AceLog ($st.Name + ' 已恢复运行') } else { Write-AceLog ($st.Name + ' 恢复后状态异常: ' + ($now -replace '\s+', ' ')) 'WARN' }
  Write-AceLog 'Gen2 是链路寄存器状态，恢复反作弊不会撤销它（2026-09-22 实测）；ACE-Tray 由下次登录的 HKLM Run 拉起，本会话缺图标可手工运行 ACE-Tray.exe'
  exit 0
}
