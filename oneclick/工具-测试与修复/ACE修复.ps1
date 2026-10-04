# ============================================================
#  ACE 体检 / 修复（腾讯反作弊起不来时用）
#  症状：解锁成功后玩游戏提示 ACE 相关错误 / 反作弊初始化失败 / 游戏进不去
#  常见真因（2026-10-01 客户实测）：开机任务旧版逻辑只在 Gen2 成功时才恢复 ACE-BOOT，
#    一旦某一轮重训失败，ACE-BOOT 就永久停在 STOPPED → 游戏里 ACE 起不来。
#  用法：
#    ACE修复.cmd                  → 只读体检（不需要管理员），桌面出报告
#    ACE修复.cmd /fix             → 修复（自动提权）：恢复 ACE-BOOT/托盘、ThrottleStop **只停+禁用（不动文件）**、
#                                    清 40HX 自启项、升级开机任务脚本
#    ACE修复.cmd /fix -retirefile → 同上，另把 ThrottleStop 彻底退役（删掉指向它的服务 + 把 .sys 挪进备份目录）；
#                                    此后厂商 legacy Gen2 回退路径不可用 —— 只在新路径已通了才这么做
#    ACE修复.cmd /acefirst on     → 打开「ACE 优先模式」：开机任务永不停止 ACE-BOOT
#    ACE修复.cmd /acefirst off    → 关闭该模式（恢复默认：新路径不通才回落旧路径）
# ============================================================
param(
  [switch]$Fix,
  [string]$AceFirst = '',
  [switch]$RetireFile   # 2026-10-04：默认只停+禁用、不动文件；要彻底退役（删服务+挪 .sys）才加这个
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
# 2026-10-04: 报告要能自证是哪一版工具产出的（远程诊断先认版本指纹）
$TOOLVER='2026-10-04c'
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
  # 2026-10-04 本机实测（关键）：PowerShell 的注册表 provider 在某个服务键 ACL 破损时会**静默跳过**那个键
  #   —— 本机 829 个里没有 ThrottleStop，而 .NET Registry 枚举有 830 个且含它。只用 Get-ChildItem 会漏掉
  #   「ACL 被改过的、指向我们驱动的服务」→ 退场动作什么都没做却报成功。改用 .NET Registry 枚举 + sc.exe 兜底。
  $regNames = @()
  try {
    $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services', $false)
    if ($root) { $regNames = @($root.GetSubKeyNames()); $root.Close() }
  } catch {}
  foreach($nm in $regNames){
    $ip = $null
    try {
      $sk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(('SYSTEM\CurrentControlSet\Services\' + $nm), $false)
      if ($sk) { $ip = $sk.GetValue('ImagePath'); $sk.Close() }
    } catch {}
    if(-not $ip){
      # 读不到就走 SCM（SCM 读自己的库，不受服务键 ACL 影响）
      $qq = (& sc.exe qc $nm 2>&1 | Out-String)
      $mm = [regex]::Match($qq, 'BINARY_PATH_NAME\s*:\s*(.+)')
      if($mm.Success){ $ip = $mm.Groups[1].Value.Trim().Trim('"') }
    }
    if('' + $ip -match $Pattern){
      $sq = (& sc.exe qc $nm 2>&1 | Out-String)
      $st = [regex]::Match($sq, 'START_TYPE\s*:\s*(\d+)').Groups[1].Value
      $ty = [regex]::Match($sq, 'TYPE\s*:\s*(\d+)').Groups[1].Value
      $out += [pscustomobject]@{ Name = $nm; ImagePath = $ip; Start = $st; Type = $ty }
    }
  }
  # 2026-10-01b（实测回归，同 ACE修复 的 Get-AceComponents）：**不要**用 `,@($out)` 包 ——
  #   调用方写的是 `@(Get-SvcByPath ...)`，外层 @() 会把"单元素数组"当成一个元素收下，
  #   于是 $x.Count 恒为 1、过滤与逐项打印全部退化成"一行挤出所有名字"。逐元素输出即可。
  @($out) | ForEach-Object { $_ }
}
function Get-AceComponents {
  # 注意：**不能用 'ACE' 裸匹配** —— 会把 "Human Interf-ACE Device Service"(hidserv)、
  # "jhi_service"/"nsi"(都含 Interface) 全捞进来（2026-10-01 元测试实测踩到）。
  $wmi = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
    ($_.PathName -match 'AntiCheatExpert|ACE-BOOT|ACE-GAME|ACE-SVC|ACE-Guard|SGuard') -or
    ($_.Name -match '^(ACE-BOOT|ACE-GAME|ACE-SVC|ACE-ADVT|ACE-Guard|AntiCheatExpert)') -or
    ($_.DisplayName -match 'AntiCheatExpert|反作弊|腾讯游戏安全')
  } | Where-Object { $_ })
  # 2026-10-01b（第三方审查 H16）：**Win32_Service 看不到内核驱动**（ACE-BOOT 是 boot 驱动）→
  #   只用 WMI 会漏检它，进而误判「组件缺失、去重装 ACE」。这里补一遍注册表 Services 扫描。
  $names = @($wmi | ForEach-Object { $_.Name })
  $extra = @()
  try {
    # 2026-10-04：同 Get-SvcByPath —— PS 的 Get-ChildItem 会跳过 ACL 破损的服务键（本机实测 829 vs .NET 830）
    #   → 这里也改用 .NET Registry 枚举，读不到就 sc.exe 兜底，避免漏检内核驱动服务。
    $regNames = @()
    try {
      $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services', $false)
      if ($root) { $regNames = @($root.GetSubKeyNames()); $root.Close() }
    } catch {}
    foreach ($nm in $regNames) {
      if ($names -contains $nm) { continue }
      $ip = $null; $startV = -1; $objName = ''
      try {
        $sk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(('SYSTEM\CurrentControlSet\Services\' + $nm), $false)
        if ($sk) { $ip = $sk.GetValue('ImagePath'); $startV = $sk.GetValue('Start'); $objName = $sk.GetValue('ObjectName'); $sk.Close() }
      } catch {}
      if (-not $ip) {
        $qq = (& sc.exe qc $nm 2>&1 | Out-String)
        $mm = [regex]::Match($qq, 'BINARY_PATH_NAME\s*:\s*(.+)')
        if ($mm.Success) { $ip = $mm.Groups[1].Value.Trim().Trim('"') }
        $ms = [regex]::Match($qq, 'START_TYPE\s*:\s*(\d+)')
        if ($ms.Success) { $startV = [int]$ms.Groups[1].Value }
      }
      if (-not $ip) { continue }
      if ($null -eq $startV -or [int]$startV -lt 0) { $startV = -1 }   # 2026-10-04（审查发现）: 原来是 -not $startV —— Start=0(Boot) 时 -not 0 为真，会被改 -1 导致启动方式显示空白
      if ($ip -match 'AntiCheatExpert|ACE-BOOT|ACE-GAME|ACE-SVC|ACE-Guard|SGuard' -or $nm -match '^(ACE-BOOT|ACE-GAME|ACE-SVC|ACE-ADVT|ACE-Guard|AntiCheatExpert)') {
        $startV = [int]$startV
        $mode = switch ([int]$startV) { 0 { 'Boot' } 1 { 'System' } 2 { 'Automatic' } 3 { 'Manual' } 4 { 'Disabled' } default { '' } }
        # 2026-10-01b（第三方审查）：State 不能留空！留空会让下面所有 "State -ne 'Running'" 的判定恒为真，
        #   把一个**正在运行**的 ACE-BOOT 报成"根因/需要恢复"，甚至进硬兜底去改它的启动类型（会动到预启动反作弊时序）。
        #   这里用 sc.exe query 取真实状态。
        $qtext = (& sc.exe query $nm 2>&1 | Out-String)
        # 2026-10-01b（第三方审查 N1）：读不到时必须是**未知**，不能默认成 'Stopped' ——
        #   默认 Stopped 会让下面"状态读不到就不动手"的保护分支永远不可达（形同虚设）。
        $state = 'Unknown'
        if     ($qtext -match 'RUNNING')       { $state = 'Running' }
        elseif ($qtext -match 'START_PENDING') { $state = 'Start Pending' }
        elseif ($qtext -match 'STOP_PENDING')  { $state = 'Stop Pending' }
        elseif ($qtext -match 'PAUSED')        { $state = 'Paused' }
        elseif ($qtext -match 'STOPPED')       { $state = 'Stopped' }
        $extra += [pscustomobject]@{ Name = $nm; PathName = $ip; State = $state; Start = $startV; StartMode = $mode; StartName = $objName; Type = ''; DisplayName = '(内核驱动，来自注册表)' }
      }
    }
  } catch { }
  # 2026-10-01b（实测发现的回归）：**不要**用 `,@(...)` 包 —— 那会让调用方拿到"一个数组对象"，
  #   于是 $comps 只有 1 个元素、$c.Name 变成一串名字、$bootComp.State 永远是 $null →
  #   组件列表挤成一行、结论误报"状态读不到"。逐元素输出即可（和原来的 WMI 版一致）。
  @($wmi) + @($extra) | Sort-Object Name
}

WB '============================================================'
WB (' 40HX：腾讯 ACE 反作弊体检（只读）   工具版 ' + $TOOLVER)
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
    $flag = if($c.State -eq 'Running'){ '  ' } elseif($c.State -eq 'Unknown'){ '  ?' } else { '  ★' }
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
      # 2026-10-04（客户机实测）：只看到「停过没恢复」还不够 —— 体检常被在开机任务跑完之前执行，
      #   那一轮可能还在 heal / 重训里（正常要几十秒~2 分钟）。必须带上「距今多久」，
      #   否则会把「回合进行中」当成「永久停机」下错结论。
      # 2026-10-04（第三方审查 低-2）：[int] 会银行家舍入（未来时刻 -0.4 分钟 → 0 → 误报"距今 0 分钟"）；
      #   改成 Floor，并把"未来时刻/解析失败"统一显示为读不出（-2），不当成"刚停过"。
      $mins = -2
      try { $mins = [math]::Floor(((Get-Date) - [datetime]::Parse($st.Time)).TotalMinutes); if($mins -lt 0){ $mins = -2 } } catch { $mins = -2 }
      WB ('  ★ 有一次停机**没有恢复成功**的记录（停止时刻距今 ' + $(if($mins -ge 0){ '' + $mins + ' 分钟' } else { '读不出（时间格式异常 / 时钟不同步）' }) + '）')
      if($mins -ge 0 -and $mins -lt 10){
        WB '     ！停止发生在 10 分钟以内 —— 若刚跑过开机任务，那一轮很可能**还在重训 / 自愈里**（本工具不等待）'
        WB '       请等 5 分钟后再跑一次体检：仍显示未恢复，才是真的停在停机态。'
      }
      WB '     确认真停在停机态时：跑 ACE修复.cmd /fix（无条件恢复、幂等）→ 再**重启**一次（预启动模式在启动阶段加载，重启即会重载）。'
      WB '       注：只有要清 GPU/PCIe 链路状态时才需要"完全关机再开机（不是重启）"；本条只需重启。'
    }
  } catch { WB ('  读取失败: ' + $_.Exception.Message) }
} else { WB '  （没有记录文件 —— 说明本机从未被我们停过 ACE）' }

# ---------- 4) 开机任务日志 ----------
WB ''
WB '==== 4) 开机任务日志（postbind.log 末尾关键行）===='
if(Test-Path $PostLog){
  # 2026-10-04（第三方审查 低-5）：postbind.log 由 cmd 写出，是 ANSI(GBK)，按 UTF8 读会让中文行变乱码 → 改 Default。
  $lines = @(Get-Content -LiteralPath $PostLog -Tail 60 -Encoding Default -ErrorAction SilentlyContinue)
  foreach($l in $lines){
    if($l -match 'NewPath EXIT|PostBind EXIT|PASS:|FAIL:|ACE|falling back|ACE-PRIORITY|heal|attempt|NewPath start'){
      WB ('  ' + ($l -replace '\s+',' ').Trim())
    }
  }
  # 2026-10-04（客户机实测）：日志停在「ACE-BOOT 已停止」而后面没有 attempt/恢复行 = 那一轮卡在停 ACE 之后。
  #   只报「有停机记录」会把「任务卡死」误判成「恢复逻辑没写」——分开判。
  # 低-1：窗口 400 行可能漏掉最后一轮（一轮失败日志很长时）→ 放大到 2000。
  $tail = @(Get-Content -LiteralPath $PostLog -Tail 2000 -Encoding Default -ErrorAction SilentlyContinue)
  $lastStart = -1; $lastExit = -1
  for($i=0; $i -lt $tail.Count; $i++){
    if($tail[$i] -match 'PostBind start'){ $lastStart = $i }
    if($tail[$i] -match 'PostBind EXIT='){ $lastExit = $i }
  }
  if($lastStart -ge 0 -and $lastExit -lt $lastStart){
    WB '  ★ 最后一次开机任务**没有跑到收尾行**（有 ==== PostBind start ==== 却始终没有 ==== PostBind EXIT= ====）'
    WB '     → 那一轮卡住/被中断了。它若卡在停 ACE-BOOT 之后，ACE-BOOT 就会一直停在停机态（游戏进不去）。'
    WB '     请把整个 logs\postbind.log 与 logs\retrain-last.log（失败轮另有 logs\failures\newpath-*-exit*.out）发回。'
  } elseif($lastStart -ge 0){
    WB '  最后一次开机任务有收尾行（出现 ==== PostBind EXIT= ====）'
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
if($task.Count){ foreach($t in $task){ WB ('  开机任务: ' + $t.TaskName + '  ' + $t.State) } }
elseif(-not (Is-Admin)){ WB '  开机任务: 读不到（本次体检不是管理员 —— SYSTEM 任务对普通用户不可见，**不等于不存在**）' }
else { WB '  开机任务:（未找到）' }
if(-not (Is-Admin) -and $task.Count){ WB '  （非管理员：这里只列出当前用户可见的任务；SYSTEM 任务读不到 —— 列表可能不完整）' }
WB ('  ACE 优先模式: ' + $(if(Test-Path $Marker){'已开启（开机任务永不停止 ACE-BOOT）'}else{'未开启（默认：新路径不通才回落旧路径）'}))
WB ('  脚本: ' + $(if(Test-Path $toggle){$toggle}else{'（找不到 ACE-Toggle.ps1）'}))

# ---------- 6b) 谁在加载 ThrottleStop？ + 部署脚本版本 ----------
WB ''
WB '==== 6b) ThrottleStop 溯源（ACE 弹窗就是指它）===='
$tsSvc = Get-SvcByPath 'ThrottleStop'
if($tsSvc.Count -eq 0){ WB '  指向 ThrottleStop.sys 的服务: 无（名字不限）' }
else { foreach($s in $tsSvc){ WB ('  ★ 服务 ' + $s.Name + '  Start=' + $s.Start + '  类型=' + $s.Type + '  → ' + $s.ImagePath) } }
$tsFile='C:\Windows\System32\drivers\ThrottleStop.sys'
if(Test-Path $tsFile){ WB ('  驱动文件: 存在  ' + (Get-Item $tsFile).Length + ' B  修改于 ' + (Get-Item $tsFile).LastWriteTime) } else { WB '  驱动文件: 不存在（已退场）' }
$tsTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $a = ($_.Actions | ForEach-Object { ('' + $_.Execute) + ' ' + ('' + $_.Arguments) }) -join ' '; $a -match 'ThrottleStop|40HX|AutoRetrain|RunPostBind|CMP40HX' } | Where-Object { $_ })
if($tsTasks.Count -eq 0){ WB $(if(Is-Admin){'  相关计划任务: 无'}else{'  相关计划任务: 读不到（需要管理员；不等于没有）'}) }
else { foreach($t in $tsTasks){ $a=($t.Actions | ForEach-Object { ('' + $_.Execute) + ' ' + ('' + $_.Arguments) }) -join ' | '; WB ('  任务 ' + $t.TaskName + '  ' + $t.State + '  → ' + $a) }; if(-not (Is-Admin)){ WB '  （非管理员：SYSTEM 任务读不到 —— 上面的列表可能不完整）' } }
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
# 部署的开机任务脚本是新版还是旧版？（判据必须用**当前脚本里真实存在**的字符串 —— 2026-10-04 修正）
#   旧判据（'ThrottleStop 退场' / 'heal: create service ThrottleStop'）在 2026-10-01s 之后的包里已被改写/删掉，
#   于是**任何**机器（含本机最新版）都会被误报「★ 旧版」——2026-10-04 在本机实测复现过。别再靠那两个字符串。
$dep = Join-Path $ProgDataWin 'RunPostBind.cmd'
if(Test-Path $dep){
  try {
  $fi  = Get-Item -LiteralPath $dep
  $raw = Get-Content -LiteralPath $dep -Raw -Encoding UTF8
  $hasCondGate  = $raw -match 'if "!RC!"=="0" if "!ACE_STOPPED!"=="1"'   # <=2026-10-01j：只在 Gen2 成功时才恢复 ACE "
  $hasOldCreate = $raw -match 'heal: create service ThrottleStop'        # <=2026-10-01k：每轮重建 ThrottleStop
  $hasUncond    = $raw -match 'restore ACE UNCONDITIONALLY'              # >=2026-10-01k：收尾无条件恢复 ACE
  $hasStartHeal = ($raw -match 'call :ace_toggle on') -and ($raw -match 'ACE heal \(unconditional\)')  # 开场无条件自愈（铁律 5）
  $hasRetire    = $raw -match 'start= disabled'                          # ThrottleStop 退场
  # 中-4：旧特征命中不再直接判「旧版」—— 新版脚本的注释/留档里也可能留着旧串（-match 是整个文件、大小写不敏感）。
  #   只有"旧特征命中 且 新逻辑特征缺失"才是真旧版；两者同时命中时报"疑似残留"请人工确认，避免误导客户去跑会改系统的 /fix。
  $verdict = if($hasCondGate -or $hasOldCreate){
    if($hasUncond -and $hasStartHeal){ '疑似旧版残留（旧串还在、但新版逻辑也在）—— 请把该文件发回人工确认' } else { '★ 旧版（含已知缺陷）' }
  } elseif($hasUncond -and $hasStartHeal){ '新版' } else { '判不出（请把该文件发回）' }
  WB ('  部署的开机脚本: ' + $verdict)
  WB ('    判据: 无条件恢复=' + $hasUncond + '  开场自愈=' + $hasStartHeal + '  条件恢复(旧缺陷)=' + $hasCondGate + '  旧heal重建ThrottleStop=' + $hasOldCreate + '  ThrottleStop退场(仅参考)=' + $hasRetire)
  # 中-6：Get-FileHash 失败时 $null.Substring 会抛异常 → 整个只读体检中断、桌面报告都不落盘。加容错。
  $depHash = ''
  try { $depHash = (Get-FileHash -LiteralPath $dep -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $depHash = '' }
  WB ('    文件: ' + $fi.Length + ' B   改于 ' + $fi.LastWriteTime + '   sha256=' + $(if($depHash){ $depHash.Substring(0,16) } else { '(读不出)' }))
  if($hasCondGate){ WB '    ！条件恢复的旧版：某轮失败后 ACE-BOOT 会永久停在 STOPPED（游戏反作弊起不来）→ 跑 ACE修复.cmd /fix 就地升级' }
  if($hasOldCreate){ WB '    ！旧逻辑仍会每轮重建 ThrottleStop 服务 → ACE 会弹「加载了 ThrottleStop.sys」→ 跑 ACE修复.cmd /fix' }
  WB ('    备份文件: ' + ((@(Get-ChildItem $ProgDataWin -Filter 'RunPostBind.cmd.bak-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', ')))
  } catch { WB ('  部署的开机脚本: 读取失败: ' + $_.Exception.Message) }
} else { WB ('  部署的开机脚本: 没找到 ' + $dep) }
# 最近一次开机的 postbind 关键行里有没有 throttle / legacy 回落
if(Test-Path $PostLog){
  $tl = @(Get-Content -LiteralPath $PostLog -Tail 80 -Encoding Default -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'throttle|legacy|falling back|create service ThrottleStop|NewPath EXIT|ACE-PRIORITY' }
  if($tl){ WB '  最近开机里与 ThrottleStop / 回落相关的行:'; foreach($l in $tl){ WB ('    ' + ($l -replace '\s+',' ').Trim()) } }
  else { WB '  最近开机日志里没有 throttle / legacy 回落痕迹 → 说明不是我们脚本在加载它' }
}
WB ''
# ---------- 6c) 厂商 v3.2 / 其它解锁包的遗留项（任务 + 服务）----------
WB ''
WB '==== 6c) 厂商遗留项（任务 / 服务）===='
$vPat = '40HX|Gen2|ThrottleStop|40HXUnlock'
$vTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
  $a = ($_.Actions | ForEach-Object { ('' + $_.Execute) + ' ' + ('' + $_.Arguments) }) -join ' '
  ($_.TaskName -match $vPat) -or ($a -match $vPat)
} | Where-Object { $_ -and $_.TaskName -notmatch 'CMP40HX Gen2 PostBind' })
if($vTasks.Count -eq 0){ WB $(if(Is-Admin){'  任务: 无（干净）'}else{'  任务: 读不到（需要管理员；不等于没有）'}) }
else {
  $script:vendorTasks = @($vTasks | ForEach-Object { $_.TaskName })
  foreach($t in $vTasks){
    $a=($t.Actions | ForEach-Object { ('' + $_.Execute) + ' ' + ('' + $_.Arguments) }) -join ' | '
    WB ('  ★ 任务 ' + $t.TaskName + '  ' + $t.State + '  → ' + $a)
  }
  WB '    危害：厂商 Gen2 任务会重新拉 ThrottleStop/硬复位显卡 → ACE 弹窗 + 算力被清'
}
$vSvcs = @(Get-SvcByPath 'ThrottleStop|40HXUnlock|40HXGen2' | Where-Object { $_.Name -notmatch '^(WinRing0_1_2_0|WinRing0_40HX|ThrottleStop)$' })
if($vSvcs.Count -eq 0){ WB '  服务: 无额外项' }
else { foreach($v in $vSvcs){ WB ('  ★ 服务 ' + $v.Name + '  Start=' + $v.Start + ' → ' + $v.ImagePath) } }
WB '  处置：ACE修复.cmd /fix 会把这些任务/服务**禁用**（不删除、留档可还原）'
WB ''
# ---------- 7) 结论 ----------
WB ''
WB '==== 7) 结论 ===='
if($comps.Count -eq 0){
  WB '  ACE 组件不在本机 → 请在游戏客户端里点「修复 / 重新安装」让游戏重新部署 ACE'
} elseif($bootComp -and $bootComp.State -eq 'Unknown'){
  # 2026-10-01b（审查）：状态都读不到时不要下"根因"结论（原来 State 为空会被当成"没在运行"→ 误报根因）
  WB ('  ACE 引导驱动 ' + $bootComp.Name + ' 的状态读不到（sc query 没返回）→ 不下结论。')
  WB '     处理：以管理员身份重跑本工具；或直接跑「ACE修复.cmd /fix」。'
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
  # 2026-10-04（第三方审查 低-3）：与 -Fix 一致 —— 非管理员先自提权；提权失败/取消时以非 0 退出（原来只打一行提示且仍 exit 0）。
  if(-not (Is-Admin)){
    WB '  -AceFirst 需要管理员权限（它会写 C:\ProgramData）→ 正在请求提权（会弹 UAC，请点“是”）...'
    Save
    try { Start-Process powershell -Verb RunAs -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-AceFirst',$AceFirst); exit 0 }
    catch { WB ('  提权失败或被取消: ' + $_.Exception.Message); Save; exit 1 }
  }
  $dir=Split-Path -Parent $Marker
  if($AceFirst -eq 'on'){
    if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -LiteralPath $Marker -Value ('ACE priority mode enabled ' + (Get-Date -Format 's')) -Encoding UTF8 -Force
    WB ('  [OK] 已开启 ACE 优先模式: ' + $Marker)
  } else {
    if(Test-Path $Marker){ Remove-Item -LiteralPath $Marker -Force }
    WB '  [OK] 已关闭 ACE 优先模式'
  }
  WB '  注意：该模式由开机任务脚本 RunPostBind.cmd 读取 —— 请先用安装器 Repair 一次，把新版 RunPostBind.cmd 铺到 C:\ProgramData\CMP40HXGen2\windows\'
  Save; if($env:NO_PAUSE -ne '1'){ if($Host.Name -eq 'ConsoleHost'){ Write-Host ''; Read-Host '按回车退出' } }; exit 0
}

if($Fix){
  if(-not (Is-Admin)){
    WB ''
    WB '  -Fix 需要管理员权限 → 正在请求提权（会弹 UAC，请点“是”）...'
    Save
    try {
      # 2026-10-04：提权时必须**把开关一起转发**，否则 /fix -retirefile 的 -RetireFile 会丢，
      #   子进程按默认（不动文件）跑 —— 客户会以为做了彻底退役其实没做（本机实测踩到）。
      $extraArgs = @()
      if($RetireFile){ $extraArgs += '-RetireFile' }
      if($AceFirst -ne ''){ $extraArgs += @('-AceFirst', $AceFirst) }
      Start-Process powershell -Verb RunAs -Wait -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Fix') + $extraArgs)
      WB '  提权窗口已结束 —— 请看它生成的报告（桌面 40HX-ACE体检-*.txt）'
    } catch { WB ('  [X] 提权失败: ' + $_.Exception.Message) }
    Save; exit 0
  }
  WB ''
  WB '==== 9) 执行修复 ===='

  # ---- 9.0) 先把「开机任务脚本」升级到包内新版 -------------------------------------
  # 新版修了两件事：① ACE 的恢复不再依赖 Gen2 是否成功（旧版漏了 RC!=0 路径，
  # 会把 ACE-BOOT 永久停在 STOPPED）；② ThrottleStop 退场（默认只停+置 disabled、**不动文件** —— 见 9.1 说明）
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

  # ---- 9.0b) 接管厂商遗留（任务/服务）—— 只禁用，不删除，留档可还原 ----
  WB '  [0b] 接管厂商遗留任务/服务（禁用 + 留档）'
  $bk2 = Join-Path $ProgDataWin ('logs\vendor-disabled-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
  $vPat2 = '40HX|Gen2|ThrottleStop|40HXUnlock'
  $n1 = 0
  try {
    $vt = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
      $a = ($_.Actions | ForEach-Object { ('' + $_.Execute) + ' ' + ('' + $_.Arguments) }) -join ' '
      (($_.TaskName -match $vPat2) -or ($a -match $vPat2)) -and ($_.TaskName -notmatch 'CMP40HX Gen2 PostBind')
    } | Where-Object { $_ })
    foreach($t in $vt){
      $a=($t.Actions | ForEach-Object { ('' + $_.Execute) + ' ' + ('' + $_.Arguments) }) -join ' | '
      Add-Content -LiteralPath $bk2 -Value ('TASK | ' + $t.TaskName + ' | state=' + $t.State + ' | ' + $a) -Encoding UTF8
      Disable-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue | Out-Null
      WB ('      已禁用任务: ' + $t.TaskName)
      $n1++
    }
    $vs = @(Get-SvcByPath 'ThrottleStop|40HXUnlock|40HXGen2' | Where-Object { $_.Name -notmatch '^(WinRing0_1_2_0|WinRing0_40HX)$' })
    foreach($v in $vs){
      Add-Content -LiteralPath $bk2 -Value ('SVC | ' + $v.Name + ' | start=' + $v.Start + ' | ' + $v.ImagePath) -Encoding UTF8
      & sc.exe config $v.Name start= disabled 2>&1 | Out-Null
      WB ('      已禁用服务: ' + $v.Name + '（原 start=' + $v.Start + '）')
      $n1++
    }
    if($n1 -eq 0){ WB '      （没有需要接管的厂商遗留）' } else { WB ('      共处置 ' + $n1 + ' 项，留档: ' + $bk2) }
  } catch { WB ('      [X] 接管失败: ' + $_.Exception.Message) }
  WB ''

  # ---- 9.1) ThrottleStop 退场（ACE 报的就是它）----
  # 2026-10-04（用户决定）：**默认只停 + 置 disabled，不动磁盘上的 .sys**。
  #   ① ACE-BOOT 拦的是「驱动映像加载」，不加载就足够（本机实测：文件在盘上、服务从未加载，近 30 天 0 条弹窗事件）；
  #   ② 文件留着才能保住厂商 legacy Gen2 回退路径（厂商 AutoRetrain 需要 ThrottleStop）—— 新路径还不通的机器靠它兜底；
  #   ③ 服务键保留 → 可逆：要用回 legacy 只要 sc config <服务> start= demand 再 sc start。
  #   要彻底退役（删掉指向它的服务 + 把 .sys 挪进备份目录）请显式加 -RetireFile。
  WB '  [1] ThrottleStop 退场（默认：只停 + 置 disabled，**不动文件**）'
  $tsSvcs = @(Get-SvcByPath 'ThrottleStop' | Where-Object { $_ })
  if($tsSvcs.Count -eq 0){ WB '      （本机没有指向 ThrottleStop.sys 的服务 —— 无需处理）' }
  else {
    foreach($sv in $tsSvcs){
      $tq = (& sc.exe query $sv.Name 2>&1 | Out-String)
      $tqc = (& sc.exe qc $sv.Name 2>&1 | Out-String)
      WB ('      服务 ' + $sv.Name + '   ' + ([regex]::Match($tqc,'START_TYPE\s*:\s*\d+\s+\S+').Value) + '   ' + ([regex]::Match($tq,'STATE\s*:\s*\d+\s+\S+').Value))
      if($tq -match 'RUNNING'){
        WB '        正在运行 → 停止（卸下内核映像；ACE 拦的就是这一步）'
        & sc.exe stop $sv.Name 2>&1 | ForEach-Object { WB ('        ' + $_) }
        Start-Sleep -Seconds 2
      }
      if($tqc -notmatch 'DISABLED'){
        WB '        设为 disabled（不再随开机/按需加载）'
        & sc.exe config $sv.Name start= disabled 2>&1 | ForEach-Object { WB ('        ' + $_) }
      }
      $tq2 = (& sc.exe query $sv.Name 2>&1 | Out-String)
      WB ('        现在: ' + ([regex]::Match($tq2,'STATE\s*:\s*\d+\s+\S+').Value))
    }
    WB '      服务键保留（没删）→ 以后要用厂商 legacy 回退：sc config <服务名> start= demand 再 sc start <服务名>'
  }
  # 1b) 默认**不动文件**；只有显式 -RetireFile 才彻底退役
  if(-not $RetireFile){
    WB '  [1b] 跳过「彻底退役」（默认不动文件 —— 有意为之，不是失败）'
    WB '       ACE 只拦驱动映像加载：不加载就够了，.sys 留在盘上不会触发它（本机实测 30 天 0 条弹窗事件）。'
    WB '       文件留着还保住厂商 legacy Gen2 回退路径（新路径不通的机器靠它兜底）；服务键也没删，随时能改回来。'
    WB '       真要彻底退役（删掉所有指向它的服务 + 把 .sys 挪进备份目录）请跑：ACE修复.cmd /fix -retirefile'
  } else {
    WB '  [1b] 彻底退役（-RetireFile）：停并删除所有指向它的服务，再把 .sys 挪进备份目录'
    try {
      $bkDir = 'C:\ProgramData\CMP40HXGen2\drivers-disabled'
      if(-not (Test-Path $bkDir)){ New-Item -ItemType Directory -Force -Path $bkDir | Out-Null }
      $svcs = Get-SvcByPath 'ThrottleStop'
      foreach($sv in $svcs){
        WB ('      服务 ' + $sv.Name + '（Start=' + $sv.Start + '）→ 停止并删除')
        & sc.exe stop $sv.Name 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
        & sc.exe delete $sv.Name 2>&1 | Out-Null
      }
      if($svcs.Count -eq 0){ WB '      指向它的服务: 无' }
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
      $left = Get-SvcByPath 'ThrottleStop'
      WB ('      复查: 指向它的服务 ' + @($left).Count + ' 个；文件存在? ' + (Test-Path 'C:\Windows\System32\drivers\ThrottleStop.sys'))
      if($moved -gt 0){ WB '      说明：本机 legacy 旧路径（厂商 AutoRetrain）将不再可用，新路径不受影响；还原请把备份文件移回原处' }
      WB ('      备份目录: ' + $bkDir)
    } catch { WB ('      [X] 退役失败: ' + $_.Exception.Message) }
  }
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
  # 1c-2) 彻底退役时才顺手把散落在厂商目录里的 ThrottleStop.sys 副本也挪走（否则厂商安装器一跑就装回来）
  #   2026-10-04：默认不动文件 → 这一段也只在 -RetireFile 时执行
  if($RetireFile){
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
  } else { WB '  [1c-2] 跳过厂商目录副本清理（默认不动文件；要彻底退役用 /fix -retirefile）' }
  WB ''
  WB '  [2] 调 ACE-Toggle -Action On（按记录恢复原始启动类型并启动）'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $toggle -Action On *>&1 | ForEach-Object { WB ('      ' + $_) }
    WB '  [3] 调 ACE-Toggle -Action HealTray（把 ACE 托盘拉回用户会话）'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $toggle -Action HealTray *>&1 | ForEach-Object { WB ('      ' + $_) }
  } else { WB '  [2/3] 找不到 ACE-Toggle.ps1 —— 跳过，走硬兜底' }
  $comps2 = @(Get-AceComponents | Where-Object { $_ })
  $boot2 = $comps2 | Where-Object { $_.Name -eq 'ACE-BOOT' } | Select-Object -First 1
  if(-not $boot2){ $boot2 = $comps2 | Where-Object { $_.PathName -match 'AntiCheatExpert' -and $_.Name -match 'BOOT' } | Select-Object -First 1 }
  if($boot2 -and $boot2.State -eq 'Unknown'){
    WB '  [4] 硬兜底：跳过 —— 读不到 ACE-BOOT 的状态（sc query 没返回），**不猜、不动手**'
  } elseif($boot2 -and $boot2.State -ne 'Running'){
    # 2026-10-01b（第三方审查 H14）：先看它当前是不是**被刻意禁用**了（DISABLED = 客户点过
    #   ACE 弹窗里的"退出/卸载预启动模式"）。那种情况下把它改成 system 并启动 → 反作弊预启动层
    #   与用户态状态不一致，实测会卡在进系统界面 / 登录后没有桌面。所以：DISABLED 就只报告、不动手。
    $qc = ((sc.exe qc $boot2.Name 2>&1) | Out-String)
    if($qc -match 'DISABLED'){
      WB '  [4] 硬兜底：跳过 —— 该服务当前是 DISABLED（你/客户点过"退出预启动模式"）'
      WB '      现在的做法是**尊重现状、不强行恢复**（强行恢复可能卡启动/黑屏）。'
      WB '      要继续用腾讯游戏的预启动反作弊，请在游戏客户端里点"修复/重装 ACE"，让 ACE 自己回到一致状态。'
    } else {
      WB '  [4] 硬兜底：仍没起来 → 按记录恢复启动类型并启动它'
      $kw=''
      if(Test-Path $StateFile){ try { $r=Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json; if($r.StartKeyword){ $kw=$r.StartKeyword } } catch {} }
      if(-not $kw){ $kw='system' }
      WB ('      用启动类型: ' + $kw)
      & sc.exe config $boot2.Name ('start= ' + $kw) 2>&1 | ForEach-Object { WB ('      ' + $_) }
      & sc.exe start $boot2.Name 2>&1 | ForEach-Object { WB ('      ' + $_) }
      Start-Sleep -Seconds 2
      WB ('      现在状态: ' + (((sc.exe query $boot2.Name) | Out-String) -replace '\s+',' '))
    }
  }
  WB ''
  WB '  修复动作完成。建议：'
  WB '   ① 重启一次（让预启动反作弊与游戏重新握手；重启就会重载预启动模式，不需要"完全关机"）'
  WB '   ② 重启后若游戏仍报错，把这份报告 + 游戏报错原文发回'
  WB '   ③ 若报「环境异常」，考虑 ACE修复.cmd /acefirst on'
}
Save
WB ''
WB ('报告已存: ' + $out)
if($env:NO_PAUSE -ne '1'){ if($Host.Name -eq 'ConsoleHost'){ Write-Host ''; Read-Host '按回车退出' } }
