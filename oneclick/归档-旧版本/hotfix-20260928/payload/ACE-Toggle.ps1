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
  [ValidateSet('Locate', 'Off', 'On', 'HealTray')] [string]$Action = 'Locate',
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
  # 记录恢复时刻：HealTray 之后要用 [停, 恢复] 这个**真实窗口**判断托盘是不是被撞坏的
  # （只拿“停”的时刻 + 当前时间当窗口会误判：修复后重新起来的托盘也会落进去，实测踩过）
  $st2 = Get-AceState
  if ($st2) {
    $st2 | Add-Member -NotePropertyName ResumedAt -NotePropertyValue ((Get-Date).ToString('s')) -Force
    $st2 | Add-Member -NotePropertyName Resumed -NotePropertyValue ($now -match 'RUNNING') -Force
    Save-AceState $st2
  }
  Write-AceLog 'Gen2 是链路寄存器状态，恢复反作弊不会撤销它（2026-09-22 实测）；ACE-Tray 由下次登录的 HKLM Run 拉起，本会话缺图标可手工运行 ACE-Tray.exe'
  exit 0
}

if ($Action -eq 'HealTray') {
  # 目的：把「被 ACE-BOOT 停窗撞坏 / 被 Off 流程结束掉」的 ACE 托盘恢复到**用户会话**里。
  # 为什么必须做：ACE-Tray.exe 由 HKLM Run 在登录时拉起一次；它若恰好落在“ACE-BOOT 已停→未恢复”
  #   的窗口里启动，就会初始化失败（用户看到“ACE 弹窗初始化失败”）。而 Run 项不会自己重试，
  #   所以必须由开机任务在恢复 ACE-BOOT 之后补一次启动（2026-09-28 在另一台同款机型上实测）。
  # 判据（任一即需恢复）：
  #   a) 托盘不存在，且刚刚（15 分钟内）确实停过 ACE-BOOT  → 拉起（多半是被 Off 流程结束掉了）
  #   b) 托盘存在，但启动时刻落在 [停, 现在+5s] 之间          → 撞窗，初始化已失败，杀掉重启
  #   c) 托盘存在但跑在 session 0（系统会话，桌面看不到）      → 杀掉重启到用户会话
  $trayExe = $null
  $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match 'Tray' -and $_.ExecutablePath -match 'AntiCheatExpert' })
  if ($procs.Count -gt 0 -and $procs[0].ExecutablePath) { $trayExe = $procs[0].ExecutablePath }
  if (-not $trayExe) {
    foreach ($c in @("$env:ProgramFiles\AntiCheatExpert\ACE-Tray.exe", "${env:ProgramFiles(x86)}\AntiCheatExpert\ACE-Tray.exe")) {
      if (Test-Path -LiteralPath $c) { $trayExe = $c; break }
    }
  }
  if (-not $trayExe) { Write-AceLog '没找到 ACE 托盘可执行文件 —— 跳过托盘恢复' 'WARN'; exit 0 }

  $st = Get-AceState
  $stopTime = $null
  if ($st -and $st.Time) { try { $stopTime = [datetime]::Parse($st.Time) } catch { $stopTime = $null } }
  $recentStop = $false
  if ($stopTime) { $recentStop = (((Get-Date) - $stopTime).TotalMinutes -lt 15) }
  $resumeTime = $null
  if ($st -and $st.ResumedAt) { try { $resumeTime = [datetime]::Parse($st.ResumedAt) } catch { $resumeTime = $null } }
  # 幂等：同一次 ACE-BOOT 停止已经恢复过托盘就不再重复（否则每次调用都会再重启一遍托盘）
  if ($st -and $st.HealedAt -and $stopTime) {
    try { if ([datetime]::Parse($st.HealedAt) -ge $stopTime) { Write-AceLog '本轮 ACE-BOOT 停止的托盘恢复已经做过 —— 跳过'; exit 0 } } catch { }
  }

  $need = $false
  $why = ''
  if ($procs.Count -eq 0) {
    if ($recentStop) { $need = $true; $why = '托盘不在运行，且刚刚停过 ACE-BOOT（多半被 Off 流程结束掉了）→ 拉起它' }
    else { Write-AceLog '托盘不在运行，但近期没有 ACE-BOOT 停止动作 —— 不动它（可能是用户自己退出的）'; exit 0 }
  }
  else {
    $t0 = $procs[0]
    $cd = $t0.CreationDate
    if ($t0.SessionId -eq 0) {
      $need = $true; $why = '托盘跑在 session 0（系统会话，桌面看不到图标）→ 重启到用户会话'
    }
    elseif ($stopTime -and $resumeTime -and $cd -ge $stopTime.AddSeconds(-2) -and $cd -le $resumeTime.AddSeconds(2)) {
      $need = $true
      $why = '托盘启动时刻 ' + $cd.ToString('HH:mm:ss') + ' 落在 ACE-BOOT 停窗 [' + $stopTime.ToString('HH:mm:ss') + '~' + $resumeTime.ToString('HH:mm:ss') + '] 内 → 它初始化已失败，重启它'
    }
    elseif ($stopTime -and -not $resumeTime -and $cd -ge $stopTime.AddSeconds(-2) -and $cd -le $stopTime.AddSeconds(120)) {
      Write-AceLog '没有 ACE-BOOT 恢复时刻的记录（非本次开机流程调用）—— 跳过撞窗判定，只做“托盘不存在 / session 0”判定'
    }
    else {
      Write-AceLog ('托盘正常（PID=' + $t0.ProcessId + ' session=' + $t0.SessionId + ' 启动=' + $cd.ToString('HH:mm:ss') + '）—— 不需要恢复')
      exit 0
    }
  }

  Write-AceLog ('需要恢复 ACE 托盘: ' + $why)
  if ($DryRun) { Write-AceLog 'DryRun：不实际重启'; exit 0 }
  foreach ($t in $procs) {
    Write-AceLog ('  结束旧托盘 PID=' + $t.ProcessId + ' session=' + $t.SessionId)
    Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 2
  $iuser = (Get-CimInstance Win32_ComputerSystem).UserName
  if (-not $iuser) {
    Write-AceLog '当前没有交互登录用户 → 托盘会在你下次登录时由 HKLM Run 自动拉起（那时 ACE-BOOT 已正常，不会再失败）' 'WARN'
    exit 0
  }
  $tn = 'ACE-Tray Heal'
  try {
    # 关键：任务以 SYSTEM 身份跑，直接 Start-Process 只会把托盘扔进 session 0（不可见）；
    # 用 Interactive 登录类型的计划任务，才能把它启动到**用户会话**（本机实测 session=1）
    $act = New-ScheduledTaskAction -Execute $trayExe
    $pri = New-ScheduledTaskPrincipal -UserId $iuser -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $tn -Action $act -Principal $pri -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $tn -ErrorAction Stop
    Start-Sleep -Seconds 6
    $new = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match 'Tray' -and $_.ExecutablePath -match 'AntiCheatExpert' })
    $ok = $false
    foreach ($n in $new) {
      Write-AceLog ('  新托盘 PID=' + $n.ProcessId + ' session=' + $n.SessionId)
      if ($n.SessionId -ne 0) { $ok = $true }
    }
    if ($ok) { Write-AceLog '托盘已在用户会话重新启动（ACE 托盘图标应已恢复）' }
    else { Write-AceLog '托盘重启后仍不在用户会话 —— 建议注销重登或重启一次' 'WARN' }
  }
  catch { Write-AceLog ('托盘重启失败: ' + $_.Exception.Message) 'WARN' }
  Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
  $st3 = Get-AceState
  if ($st3) { $st3 | Add-Member -NotePropertyName HealedAt -NotePropertyValue ((Get-Date).ToString('s')) -Force; Save-AceState $st3 }
  exit 0
}
