#Requires -Version 5.1
<#
  ============================================================================
   ACE / CMP40HX 一键解锁包 —— 现场排查采集器（只读为主，-Fix 才动手）
  ============================================================================
   背景：一键解锁包（Install-40HXUnlock.ps1 / RunPostBind.cmd）为了落地 PCIe Gen2，
         必须在那十几秒里**临时停掉腾讯反作弊引导驱动 ACE-BOOT**，再恢复。
         ACE 有两种"初始化失败"的典型成因：
           (A) 竞态：ACE 托盘(ACE-Tray.exe, 由 HKLM Run 在登录时拉起)恰好落在
               "ACE-BOOT 已停 → 还没恢复"的窗口里启动 → 托盘初始化必定失败；
           (B) 未恢复：那次 Gen2 没成功(EXIT≠0)，脚本按设计**不恢复** ACE-BOOT，
               或 ACE-BOOT 的启动类型被改成了 Disabled。
   用法：
     双击 排查ACE.cmd            只读采集，报告写到桌面
     双击 排查ACE.cmd -Fix       采集后顺手做安全的恢复动作（改启动类型/启服务/重启托盘）
   作者：Hermes（本机 = 已跑通的同款环境，脚本与判据同源）
#>
[CmdletBinding()]
param(
  [switch]$Fix,
  [string]$OutDir
)

$ErrorActionPreference = 'Continue'

# ---------------- 自提权（双击场景） ----------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
  if ($Fix) { $argList += '-Fix' }
  if ($OutDir) { $argList += @('-OutDir', ('"' + $OutDir + '"')) }
  Write-Host '需要管理员权限，正在提权（UAC 确认框请点“是”）...' -ForegroundColor Yellow
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
  exit
}

if (-not $OutDir -or -not (Test-Path -LiteralPath $OutDir)) { $OutDir = [Environment]::GetFolderPath('Desktop') }
if (-not $OutDir -or -not (Test-Path -LiteralPath $OutDir)) { $OutDir = $env:TEMP }
$report = Join-Path $OutDir ('ACE排查报告-' + $env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')

$script:Verdicts = New-Object System.Collections.ArrayList
function Say {
  param([string]$t)
  Write-Host $t
  try { Add-Content -LiteralPath $report -Value $t -Encoding Default -ErrorAction Stop } catch { }
}
function Head { param([string]$t) ; Say '' ; Say ('==== ' + $t + ' ====') }
function Hit  { param([string]$t) ; [void]$script:Verdicts.Add($t) ; Say ('  >> ' + $t) }

$startMap = @{ 0 = 'Boot(引导)'; 1 = 'System(系统)'; 2 = 'Auto(自动)'; 3 = 'Manual(手动)'; 4 = 'Disabled(禁用)' }

function Get-SvcState([string]$name) {
  $o = & sc.exe query $name 2>&1 | Out-String
  if ($o -match 'STATE\s+:\s+\d+\s+([A-Z_]+)') { return $Matches[1] }
  return 'NOT_FOUND'
}

Say ('ACE / CMP40HX 排查报告    ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ('计算机: ' + $env:COMPUTERNAME + '    用户: ' + $env:USERNAME + '    管理员: 是')

# ---------------- 1. 系统基本状态 ----------------
Head '1. 系统'
$os = Get-CimInstance Win32_OperatingSystem
$boot = $os.LastBootUpTime
Say ('  系统      : ' + $os.Caption + ' (Build ' + $os.BuildNumber + ')')
Say ('  上次开机  : ' + $boot)
Say ('  已运行    : ' + [int]((Get-Date) - $boot).TotalMinutes + ' 分钟')
Say ('  交互登录用户: ' + (Get-CimInstance Win32_ComputerSystem).UserName)

# ---------------- 2. 开机任务 ----------------
Head '2. 一键包的开机任务（CMP40HX Gen2 PostBind）'
$taskName = 'CMP40HX Gen2 PostBind'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
  $ti = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
  Say ('  存在      : 是    State=' + $task.State)
  Say ('  上次运行  : ' + $ti.LastRunTime + '    上次结果=0x' + ('{0:X}' -f $ti.LastTaskResult))
  Say ('  下次运行  : ' + $ti.NextRunTime)
  foreach ($tr in $task.Triggers) { Say ('  触发器    : ' + $tr.CimClass.CimClassName) }
  foreach ($ac in $task.Actions) { Say ('  动作      : ' + $ac.Execute + ' ' + $ac.Arguments) }
  if ($ti.LastTaskResult -eq 267011) { Hit '开机任务还没跑过（刚注册/被重装）—— 重启一次才会有效果' }
  elseif ($ti.LastTaskResult -ne 0) { Hit ('开机任务上次不是成功退出（rc=0x' + ('{0:X}' -f $ti.LastTaskResult) + '）—— Gen2 这次没落地，且 ACE-BOOT 很可能没被恢复') }
} else {
  Say '  存在      : 否'
  Hit '没找到开机任务 —— 这台机器上没装一键包（或已被卸载）。ACE 的问题就不是本包引起的，按第 7 节的通用项查'
}
$others = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '40HX|CMP|Gen2|ACE-Tray' })
if ($others.Count) {
  foreach ($o in $others) { Say ('  相关任务  : ' + $o.TaskName + '   State=' + $o.State) }
  $v = @($others | Where-Object { $_.TaskName -match 'Bring-up|Retrain' -and $_.State -ne 'Disabled' })
  if ($v.Count) { Hit ('厂商的 Gen2 任务还处于启用状态（' + (($v | Select-Object -ExpandProperty TaskName) -join ', ') + '）—— 它们走"复位显卡"的硬回退路线，会清掉算力并和本包抢；一键包安装时本应禁用它们，请在 任务计划程序 里把它们禁用') }
}

# ---------------- 3. ACE 服务/驱动 ----------------
Head '3. 腾讯 ACE 的服务与驱动（启动类型决定 ACE-BOOT 会不会自己起来）'
$aceSvcs = New-Object System.Collections.ArrayList
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object {
  $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
  if (-not $props) { return }
  $img = [string]$props.ImagePath
  if ($_.PSChildName -match '^ACE' -or $img -match 'AntiCheatExpert') {
    $st = $null
    if ($props.PSObject.Properties.Name -contains 'Start') { $st = [int]$props.Start }
    [void]$aceSvcs.Add([pscustomobject]@{
      Name = $_.PSChildName; Start = $st; StartText = $(if ($st -ne $null -and $startMap.ContainsKey($st)) { $startMap[$st] } else { '?' }); ImagePath = $img
    })
  }
}
if ($aceSvcs.Count -eq 0) {
  Say '  一个都没找到 —— ACE 没装或装坏了（腾讯游戏启动时会自动修复/重装）'
  Hit 'ACE 组件在系统里不存在 —— 与一键包无关；开一次腾讯游戏让 ACE 重新安装，或重装 ACE'
} else {
  foreach ($s in ($aceSvcs | Sort-Object Name)) {
    Say ('  ' + $s.Name.PadRight(22) + ' start=' + $s.StartText.PadRight(16) + ' state=' + (Get-SvcState $s.Name))
    Say ('        路径: ' + $s.ImagePath)
  }
}
$aceBoot = $aceSvcs | Where-Object { $_.Name -eq 'ACE-BOOT' } | Select-Object -First 1
$aceBootState = if ($aceBoot) { Get-SvcState 'ACE-BOOT' } else { 'NOT_FOUND' }
if ($aceBoot) {
  if ($aceBoot.Start -eq 4) { Hit ('ACE-BOOT 的启动类型是 Disabled（禁用）—— 每次开机它都不会加载，ACE 托盘/游戏就会报初始化失败。修：sc config ACE-BOOT start= system 后重启') }
  elseif ($aceBootState -ne 'RUNNING') { Hit ('ACE-BOOT 存在但当前不是 RUNNING（state=' + $aceBootState + '）—— 这是"被停掉但没恢复"的样子；修：sc start ACE-BOOT（-Fix 会自动做）') }
} else {
  if ($aceSvcs.Count -gt 0) { Hit 'ACE-BOOT 这个引导驱动不存在（ACE 组件有其它项，但没有 ACE-BOOT）—— ACE 版本不同或被清掉了' }
}


# --- ACE 驱动文件本身的版本/大小（对比两台机器先比这个，别只比时间） ---
if ($aceBoot -and $aceBoot.ImagePath) {
  $bp = ([string]$aceBoot.ImagePath) -replace '^\\\?\?\\', ''
  if ($bp -match '^\\SystemRoot') { $bp = $bp -replace '^\\SystemRoot', $env:SystemRoot }
  if ($bp -notmatch '^[A-Za-z]:') { Say ('  ACE-BOOT.sys 路径无法解析: ' + $bp) }
  elseif (Test-Path -LiteralPath $bp) {
    $bfi = Get-Item -LiteralPath $bp
    Say ('  ACE-BOOT.sys 文件: ' + [string]$bfi.Length + ' B   修改时间=' + $bfi.LastWriteTime + '   FileVersion=' + $bfi.VersionInfo.FileVersion)
  } else { Say ('  ACE-BOOT.sys 文件读不到: ' + $bp) }
}

# ---------------- 4. ACE 进程 + 与"停止窗口"的时间比对 ----------------
Head '4. ACE 进程（重点看托盘在哪个会话、什么时候启动的）'
$aceProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -match 'AntiCheatExpert' -or $_.Name -match '^(ACE-|SGuard)' })
if ($aceProcs.Count -eq 0) {
  Say '  没有任何 ACE 进程在跑'
  Hit 'ACE 进程一个都不在 —— 如果游戏也报初始化失败，先重启一次电脑；仍不行按第 7 节查杀软/重装 ACE'
} else {
  foreach ($p in $aceProcs) {
    Say ('  ' + $p.Name.PadRight(20) + ' PID=' + $p.ProcessId + ' session=' + $p.SessionId + ' 启动=' + $p.CreationDate)
  }
}
$trayProc = $aceProcs | Where-Object { $_.Name -match 'Tray' } | Select-Object -First 1
if ($trayProc -and $trayProc.SessionId -eq 0) {
  Hit 'ACE 托盘跑在 session 0（系统会话）—— 桌面看不到图标、也初始化不完整。这是"以 SYSTEM 身份启动托盘"造成的样子'
}

$pbLog = Join-Path $env:ProgramData 'CMP40HXGen2\windows\logs\postbind.log'
$win = $null
if (Test-Path -LiteralPath $pbLog) {
  $pl = @(Get-Content -LiteralPath $pbLog -Encoding Default -ErrorAction SilentlyContinue)
  $si = -1
  for ($i = $pl.Count - 1; $i -ge 0; $i--) { if ($pl[$i] -match 'PostBind start\s+(\d{4})/(\d{1,2})/(\d{1,2})') { $si = $i; break } }
  if ($si -ge 0) {
    $base = Get-Date -Year ([int]$Matches[1]) -Month ([int]$Matches[2]) -Day ([int]$Matches[3]) -Hour 0 -Minute 0 -Second 0
    $stopT = $null; $rsmT = $null; $exitC = $null
    for ($j = $si; $j -lt $pl.Count; $j++) {
      $l = $pl[$j]
      if ($l -match '\[(\d{2}):(\d{2}):(\d{2})\]') {
        $ts = $base.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2]).AddSeconds([int]$Matches[3])
        if (-not $stopT -and $l -match 'ACE-BOOT 已停止') { $stopT = $ts }
        if (-not $rsmT -and $l -match 'ACE-BOOT 已恢复运行') { $rsmT = $ts }
      }
      if ($l -match 'PostBind EXIT=(\d+)') { $exitC = [int]$Matches[1] }
    }
    $win = [pscustomobject]@{ Date = $base; Stop = $stopT; Resume = $rsmT; Exit = $exitC }
    Say ''
    Say ('  最近一次开机任务的时间线（' + $base.ToString('yyyy-MM-dd') + '）:')
    Say ('    停 ACE-BOOT : ' + $(if ($stopT) { $stopT.ToString('HH:mm:ss') } else { '（日志里没有"已停止"行 —— 说明脚本没停它，或日志被截断）' }))
    Say ('    恢复 ACE-BOOT: ' + $(if ($rsmT) { $rsmT.ToString('HH:mm:ss') } else { '（没有"已恢复运行"行！）' }))
    Say ('    任务退出码   : ' + $(if ($exitC -ne $null) { $exitC } else { '（没找到 EXIT= 行）' }))
    if ($trayProc -and $stopT -and $rsmT -and $trayProc.CreationDate) {
      $ts0 = $trayProc.CreationDate
      Say ('    托盘启动时刻 : ' + $ts0.ToString('HH:mm:ss'))
      if ($ts0 -ge $stopT -and $ts0 -le $rsmT.AddSeconds(5)) {
        Hit ('竞态成立：ACE 托盘在 ' + $ts0.ToString('HH:mm:ss') + ' 启动，正落在 ACE-BOOT 停掉的窗口(' + $stopT.ToString('HH:mm:ss') + '~' + $rsmT.ToString('HH:mm:ss') + ')里 —— 托盘初始化必然失败。这就是"ACE 弹窗初始化失败"的机理')
      } else {
        Say '    托盘不在停止窗口内启动 —— 这条竞态不成立'
      }
    }
  }
} else {
  Say ('  ' + $pbLog + ' 不存在 —— 这台机器没跑过一键包的开机任务')
}
if ($win -and $win.Stop -and $win.Resume) {
  $exp = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Sort-Object CreationDate)
  if ($exp.Count) {
    $lg = $exp[0].CreationDate
    Say ('  本次登录时刻(explorer 启动) : ' + $lg.ToString('HH:mm:ss') + '   ← 注册表 Run 就是在这前后拉起 ACE 托盘的')
    if ($lg -ge $win.Stop.AddSeconds(-30) -and $lg -le $win.Resume.AddSeconds(60)) {
      Hit ('本次登录与 ACE-BOOT 停窗重叠（停 ' + $win.Stop.ToString('HH:mm:ss') + ' / 恢复 ' + $win.Resume.ToString('HH:mm:ss') + ' / 登录 ' + $lg.ToString('HH:mm:ss') + '）—— 这台机器属于"高风险撞车"：托盘由登录时拉起，撞上窗口就会初始化失败。哪怕现在托盘看着正常（已被重启过），也按第 9 节做根治')
    } else {
      Say '  本次登录不在停窗范围内 —— 这次登录没有撞车'
    }
  }
}

# ---------------- 5. 一键包日志 ----------------
Head '5. 一键包日志（postbind.log 尾部 / last.log 判据行 / ace-state.json）'
if (Test-Path -LiteralPath $pbLog) {
  Say ('  --- ' + $pbLog + ' 尾部 30 行 ---')
  (@(Get-Content -LiteralPath $pbLog -Encoding Default -ErrorAction SilentlyContinue) | Select-Object -Last 30) | ForEach-Object { Say ('  | ' + $_) }
} else { Say '  （无 postbind.log）' }
# ---------------- 5b. 新路径（全程不停 ACE-BOOT）的证据 ----------------
$npLog = Join-Path $env:ProgramData 'CMP40HXGen2\windows\logs\retrain-inpout.log'
if (Test-Path -LiteralPath $npLog) {
  Say ''
  Say ('  --- ' + $npLog + ' 尾部 16 行（新路径：inpoutx64 直写寄存器，不停 ACE）---')
  (@(Get-Content -LiteralPath $npLog -Encoding Default -ErrorAction SilentlyContinue) | Select-Object -Last 16) | ForEach-Object { Say ('  | ' + $_) }
  $npAll = @(Get-Content -LiteralPath $npLog -Encoding Default -ErrorAction SilentlyContinue)
  $npPass = @($npAll | Where-Object { $_ -match 'PASS: physical Gen2 x16 reached' })
  $npBad  = @($npAll | Where-Object { $_ -match 'GUARD = FAIL|REFUSE|EXIT=[1-9]' })
  Say ('  新路径成功次数 = ' + $npPass.Count + '   异常行 = ' + $npBad.Count)
  if ($npPass.Count -eq 0) {
    Hit '新路径工具从未成功过 —— 这台机器还在走老办法（停 ACE-BOOT → 重训 → 恢复 ACE-BOOT），所以每次开机后腾讯游戏都会要求“重新安装并重启”。根治：升级到新版包（含 40hx-retrain-inpout.ps1 + inpoutx64.sys），跑 -Mode Repair 后重启'
  }
} else { Say '  （无 retrain-inpout.log —— 这台机器没装新版包的新路径，仍在用停 ACE 的老办法）' }
if (Test-Path -LiteralPath $pbLog) {
  $pbAll = @(Get-Content -LiteralPath $pbLog -Encoding Default -ErrorAction SilentlyContinue)
  $fb  = @($pbAll | Where-Object { $_ -match 'falling back to the legacy|NewPath EXIT=[1-9]' })
  $npOk = @($pbAll | Where-Object { $_ -match 'PASS: Gen2 reached on the new path' })
  Say ('  postbind.log：新路径成功 ' + $npOk.Count + ' 次，回落老路径 ' + $fb.Count + ' 次')
  if ($fb.Count) {
    Hit ('有 ' + $fb.Count + ' 次“新路径失败 → 回落老路径”：每次回落都会停一次 ACE-BOOT，那一轮开机里强制预启动模式的腾讯游戏就进不去（要求重启）。最近一条：' + $fb[-1].Trim())
  } elseif ($npOk.Count -gt 0) {
    Say '  最近几次开机都走的新路径（ACE-BOOT 全程没停）—— 若游戏仍报预启动模式，问题不在本包，按第 9 节通用项查'
  }
}

$lastLog = Join-Path $env:ProgramData 'CMP40HXGen2\windows\logs\last.log'
if (Test-Path -LiteralPath $lastLog) {
  Say '  --- last.log 关键行 ---'
  (Get-Content -LiteralPath $lastLog -Encoding Default -ErrorAction SilentlyContinue | Select-String -Pattern 'GUARD=|PASS|ERROR|FATAL|EXIT=|ThrottleStop|WinRing') | ForEach-Object { Say ('  | ' + $_.Line.Trim()) }
} else { Say '  （无 last.log）' }
$stateFile = Join-Path $env:ProgramData 'CMP40HXGen2\windows\logs\ace-state.json'
if (Test-Path -LiteralPath $stateFile) {
  Say '  --- ace-state.json ---'
  (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8) -split "`r?`n" | ForEach-Object { if ($_.Trim()) { Say ('  | ' + $_.Trim()) } }
} else { Say '  （无 ace-state.json）' }

# ---------------- 6. 事件日志 ----------------
Head '6. 近 2 天系统日志里与 ACE / 驱动加载有关的记录'
try {
  $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddDays(-2) } -ErrorAction SilentlyContinue |
        Where-Object {
          ($_.Id -in @(7000, 7001, 7023, 7026, 7045)) -or
          (($_.ProviderName -notmatch 'FilterManager') -and $_.Message -match 'ACE-BOOT|ACE-Tray|AntiCheatExpert|ThrottleStop|WinRing0')
        } |
        Select-Object -First 40
  if ($ev) { foreach ($e in $ev) { Say ('  [' + $e.TimeCreated.ToString('MM-dd HH:mm:ss') + '] ' + $e.Id + ' ' + $e.ProviderName + ' :: ' + (($e.Message -replace "`r?`n", ' | '))) } }
  else { Say '  没有相关记录' }
} catch { Say ('  读取失败: ' + $_.Exception.Message) }

# ---------------- 7. 杀软 / 其它反作弊 ----------------
Head '7. 杀软与其它反作弊（ACE 初始化失败的另一个常见原因）'
$av = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'HipsTray|wsctrl|HipsDaemon|MsMpEng|360|QQPCTray|kav|avp|ZhuDongFangYu' })
if ($av.Count) { Say ('  在跑的杀软进程: ' + (($av | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')) } else { Say '  没检测到常见杀软进程' }
$otherAc = @('vgk','vgc','EasyAntiCheat','BEDaisy','BEService','XIGNCODE','nProtect','TenProtect','SGuard')
$hit = New-Object System.Collections.ArrayList
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object {
  $n = $_.PSChildName
  foreach ($k in $otherAc) { if ($n -eq $k -or $n -like ($k + '*')) { if (-not $hit.Contains($n)) { [void]$hit.Add($n) }; break } }
}
if ($hit.Count) { Say ('  其它反作弊服务: ' + ($hit -join ', ')) } else { Say '  没发现其它厂商反作弊服务' }
Say '  提示：火绒/其它杀软把 ThrottleStop.sys 判成 Exploit/Vulndriver 会秒删（属预期）—— 但只要 ACE-BOOT 正常、托盘正常，这与"ACE 初始化失败"无关。'

# ---------------- 8. ACE 安装目录 ----------------
Head '8. ACE 安装目录里的关键文件'
$aceDirs = @()
foreach ($d in @("$env:ProgramFiles\AntiCheatExpert", "${env:ProgramFiles(x86)}\AntiCheatExpert", "$env:ProgramData\AntiCheatExpert")) {
  if (Test-Path -LiteralPath $d) { $aceDirs += $d }
}
if ($aceDirs.Count -eq 0) { Say '  没找到 ACE 目录' }
foreach ($d in $aceDirs) {
  Say ('  --- ' + $d + ' ---')
  Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
    Say ('  | ' + $_.Name.PadRight(34) + ' ' + ([string]$_.Length).PadLeft(10) + '  ' + $_.LastWriteTime)
  }
  Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.sys' } | ForEach-Object {
    Say ('  ~ ' + $_.Name.PadRight(34) + ' FileVersion=' + $_.VersionInfo.FileVersion)
  }

  Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-2) } | ForEach-Object {
    Say ('  ! 近 2 天被改动过: ' + $_.Name + '  ' + $_.LastWriteTime)
  }
}

# ---------------- 9. 结论 ----------------
Head '9. 结论与建议'
if ($script:Verdicts.Count -eq 0) {
  Say '  没命中任何已知判据 —— 请把本报告整份发回，我按原始证据继续判。'
} else {
  $n = 1
  foreach ($v in $script:Verdicts) { Say ('  [' + $n + '] ' + $v) ; $n++ }
  Say ''
  Say '  处理顺序建议：'
  Say '   1) 先只想"让 ACE 立刻能用"：杀掉 ACE-Tray 再重新启动它（用户会话里启动），或直接重启电脑。'
  Say '   2) 若 ACE-BOOT 是 Disabled：改回 system 并启动，然后重启。'
  Say '  如果第 5b 节显示【新路径从未成功 / 回落过老路径】：这就是腾讯游戏要求【重新安装并重启】的成因，用新版包（含 40hx-retrain-inpout.ps1 + inpoutx64.sys）跑一次 -Mode Repair 再重启即可根治。'

  Say '   3) 想"以后每次开机都不再犯"：用带自愈的新版 RunPostBind.cmd / ACE-Toggle.ps1（Hermes 已备好，覆盖后跑一次 Repair）。'
  Say '   4) 想同时确认算力 + Gen2 没有掉：跑本包里的 状态自检.bat（不用管理员，出"全绿"即正常）。'
}

# ---------------- 10. -Fix ----------------
if ($Fix) {
  Head '10. 执行修复（-Fix）'
  if ($aceBoot) {
    if ($aceBoot.Start -eq 4) {
      Say '  ACE-BOOT 启动类型改回 System ...'
      & sc.exe config ACE-BOOT start= system | ForEach-Object { Say ('  | ' + $_) }
    }
    $st = Get-SvcState 'ACE-BOOT'
    if ($st -ne 'RUNNING') {
      Say '  ACE-BOOT 当前 ' + $st + '，尝试启动 ...'
      & sc.exe start ACE-BOOT | ForEach-Object { Say ('  | ' + $_) }
      Start-Sleep -Seconds 3
      Say ('  启动后状态: ' + (Get-SvcState 'ACE-BOOT'))
    } else { Say '  ACE-BOOT 已在运行' }
  }

  $trayExe = $null
  foreach ($c in @("$env:ProgramFiles\AntiCheatExpert\ACE-Tray.exe", "${env:ProgramFiles(x86)}\AntiCheatExpert\ACE-Tray.exe")) {
    if (Test-Path -LiteralPath $c) { $trayExe = $c; break }
  }
  if (-not $trayExe) {
    $tp = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Tray' -and $_.ExecutablePath -match 'AntiCheatExpert' })
    if ($tp.Count) { $trayExe = $tp[0].ExecutablePath }
  }
  if (-not $trayExe) { Say '  找不到 ACE 托盘可执行文件 —— 跳过托盘重启' }
  else {
    Say ('  重启托盘: ' + $trayExe)
    foreach ($t in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Tray' -and $_.ExecutablePath -match 'AntiCheatExpert' })) {
      Say ('    结束旧托盘 PID=' + $t.ProcessId + ' session=' + $t.SessionId)
      Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    $iuser = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $iuser) { Say '    当前没有交互登录用户 —— 托盘会在你下次登录时由 HKLM Run 自动拉起（现在不用管）' }
    else {
      $tn = 'ACE-Tray Restore'
      try {
        $act = New-ScheduledTaskAction -Execute $trayExe
        $pri = New-ScheduledTaskPrincipal -UserId $iuser -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $tn -Action $act -Principal $pri -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $tn -ErrorAction Stop
        Start-Sleep -Seconds 6
        $newTray = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Tray' -and $_.ExecutablePath -match 'AntiCheatExpert' })
        if ($newTray.Count) {
          foreach ($t in $newTray) { Say ('    新托盘 PID=' + $t.ProcessId + ' session=' + $t.SessionId) }
          if (@($newTray | Where-Object { $_.SessionId -ne 0 }).Count -gt 0) { Say '    成功：托盘已在用户会话运行（桌面右下角应能看到 ACE 图标）' }
          else { Say '    警告：托盘仍在 session 0 —— 请注销重登或重启' }
        } else { Say '    托盘没起来 —— 请重启电脑让 HKLM Run 拉起它' }
        # 用完即清（实测：Unregister 不会杀掉它已经启动的托盘进程）
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
        $aliveTray = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Tray' -and $_.ExecutablePath -match 'AntiCheatExpert' })
        Say ('    临时任务已清理；托盘进程存活=' + ($aliveTray.Count -gt 0))
      } catch { Say ('    托盘重启失败: ' + $_.Exception.Message) }
    }
  }
  $vTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'Bring-up|Retrain' -and $_.State -ne 'Disabled' })
  foreach ($x in $vTasks) {
    Disable-ScheduledTask -TaskName $x.TaskName -ErrorAction SilentlyContinue | Out-Null
    Say ('  已禁用厂商任务: ' + $x.TaskName + '（它走复位显卡路线，会清掉算力）')
  }
  Say ''
  Say '  修复动作结束。若 ACE 仍报初始化失败，把本报告发回。'
}

Say ''
Say ('报告文件: ' + $report)
Say '把这份报告整份发回给 Hermes 即可（含上面的第 2/3/4/5/6 节最有价值）。'
try { Start-Process notepad.exe -ArgumentList ('"' + $report + '"') } catch { }
