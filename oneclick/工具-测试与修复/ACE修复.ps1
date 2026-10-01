# ============================================================
#  ACE 体检 / 修复（腾讯反作弊起不来时用）
#  症状：解锁成功后玩游戏提示 ACE 相关错误 / 反作弊初始化失败 / 游戏进不去
#  常见真因（2026-10-01 客户实测）：开机任务旧版逻辑只在 Gen2 成功时才恢复 ACE-BOOT，
#    一旦某一轮重训失败，ACE-BOOT 就永久停在 STOPPED → 游戏里 ACE 起不来。
#  用法：
#    ACE修复.cmd                  → 只读体检（不需要管理员），桌面出报告
#    ACE修复.cmd /fix             → 修复（自动提权）：恢复 ACE-BOOT + 拉起 ACE 托盘
#    ACE修复.cmd /acefirst on     → 打开「ACE 优先模式」：开机任务永不停止 ACE-BOOT
#    ACE修复.cmd /acefirst off    → 关闭该模式（恢复默认：新路径不通才回落旧路径）
# ============================================================
param(
  [switch]$Fix,
  [string]$AceFirst = ''
)
$ErrorActionPreference='Continue'
$here = if($PSScriptRoot){ $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# 本脚本位于「工具-测试与修复\」下 → 向上找包根（内含 payload\windows 的那一层）
if(-not (Test-Path (Join-Path $here 'payload\windows'))){
  $p2 = $here
  for($i=0; $i -lt 3; $i++){
    $p2 = Split-Path -Parent $p2
    if(-not $p2){ break }
    if(Test-Path (Join-Path $p2 'payload\windows')){ $here = $p2; break }
  }
}
$desk=[Environment]::GetFolderPath('Desktop'); if(-not $desk){ $desk='C:\Users\Public\Desktop' }
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$out=Join-Path $desk ('40HX-ACE体检-' + $stamp + '.txt')
$sb=New-Object System.Text.StringBuilder
function W  { param([string]$s='') [void]$sb.AppendLine($s) }
function WB { param([string]$s='') Write-Host $s; [void]$sb.AppendLine($s) }
function Save { try { $sb.ToString() | Out-File -Encoding utf8 $out } catch {} }

$ProgDataWin = 'C:\ProgramData\CMP40HXGen2\windows'
$StateFile   = Join-Path $ProgDataWin 'logs\ace-state.json'
$PostLog     = Join-Path $ProgDataWin 'logs\postbind.log'
$Marker      = 'C:\ProgramData\CMP40HXGen2\NO_ACE_TOGGLE'
$toggleDeployed = Join-Path $ProgDataWin 'ACE-Toggle.ps1'
$togglePkg      = Join-Path $here 'payload\windows\ACE-Toggle.ps1'
$toggle = if(Test-Path $toggleDeployed){ $toggleDeployed } else { $togglePkg }

function Is-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-SvcByPath {
  # 2026-10-01 两次踩坑后的结论：**WMI 不可靠** —— Win32_Service 与 Win32_SystemDriver
  # 都查不到某个以相对路径(ImagePath='System32\drivers\X.sys')注册的内核驱动服务
  # （本机实测：sc qc 有 ThrottleStop，WMI 440 个驱动里 0 命中）。所以直接读 SCM 的真实数据源：注册表。
  # 好处：能发现**任何名字**的服务（含别人换了名字指向同一个 .sys 的），这正是 ACE 弹窗的排查要点。
  param([string]$Pattern)
  $out = @()
  foreach($k in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)){
    try {
      $ip = (Get-ItemProperty -LiteralPath $k.PSPath -Name ImagePath -ErrorAction Stop).ImagePath
      if('' + $ip -match $Pattern){
        $pr = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        $out += [pscustomobject]@{ Name = $k.PSChildName; ImagePath = $ip; Start = $pr.Start; Type = $pr.Type }
      }
    } catch {}
  }
  ,@($out)
}
function Get-AceComponents {
  # 注意：**不能用 'ACE' 裸匹配** —— 会把 "Human Interf-ACE Device Service"(hidserv)、
  # "jhi_service"/"nsi"(都含 Interface) 全捞进来（2026-10-01 元测试实测踩到）。
  Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
    ($_.PathName -match 'AntiCheatExpert|ACE-BOOT|ACE-GAME|ACE-SVC|ACE-Guard|SGuard') -or
    ($_.Name -match '^(ACE-BOOT|ACE-GAME|ACE-SVC|ACE-ADVT|ACE-Guard|AntiCheatExpert)') -or
    ($_.DisplayName -match 'AntiCheatExpert|反作弊|腾讯游戏安全')
  } | Where-Object { $_ } | Sort-Object Name
}

WB '============================================================'
WB ' 40HX：腾讯 ACE 反作弊体检（只读）'
WB (' 时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   机器: ' + $env:COMPUTERNAME + '   管理员: ' + (Is-Admin))
WB '============================================================'
WB ''

# ---------- 1) ACE 组件现状 ----------
WB '==== 1) ACE 组件现状（服务）===='
$comps = @(Get-AceComponents | Where-Object { $_ })
if($comps.Count -eq 0){
  WB '  !! 没有找到任何 ACE 组件（AntiCheatExpert / ACE-* 服务）'
  WB '     → 说明 ACE 组件缺失或被卸载：在游戏客户端里点「修复/重新安装」由游戏重新部署 ACE'
} else {
  foreach($c in $comps){
    $flag = if($c.State -eq 'Running'){ '  ' } else { '  ★' }
    W ($flag + ' ' + $c.Name + '   显示名=' + $c.DisplayName)
    W ('     启动类型=' + $c.StartMode + '   状态=' + $c.State + '   账号=' + $c.StartName)
    W ('     路径=' + $c.PathName)
    WB ($flag + ' ' + $c.Name + '   ' + $c.StartMode + '   ' + $c.State)
  }
}
WB ''
$bootComp = $comps | Where-Object { $_.Name -eq 'ACE-BOOT' } | Select-Object -First 1
if(-not $bootComp){ $bootComp = $comps | Where-Object { $_.PathName -match 'AntiCheatExpert' -and $_.Name -match 'BOOT' } | Select-Object -First 1 }

# ---------- 2) ACE 托盘进程 ----------
WB '==== 2) ACE 托盘进程（用户态）===='
$trays=@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(ACE-Tray|ACE-ADVT|SGuard|AntiCheat)' })
if($trays.Count -eq 0){ WB '  （没有 ACE 托盘进程 —— 一般重新登录一次会自动拉起，或用 /fix 拉起）' }
else { foreach($t in $trays){ WB ('  PID=' + $t.Id + '  ' + $t.ProcessName + '   启动于 ' + $t.StartTime) } }
WB ''

# ---------- 3) 有无「停了没恢复」的记录 ----------
WB '==== 3) 我们的停机记录（ace-state.json）===='
if(Test-Path $StateFile){
  try {
    $st = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    W ('  原始内容: ' + ($st | ConvertTo-Json -Compress))
    WB ('  记录的原始启动类型: ' + $st.Name + ' start=' + $st.StartMode + ' (' + $st.StartKeyword + ')')
    WB ('  停过: ' + $st.Stopped + '   停止时刻: ' + $st.Time + '   恢复时刻: ' + $(if($st.ResumedAt){$st.ResumedAt}else{'(无)'}) + '   恢复结果: ' + $(if($st.Resumed){$st.Resumed}else{'未记录/失败'}))
    if($st.Stopped -eq $true -and -not $st.Resumed){
      WB '  ★ 有一次停机**没有恢复成功**的记录 —— 这正是 ACE 起不来的典型原因'
    }
  } catch { WB ('  读取失败: ' + $_.Exception.Message) }
} else { WB '  （没有记录文件 —— 说明本机从未被我们停过 ACE）' }

# ---------- 4) 开机任务日志 ----------
WB ''
WB '==== 4) 开机任务日志（postbind.log 末尾关键行）===='
if(Test-Path $PostLog){
  $lines = @(Get-Content -LiteralPath $PostLog -Tail 60 -Encoding UTF8 -ErrorAction SilentlyContinue)
  foreach($l in $lines){
    if($l -match 'NewPath EXIT|PostBind EXIT|PASS:|FAIL:|ACE|falling back|ACE-PRIORITY|heal|attempt|NewPath start'){
      WB ('  ' + ($l -replace '\s+',' ').Trim())
    }
  }
} else { WB ('  （没有 ' + $PostLog + '）') }

# ---------- 5) 事件日志 ----------
WB ''
WB '==== 5) 近 3 天与 ACE/反作弊相关的事件日志 ===='
$found=0
try {
  $ev = @(Get-WinEvent -FilterHashtable @{LogName=@('System','Application'); StartTime=(Get-Date).AddDays(-3)} -MaxEvents 600 -ErrorAction SilentlyContinue)
  foreach($e in $ev){
    $m = '' + $e.Message
    if($e.ProviderName -match 'AntiCheat|ACE|SGuard|Tencent|腾讯' -or $m -match 'AntiCheat|ACE-|反作弊|安全组件'){
      $found++
      if($found -le 25){ WB ('  [' + $e.TimeCreated.ToString('MM-dd HH:mm:ss') + '] ' + $e.LevelDisplayName + ' ' + $e.ProviderName + ' ID=' + $e.Id + ' :: ' + (($m -replace '\s+',' ').Trim().Substring(0, [Math]::Min(160, ($m -replace '\s+',' ').Trim().Length)))) }
    }
  }
} catch { WB ('  读取失败: ' + $_.Exception.Message) }
if($found -eq 0){ WB '  （没有相关事件）' } else { WB ('  共 ' + $found + ' 条') }

# ---------- 6) 我们自己的东西 ----------
WB ''
WB '==== 6) 本包相关状态 ===='
foreach($s in @('ThrottleStop','WinRing0_1_2_0','WinRing0_40HX')){
  $q = (sc.exe qc $s 2>&1 | Out-String)
  if($q -match 'SERVICE_NAME'){
    $m1=[regex]::Match($q,'START_TYPE\s*:\s*\d+\s+\S+'); $m2=[regex]::Match($q,'BINARY_PATH_NAME\s*:\s*(\S+)')
    $st=(sc.exe query $s 2>&1 | Out-String); $m3=[regex]::Match($st,'STATE\s*:\s*\d+\s+\S+')
    WB ('  ' + $s + '  ' + $m1.Value + '  ' + $m3.Value)
  } else { WB ('  ' + $s + '  （不存在）') }
}
$task = @(Get-ScheduledTask -TaskName '*CMP40HX*' -ErrorAction SilentlyContinue)
if($task.Count){ foreach($t in $task){ WB ('  开机任务: ' + $t.TaskName + '  ' + $t.State) } } else { WB '  开机任务:（未找到）' }
WB ('  ACE 优先模式: ' + $(if(Test-Path $Marker){'已开启（开机任务永不停止 ACE-BOOT）'}else{'未开启（默认：新路径不通才回落旧路径）'}))
WB ('  脚本: ' + $(if(Test-Path $toggle){$toggle}else{'（找不到 ACE-Toggle.ps1）'}))

# ---------- 6b) 谁在加载 ThrottleStop？ + 部署脚本版本 ----------
WB ''
WB '==== 6b) ThrottleStop 溯源（ACE 弹窗就是指它）===='
$tsSvc = Get-SvcByPath 'ThrottleStop'
if($tsSvc.Count -eq 0){ WB '  指向 ThrottleStop.sys 的服务: 无（名字不限）' }
else { foreach($s in $tsSvc){ WB ('  ★ 服务 ' + $s.Name + '  ' + $s.StartMode + '  ' + $s.State + '  → ' + $s.PathName) } }
$tsFile='C:\Windows\System32\drivers\ThrottleStop.sys'
if(Test-Path $tsFile){ WB ('  驱动文件: 存在  ' + (Get-Item $tsFile).Length + ' B  修改于 ' + (Get-Item $tsFile).LastWriteTime) } else { WB '  驱动文件: 不存在（已退场）' }
$tsTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $a = ($_.Actions | ForEach-Object { ('' + $_.Execute) + ' ' + ('' + $_.Arguments) }) -join ' '; $a -match 'ThrottleStop|40HX|AutoRetrain|RunPostBind|CMP40HX' } | Where-Object { $_ })
if($tsTasks.Count -eq 0){ WB '  相关计划任务: 无' }
else { foreach($t in $tsTasks){ $a=($t.Actions | ForEach-Object { ('' + $_.Execute) + ' ' + ('' + $_.Arguments) }) -join ' | '; WB ('  任务 ' + $t.TaskName + '  ' + $t.State + '  → ' + $a) } }
$script:foundAutorun = $false
foreach($rk in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')){
  try {
    $p=Get-ItemProperty -Path $rk -ErrorAction Stop
    foreach($n in $p.PSObject.Properties){
      if($n.Name -match '^PS'){ continue }
      if(('' + $n.Value) -match 'ThrottleStop|40HX|AutoRetrain|CMP40HX'){
        $script:foundAutorun = $true
        WB ('  ★ 自启项 ' + $rk.Split('\')[0] + '\Run → ' + $n.Name + ' = ' + $n.Value)
        WB '    （Run 里的项**每次登录都会执行**；名字叫什么无关紧要 —— 这就是"开机/登录就弹窗"的常见来源）'
      }
    }
  } catch {}
}
# 部署的开机任务脚本是新版还是旧版？（决定性判据）
$dep = Join-Path $ProgDataWin 'RunPostBind.cmd'
if(Test-Path $dep){
  $raw = Get-Content -LiteralPath $dep -Raw -Encoding UTF8
  $isNew = $raw -match 'ThrottleStop 退场'
  $hasOldCreate = $raw -match 'heal: create service ThrottleStop'
  WB ('  部署的开机脚本: ' + $(if($isNew){'新版（含 ThrottleStop 退场）'}else{'★ 旧版！还在每轮创建 ThrottleStop'}))
  if($hasOldCreate){ WB '    ★ 仍含 heal: create service ThrottleStop（旧逻辑残留）' }
  WB ('    备份文件: ' + ((@(Get-ChildItem $ProgDataWin -Filter 'RunPostBind.cmd.bak-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', ')))
} else { WB ('  部署的开机脚本: 没找到 ' + $dep) }
# 最近一次开机的 postbind 关键行里有没有 throttle / legacy 回落
if(Test-Path $PostLog){
  $tl = @(Get-Content -LiteralPath $PostLog -Tail 80 -Encoding UTF8 -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'throttle|legacy|falling back|create service ThrottleStop|NewPath EXIT|ACE-PRIORITY' }
  if($tl){ WB '  最近开机里与 ThrottleStop / 回落相关的行:'; foreach($l in $tl){ WB ('    ' + ($l -replace '\s+',' ').Trim()) } }
  else { WB '  最近开机日志里没有 throttle / legacy 回落痕迹 → 说明不是我们脚本在加载它' }
}
WB ''
# ---------- 7) 结论 ----------
WB ''
WB '==== 7) 结论 ===='
if($comps.Count -eq 0){
  WB '  ACE 组件不在本机 → 请在游戏客户端里点「修复 / 重新安装」让游戏重新部署 ACE'
} elseif($bootComp -and $bootComp.State -ne 'Running'){
  WB ('  ★ 根因：ACE 引导驱动 ' + $bootComp.Name + ' 当前是 ' + $bootComp.State + '（应为 Running）')
  WB '     典型成因：旧版开机任务只在 Gen2 成功时才恢复 ACE-BOOT，某轮失败后就一直停着。'
  WB '     处理：跑「ACE修复.cmd /fix」（会自动提权恢复），完成后建议重启一次。'
} elseif($bootComp) {
  WB ('  ACE 引导驱动 ' + $bootComp.Name + ' 在运行（' + $bootComp.State + '）。若游戏仍报错：')
  WB '   ① 把游戏里的**报错原文/错误码**发回（不同错误码对应不同处理）'
  WB '   ② 在游戏客户端里点「修复」，让游戏重新部署 ACE 组件'
  WB '   ③ 若报的是「环境异常/检测到非法程序」这类，属于反作弊判定，按下面第 8 节处理'
} elseif($script:foundAutorun){
  WB '  ★ 发现会**自动加载/重装** 40HX 相关驱动的自启项（见 6b 节）—— 这是「开机/登录就弹 ACE 兼容性」的最常见来源。'
  WB '     处理：跑 ACE修复.cmd /fix（会把这些自启项移除并留档），然后重启。'
} else {
  WB '  有 ACE 组件，但**没找到 ACE 引导驱动（ACE-BOOT）**：'
  WB '   多数情况下它只在该游戏启动时才被部署/加载 → 先在游戏里复现一次报错，再跑本体检'
  WB '   同时把游戏里的**报错原文/错误码**发回，并可在游戏客户端点「修复」重新部署 ACE 组件'
}
WB ''
WB '==== 8) 如果 ACE 报的是「环境异常 / 检测到第三方程序」 ===='
WB '  那不是 ACE 组件坏了，而是判定环境被改造。可选：'
WB '  ① ACE 优先模式：ACE修复.cmd /acefirst on  →  开机任务永不停止 ACE-BOOT（代价：新路径不通时本轮不落地 Gen2）'
WB '  ② 让解锁驱动不在游戏时驻留：本包只在开机后十几秒内加载工具驱动，跑完即清理（日志里 drivers cleaned）'
WB '  ③ 若仍被判定，只能二选一：这台机器上「玩该腾讯游戏」或「用 Gen2 解锁」（换一张卡玩 / 换个机器玩）'
WB '  注意：不要使用任何第三方「过 ACE / 破解反作弊」工具 —— 有封号风险，本包不做这件事。'
WB ''

# ---------- 动作 ----------
if($AceFirst -ne ''){
  if($AceFirst -notin @('on','off')){ WB ('  用法错误: -AceFirst 只能是 on / off'); Save; exit 1 }
  $dir=Split-Path -Parent $Marker
  if($AceFirst -eq 'on'){
    if(Is-Admin){ if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }; Set-Content -LiteralPath $Marker -Value ('ACE priority mode enabled ' + (Get-Date -Format 's')) -Encoding UTF8 -Force; WB ('  [OK] 已开启 ACE 优先模式: ' + $Marker) }
    else { WB '  [X] 需要管理员权限（它会写 C:\ProgramData）' }
  } else {
    if(Is-Admin){ if(Test-Path $Marker){ Remove-Item -LiteralPath $Marker -Force }; WB '  [OK] 已关闭 ACE 优先模式' }
    else { WB '  [X] 需要管理员权限' }
  }
  WB '  注意：该模式由开机任务脚本 RunPostBind.cmd 读取 —— 请先用安装器 Repair 一次，把新版 RunPostBind.cmd 铺到 C:\ProgramData\CMP40HXGen2\windows\'
  Save; if(-not $env:NO_PAUSE){ if($Host.Name -eq 'ConsoleHost'){ Write-Host ''; Read-Host '按回车退出' } }; exit 0
}

if($Fix){
  if(-not (Is-Admin)){
    WB ''
    WB '  -Fix 需要管理员权限 → 正在请求提权（会弹 UAC，请点“是”）...'
    Save
    try {
      Start-Process powershell -Verb RunAs -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Fix')
      WB '  提权窗口已结束 —— 请看它生成的报告（桌面 40HX-ACE体检-*.txt）'
    } catch { WB ('  [X] 提权失败: ' + $_.Exception.Message) }
    Save; exit 0
  }
  WB ''
  WB '==== 9) 执行修复 ===='

  # ---- 9.0) 先把「开机任务脚本」升级到包内新版 -------------------------------------
  # 新版修了两件事：① ACE 的恢复不再依赖 Gen2 是否成功（旧版漏了 RC!=0 路径，
  # 会把 ACE-BOOT 永久停在 STOPPED）；② ThrottleStop 退场（它加载着会让腾讯 ACE-BOOT 报
  # 「检测到与游戏可能存在兼容问题的软件程序加载: ThrottleStop.sys」）。
  $pkgCmd = Join-Path $here 'payload\windows\RunPostBind.cmd'
  $deployedCmd = Join-Path $ProgDataWin 'RunPostBind.cmd'
  $dirty = $false
  if(-not (Test-Path $deployedCmd)){ WB ('  [0] 没找到 ' + $deployedCmd + ' —— 跳过（请先跑一次安装器）'); $dirty = $true }
  elseif(-not (Test-Path $pkgCmd)){ WB ('  [0] 包内缺少 payload\windows\RunPostBind.cmd —— 跳过升级') ; $dirty = $true }
  else {
    # 安全前提：两边的「驱动源行」必须一致，说明本机没有被改写过的机器专属内容
    $getSrc = { param($f) $l = (Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_ -match 'for %%S in \(' } | Select-Object -First 1); if($l){ $l.Trim() } else { '' } }
    $srcA = & $getSrc $deployedCmd; $srcB = & $getSrc $pkgCmd
    if($srcA -eq $srcB){
      $bak = $deployedCmd + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
      Copy-Item -LiteralPath $deployedCmd -Destination $bak -Force
      Copy-Item -LiteralPath $pkgCmd -Destination $deployedCmd -Force
      WB ('  [0] 开机任务脚本已整份升级为包内新版（备份: ' + (Split-Path -Leaf $bak) + '）')
      # 校验：新文件里必须真的包含两处关键修复
      $nb = Get-Content -LiteralPath $deployedCmd -Raw -Encoding UTF8
      WB ('       - ACE 无条件恢复: ' + ($nb -notmatch 'if "!RC!"=="0" if "!ACE_STOPPED!"=="1"'))
      WB ('       - ThrottleStop 退场: ' + ($nb -match 'start= disabled'))
    } else {
      # 本机那份被改写过的行要保住 → 用「整份替换 + 回填本机专属行」的合并法
      WB '  [0] 本机 RunPostBind.cmd 的驱动源行与包内不同（被安装器改写过）→ 整份替换后回填本机那行'
      $bak = $deployedCmd + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
      Copy-Item -LiteralPath $deployedCmd -Destination $bak -Force
      $bytes = [System.IO.File]::ReadAllBytes($pkgCmd)
      $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
      $nt = if($hasBom){ [System.Text.Encoding]::UTF8.GetString($bytes,3,$bytes.Length-3) } else { [System.Text.Encoding]::UTF8.GetString($bytes) }
      $nt = $nt.Replace("`r`n","`n")
      $merged = $false
      if($srcA -ne ''){
        $pkgLine = & $getSrc $pkgCmd
        if($pkgLine -ne '' -and $nt.Contains($pkgLine)){ $nt = $nt.Replace($pkgLine, $srcA); $merged = $true }
      }
      if($merged){
        $outB = [System.Text.Encoding]::UTF8.GetBytes($nt.Replace("`n","`r`n"))
        if($hasBom){ $outB = @([byte]0xEF,[byte]0xBB,[byte]0xBF) + $outB }
        [System.IO.File]::WriteAllBytes($deployedCmd, $outB)
        WB ('      已合并写入（备份: ' + (Split-Path -Leaf $bak) + '）；本机驱动源行已回填: ' + $merged)
        $nb = Get-Content -LiteralPath $deployedCmd -Raw -Encoding UTF8
        WB ('       - ACE 无条件恢复: ' + ($nb -notmatch 'if "!RC!"=="0" if "!ACE_STOPPED!"=="1"') + '   ThrottleStop 退场: ' + ($nb -match 'start= disabled'))
      } else {
        Copy-Item -LiteralPath $bak -Destination $deployedCmd -Force
        WB '      [X] 回填失败 → 已还原原文件（请改跑安装器 Repair 升级开机任务脚本）'
      }
    }
  }
  WB ''

  # ---- 9.1) ThrottleStop 退场（ACE 报的就是它）----
  WB '  [1] ThrottleStop 退场（新路径不需要它；加载在内核里会被 ACE-BOOT 判为兼容性问题）'
  $ts = (sc.exe qc ThrottleStop 2>&1 | Out-String)
  if($ts -match 'SERVICE_NAME'){
    $tq = (sc.exe query ThrottleStop 2>&1 | Out-String)
    WB ('      当前: ' + (([regex]::Match($tq,'STATE\s*:\s*\d+\s+\S+').Value)) + '  ' + (([regex]::Match($ts,'START_TYPE\s*:\s*\d+\s+\S+').Value)))
    if($tq -match 'RUNNING'){
      WB '      正在运行 → 停止（卸下内核映像）'
      & sc.exe stop ThrottleStop 2>&1 | ForEach-Object { WB ('        ' + $_) }
      Start-Sleep -Seconds 2
    }
    if($ts -notmatch 'DISABLED'){
      WB '      设为 disabled（不再随开机加载）'
      & sc.exe config ThrottleStop start= disabled 2>&1 | ForEach-Object { WB ('        ' + $_) }
    }
    $tq2 = (sc.exe query ThrottleStop 2>&1 | Out-String)
    WB ('      现在: ' + (([regex]::Match($tq2,'STATE\s*:\s*\d+\s+\S+').Value)))
  } else { WB '      （本机没有 ThrottleStop 服务 —— 无需处理）' }
  # 1b) 彻底退场：把 ThrottleStop.sys 挪走 —— 只要文件还在，**任何**东西（含别的服务名/厂商自启）
  #     都可能去加载它，ACE-BOOT 就会在开机时弹「检测到与游戏可能存在兼容问题的软件程序加载」。
  #     新路径（ECAM + inpoutx64 / WinRing0）完全不需要它，所以挪走最彻底；备份保留可人工还原。
  WB '  [1b] ThrottleStop 彻底退场（把 .sys 挪到备份目录，杜绝任何组件再加载它）'
  try {
    $bkDir = 'C:\ProgramData\CMP40HXGen2\drivers-disabled'
    if(-not (Test-Path $bkDir)){ New-Item -ItemType Directory -Force -Path $bkDir | Out-Null }
    # 先把所有指向它的服务停掉并删除（名字不限）
    $svcs = Get-SvcByPath 'ThrottleStop'
    foreach($sv in $svcs){
      WB ('      服务 ' + $sv.Name + '（' + $sv.StartMode + '/' + $sv.State + '）→ 停止并删除')
      & sc.exe stop $sv.Name 2>&1 | Out-Null
      Start-Sleep -Milliseconds 800
      & sc.exe delete $sv.Name 2>&1 | Out-Null
    }
    if($svcs.Count -eq 0){ WB '      指向它的服务: 无' }
    # 再挪走所有副本（System32 + 两个 heal 源目录）
    $stamp2 = Get-Date -Format 'yyyyMMdd-HHmmss'
    $moved = 0
    foreach($f in @('C:\Windows\System32\drivers\ThrottleStop.sys','C:\ProgramData\CMP40HXGen2\drivers\ThrottleStop.sys','C:\ProgramData\40HXUnlock\drivers\ThrottleStop.sys')){
      if(Test-Path $f){
        $sub = switch -Wildcard ($f) {
          '*System32\drivers*'  { 'system32-drivers' }
          '*CMP40HXGen2*'        { 'progdata-cmp40hxgen2' }
          '*40HXUnlock*'         { 'progdata-40hxunlock' }
          default                { 'other' }
        }
        $dstDir = Join-Path $bkDir $sub
        if(-not (Test-Path $dstDir)){ New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        $dst = Join-Path $dstDir ((Split-Path -Leaf $f) + '.disabled-' + $stamp2)
        Move-Item -LiteralPath $f -Destination $dst -Force -ErrorAction Stop
        WB ('      已挪走: ' + $f + '  →  ' + $dst)
        $moved++
      }
    }
    if($moved -eq 0){ WB '      （没有可挪的副本 —— 已经退场过了）' }
    # 复查
    $left = Get-SvcByPath 'ThrottleStop'
    WB ('      复查: 指向它的服务 ' + $left.Count + ' 个；文件存在? ' + (Test-Path 'C:\Windows\System32\drivers\ThrottleStop.sys'))
    if($moved -gt 0){ WB '      说明：本机 legacy 旧路径（厂商 AutoRetrain）将不再可用，新路径不受影响；还原请把备份文件移回原处' }
    WB ('      备份目录: ' + $bkDir)
  } catch { WB ('      [X] 退场失败: ' + $_.Exception.Message) }
  WB ''

  if(Test-Path $toggle){
    # 1c) 清掉会**自动加载/重装 ThrottleStop** 的自启项（2026-10-01 客户机真凶）
  #     客户机 HKCU\Run 里有一项 40HXGen2_parked → 每次登录都跑厂商的
  #     "D:\download\40HXUnlock_v2.5_win\...\40HXInstaller.exe" -gen2 -silent，
  #     它会重新部署/加载 ThrottleStop → ACE-BOOT 每次开机都弹兼容性提示。
  #     Run 值的**名字无所谓**，只要还在 Run 里就会执行 → 必须移除值本身（留档可还原）。
  WB '  [1c] 清理会加载/重装 40HX 驱动的自启项（Run 键）'
  $patAuto = '40HXInstaller|ThrottleStop|40HXUnlock|40HXGen2'
  $bkLog = Join-Path $ProgDataWin ('logs\autostart-removed-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
  $rmCount = 0; $vendorDirs = @()
  foreach($key in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')){
    try { $pp = Get-ItemProperty -LiteralPath $key -ErrorAction Stop } catch { continue }
    foreach($n in @($pp.PSObject.Properties)){
      if($n.Name -match '^PS'){ continue }
      $val = '' + $n.Value
      if($val -match $patAuto){
        $dir = Split-Path -Parent $key
        if(-not (Test-Path (Split-Path -Parent $bkLog))){ New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bkLog) | Out-Null }
        Add-Content -LiteralPath $bkLog -Value ($key + ' | ' + $n.Name + ' = ' + $val) -Encoding UTF8
        Remove-ItemProperty -LiteralPath $key -Name $n.Name -ErrorAction SilentlyContinue
        WB ('      已移除: ' + $key + ' → ' + $n.Name + ' = ' + $val)
        $rmCount++
        $m = [regex]::Match($val,'"?([A-Za-z]:\\[^"]+?\.exe)')
        if($m.Success){ $vendorDirs += (Split-Path -Parent $m.Groups[1].Value) }
      }
    }
  }
  if($rmCount -eq 0){ WB '      （Run 键里没有需要清理的 40HX 自启项）' }
  else { WB ('      共清理 ' + $rmCount + ' 项，留档: ' + $bkLog) }
  # 1c-2) 顺手把散落在厂商目录里的 ThrottleStop.sys 副本也挪走（否则厂商安装器一跑就装回来）
  $stray = 0
  foreach($vd in ($vendorDirs | Select-Object -Unique)){
    $top = $vd
    # 只扫**厂商 exe 自己所在目录**（含子目录）：绝不向上退层 —— 曾因此把 C:\Temp 整个递归扫了、
    # 误挪仓库副本（2026-10-01 本机测试踩到）。空值/盘符根一律跳过。
    if([string]::IsNullOrWhiteSpace($top) -or $top -match '^[A-Za-z]:\\?$' -or $top -match '^[A-Za-z]:\\Windows'){ WB ('      （跳过扫描 ' + $top + '）'); continue }
    if(Test-Path $top){
      $hits = @(Get-ChildItem -LiteralPath $top -Recurse -Filter 'ThrottleStop.sys' -ErrorAction SilentlyContinue | Select-Object -First 20)
      $idx = 0
      foreach($h in $hits){
        $idx++
        $dstDir = Join-Path $bkDir 'vendor-strays'
        if(-not (Test-Path $dstDir)){ New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        # 备份名唯一（否则多份同名会互相覆盖）
        $dst = Join-Path $dstDir ($h.Name + '.disabled-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '_' + $idx + '_' + ($h.FullName -replace '^[A-Za-z]:\\','' -replace '[\\/:]','_'))
        try { Move-Item -LiteralPath $h.FullName -Destination $dst -Force -ErrorAction Stop; WB ('      厂商目录副本已挪走: ' + $h.FullName); $stray++ } catch { WB ('      [X] 挪走失败: ' + $h.FullName + ' : ' + $_.Exception.Message) }
      }
    }
  }
  if($stray -eq 0){ WB '      （厂商目录里没发现 ThrottleStop.sys 副本）' }
  WB ''
  WB '  [2] 调 ACE-Toggle -Action On（按记录恢复原始启动类型并启动）'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $toggle -Action On *>&1 | ForEach-Object { WB ('      ' + $_) }
    WB '  [3] 调 ACE-Toggle -Action HealTray（把 ACE 托盘拉回用户会话）'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $toggle -Action HealTray *>&1 | ForEach-Object { WB ('      ' + $_) }
  } else { WB '  [2/3] 找不到 ACE-Toggle.ps1 —— 跳过，走硬兜底' }
  $comps2 = @(Get-AceComponents | Where-Object { $_ })
  $boot2 = $comps2 | Where-Object { $_.Name -eq 'ACE-BOOT' } | Select-Object -First 1
  if(-not $boot2){ $boot2 = $comps2 | Where-Object { $_.PathName -match 'AntiCheatExpert' -and $_.Name -match 'BOOT' } | Select-Object -First 1 }
  if($boot2 -and $boot2.State -ne 'Running'){
    WB '  [4] 硬兜底：仍没起来 → 恢复启动类型并启动它'
    $kw='system'
    if(Test-Path $StateFile){ try { $r=Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json; if($r.StartKeyword){ $kw=$r.StartKeyword } } catch {} }
    WB ('      用启动类型: ' + $kw)
    & sc.exe config $boot2.Name ('start= ' + $kw) 2>&1 | ForEach-Object { WB ('      ' + $_) }
    & sc.exe start $boot2.Name 2>&1 | ForEach-Object { WB ('      ' + $_) }
    Start-Sleep -Seconds 2
    WB ('      现在状态: ' + (((sc.exe query $boot2.Name) | Out-String) -replace '\s+',' '))
  }
  WB ''
  WB '  修复动作完成。建议：'
  WB '   ① 重启一次（让预启动反作弊与游戏重新握手）'
  WB '   ② 重启后若游戏仍报错，把这份报告 + 游戏报错原文发回'
  WB '   ③ 若报「环境异常」，考虑 ACE修复.cmd /acefirst on'
}
Save
WB ''
WB ('报告已存: ' + $out)
if(-not $env:NO_PAUSE){ if($Host.Name -eq 'ConsoleHost'){ Write-Host ''; Read-Host '按回车退出' } }
