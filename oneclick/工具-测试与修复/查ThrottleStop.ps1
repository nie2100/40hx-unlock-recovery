# ============================================================
#  查 ThrottleStop 驱动（只读体检）
#  回答三个问题：① 这个驱动现在有没有在跑 ② 文件都放在哪几个位置 ③ 谁还会把它加载回来
#  末节给「直接删掉安不安全」的判据与正确退役顺序。
#  用法：查ThrottleStop.cmd            → 只读体检（自动提权），报告落到桌面
#        查ThrottleStop.cmd -Deep      → 顺带扫 ESP 上的兜底副本（会临时挂一下 EFI 分区）
#  作者：Hermes / 2026-10-04   ver 2026-10-04a
# ============================================================
param([switch]$NoElevate, [switch]$Deep, [string]$OutFile = '')
$ErrorActionPreference = 'Continue'
$VER = '2026-10-04a'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk) { $desk = 'C:\Users\Public\Desktop' }
# 父进程提权时把路径传给子进程，避免生成两份报告（一份只有 2 行的空壳）
$out = if ($OutFile) { $OutFile } else { Join-Path $desk ('40HX-ThrottleStop体检-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt') }
$sb = New-Object System.Text.StringBuilder
function W  { param([string]$s = '') [void]$sb.AppendLine($s) }
function WB { param([string]$s = '') Write-Host $s; [void]$sb.AppendLine($s) }
function Save { try { $sb.ToString() | Out-File -Encoding utf8 $out } catch { } }
function Is-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
# ImagePath 的四种写法都要能还原成真实路径（2026-10-04 实测：写错会把存在的文件报成"不存在"）
function Resolve-ImagePath([string]$ip) {
  if (-not $ip) { return '' }
  $p = ([string]$ip).Trim()
  if ($p.StartsWith('"')) {
    $q = [regex]::Match($p, '^"([^"]+)"')
    if ($q.Success) { $p = $q.Groups[1].Value } else { $p = $p.Trim('"') }
  } else {
    # 未加引号的写法可能带参数（如 C:\x\y.exe -svc_run）→ 只取到 .sys / .exe 为止
    $q = [regex]::Match($p, '^([A-Za-z]:\\[^"]*?\.(sys|exe))')
    if ($q.Success) { $p = $q.Groups[1].Value }
  }
  if ($p -match '^\\\\?\?\\') { $p = $p.Substring(4) }
  elseif ($p -match '^\\\?\?\\') { $p = $p.Substring(4) }
  if ($p -match '^[A-Za-z]:') { return $p }
  if ($p -match '^\\SystemRoot\\') { return (Join-Path $env:SystemRoot $p.Substring(12)) }
  if ($p -match '^SystemRoot\\')    { return (Join-Path $env:SystemRoot $p.Substring(11)) }
  if ($p -match '^\\\\')            { return $p }
  return (Join-Path $env:SystemRoot $p)
}

WB '============================================================'
WB (' 40HX：ThrottleStop 驱动体检（只读）   工具版 ' + $VER)
WB (' 时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   机器: ' + $env:COMPUTERNAME + '   管理员: ' + (Is-Admin))
WB '============================================================'

if ((-not (Is-Admin)) -and (-not $NoElevate)) {
  WB ''
  Write-Host '  本工具要读服务注册表与内核模块列表 → 需要管理员，正在提权（会弹 UAC，请点"是"）...'
  Write-Host ('  完整报告将写到: ' + $out)
  try {
    Start-Process powershell -Verb RunAs -Wait -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-NoElevate','-OutFile',$out) + $(if ($Deep) { @('-Deep') } else { @() }))   # 2026-10-04（审查发现）: 提权时必须转发 -Deep，否则用户以为扫了 ESP，其实没扫
    Write-Host '  提权窗口已结束 —— 请看上面那个报告文件'
  } catch { Write-Host ('  [X] 提权失败: ' + $_.Exception.Message) }
  # 2026-10-04: 父进程**不再写报告** —— 否则会用这份两行的空壳把子进程的完整报告覆盖掉
  exit 0
}

# ---------- 1) 服务层：谁指向 ThrottleStop.sys（名字不限）----------
WB ''
WB ''
WB '==== 1) 指向 ThrottleStop.sys 的服务（全量枚举，名字不限）===='
# 2026-10-04 本机实测（必读）：PowerShell 的注册表 provider（Get-ChildItem）在某个服务键 ACL 破损时会**静默跳过**那个键
#   —— 本机 829 个里没有 ThrottleStop，而 .NET Registry 枚举有 830 个且含它 → 会误报「这台机器没有这个服务」。
#   所以一律用 .NET Registry 枚举；读不到 ImagePath 的键用 sc.exe qc 兜底，并把「读不到的键」按名字报出来。
$svcNames = @()
try {
  $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services', $false)
  if ($root) { $svcNames = @($root.GetSubKeyNames()); $root.Close() }
} catch { WB ('  [X] 注册表枚举失败: ' + $_.Exception.Message) }
WB ('  服务键总数: ' + $svcNames.Count + '（.NET Registry 枚举；PS 的 Get-ChildItem 会跳过 ACL 破损的键）')
$hits = @()
$deniedKeys = @()    # 连 ImagePath 都读不到的服务键（ACL 破损）
$scFallback = @()    # 其中确实是服务、路径靠 sc.exe qc 拿到的
$noImagePath = 0     # 本来就没有 ImagePath 的键（性能计数器之类，不是驱动服务）
foreach ($name in $svcNames) {
  $ip = $null; $why = ''
  try {
    $sk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(('SYSTEM\CurrentControlSet\Services\' + $name), $false)
    if ($sk) {
      $ip = $sk.GetValue('ImagePath')
      $sk.Close()
      if (-not $ip) { $why = 'no-ImagePath-value' }
    } else { $why = 'registry-denied' }
  } catch { $why = 'registry-denied' }
  if ($why -eq 'registry-denied') { $deniedKeys += $name }
  if (-not $ip) {
    $q = (& sc.exe qc $name 2>&1 | Out-String)
    $m = [regex]::Match($q, 'BINARY_PATH_NAME\s*:\s*(.+)')
    if ($m.Success) {
      $ip = $m.Groups[1].Value.Trim()
      if ($why -eq 'registry-denied') { $scFallback += $name }
    } elseif ($why -eq 'no-ImagePath-value') { $noImagePath++ }
  }
  if ($ip) { $ip = ([string]$ip).Trim().Trim('"') }
  if ($ip -and ($ip -match 'ThrottleStop')) {
    $st = (& sc.exe query $name 2>&1 | Out-String)
    $qc = (& sc.exe qc $name 2>&1 | Out-String)
    $src = 'registry'
    if ($scFallback -contains $name) { $src = 'sc.exe（注册表读不到）' }
    $hits += [pscustomobject]@{
      Name = $name
      ImagePath = $ip
      Resolved = (Resolve-ImagePath $ip)
      StartType = [regex]::Match($qc, 'START_TYPE\s*:\s*\d+\s+(\S+)').Groups[1].Value
      State = [regex]::Match($st, 'STATE\s*:\s*\d+\s+(\S+)').Groups[1].Value
      WinExit = [regex]::Match($st, 'WIN32_EXIT_CODE\s*:\s*(\d+)').Groups[1].Value
      From = $src
    }
  }
}
if ($hits.Count -eq 0) { WB '  （没有找到 —— 本机没有任何服务会加载 ThrottleStop.sys）' }
else {
  foreach ($h in $hits) {
    WB ('  ★ 服务 ' + $h.Name + '   启动类型=' + $h.StartType + '   状态=' + $h.State + $(if ($h.WinExit -and $h.WinExit -ne '0') { '  （上次启动失败码 ' + $h.WinExit + '）' } else { '' }))
    WB ('      ImagePath: ' + $h.ImagePath + '   [读自 ' + $h.From + ']')
    WB ('      解析路径 : ' + $h.Resolved + '   存在=' + (Test-Path -LiteralPath $h.Resolved))
  }
}
if ($noImagePath -gt 0) { WB ('  说明：' + $noImagePath + ' 个服务键本来就没有 ImagePath（性能计数器/组件键，不是驱动服务）—— 正常。') }
if ($deniedKeys.Count) {
  WB ('  ★ 读不到 ImagePath 的服务键 ' + $deniedKeys.Count + ' 个（ACL 破损）—— 已逐个用 sc.exe qc 兜底，不漏检：')
  WB ('      ' + (($deniedKeys | Select-Object -First 12) -join ', '))
}
$risk = @($svcNames | Where-Object { $_ -match 'Throttle|WinRing|inpout|40HX|Gen2|ACE|SGuard|iGame' })
$risk = @($svcNames | Where-Object { $_ -match '^(ACE|SGuard|ThrottleStop|WinRing0|inpout|40HX|Gen2|iGame)' })
if ($risk.Count) { WB ('  与 40HX 方案相关的服务名（锚定匹配；含正在运行的其它工具，供人工核对）：' + ($risk -join ', ')) }
if ($denied.Count) { WB ('  注意：' + $denied.Count + ' 个服务键连管理员都读不到（ACL 异常，已改用 sc.exe 兜底）：' + (($denied | Select-Object -First 8) -join ', ')) }
WB '  说明：内核驱动**正在运行** = 它的映像已加载进内核，此时腾讯 ACE-BOOT 会在映像加载阶段拦它并弹'
WB '        「检测到与游戏可能存在兼容问题的软件程序加载: ThrottleStop.sys」。所以状态是 STOPPED/DISABLED 才安全。'

# ---------- 2) 内核里到底有没有它 ----------
WB ''
WB '==== 2) 内核模块 / WMI 交叉验证（防止只看服务状态被骗）===='
$dq = (& driverquery.exe /v /fo csv 2>&1 | Out-String)
$dm = @($dq -split "`r?`n" | Where-Object { $_ -match 'ThrottleStop' })
if ($dm.Count) { foreach ($l in $dm) { WB ('  driverquery: ' + (($l -replace '\s+', ' ') -replace '","', ' | ').Trim()) } } else { WB '  driverquery: 内核里没有 ThrottleStop 模块（= 没在跑）' }
$w = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object { $_.PathName -match 'ThrottleStop' -or $_.Name -match 'ThrottleStop' })
$kRunning = $false
if ($w.Count) {
  foreach ($x in $w) {
    WB ('  WMI: ' + $x.Name + '  State=' + $x.State + '  StartMode=' + $x.StartMode + '  Started=' + $x.Started + '  Path=' + $x.PathName)
    if ($x.State -eq 'Running') { $kRunning = $true }
  }
} else { WB '  WMI: 没有查到（注意 WMI 可能看不到某些内核驱动服务，读不到不等于没有）' }
# 判据：ACE 看的是"映像有没有被加载" —— 服务层(SCM 的 STATE) 与 内核层(WMI/driverquery) 合并出结论
$svcRunning = @($hits | Where-Object { $_.State -eq 'RUNNING' })
$running = $svcRunning
$isRunning = (($svcRunning.Count -gt 0) -or $kRunning)
$isPresent = (($hits.Count -gt 0) -or ($w.Count -gt 0) -or ($dm.Count -gt 0))
WB ('  ★ 判定：服务层=' + $(if ($hits.Count -gt 0) { [string]$hits.Count + ' 个服务指向它' } else { '没有' }) + '；内核层=' + $(if ($kRunning) { '已加载并在运行(RUNNING)' } elseif ($w.Count -gt 0 -or $dm.Count -gt 0) { '有记录但未运行' } else { '不存在' }))
if ($isRunning) { WB '  ★ 结论：ThrottleStop 驱动**正在运行**（RUNNING）—— 这正是腾讯 ACE 弹「检测到兼容问题软件」的直接原因。' }
elseif ($isPresent) { WB '  结论：本机上**存在** ThrottleStop（服务 / 内核条目 / 文件），当前**没有在运行** → ACE 不会因它弹窗；隐患是"哪天被拉起来"（见第 4 节）。' }
else { WB '  结论：服务、内核模块、WMI 三处都没有它 → 这台机器已经干净。' }

# ---------- 3) 文件都在哪几处 ----------
WB ''
WB '==== 3) 文件副本位置（删之前必须知道有几处）===='
$targets = @()
$targets += 'C:\Windows\System32\drivers\ThrottleStop.sys'
foreach ($d in @('C:\ProgramData\CMP40HXGen2\drivers', 'C:\ProgramData\40HXUnlock\drivers')) {
  $targets += (Join-Path $d 'ThrottleStop.sys')
  $targets += (Join-Path $d 'ThrottleStop.sys.b64')
}
# 还从自启项里抠出厂商安装器目录（只扫那个 exe 自己的目录子树，绝不向上退层）
$vendorDirs = @()
foreach ($rk in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
  try { $pp = Get-ItemProperty -LiteralPath $rk -ErrorAction Stop } catch { continue }
  foreach ($n in @($pp.PSObject.Properties)) {
    if ($n.Name -match '^PS') { continue }
    $v = '' + $n.Value
    if ($v -match '40HX|ThrottleStop|40HXUnlock|40HXGen2') {
      $m = [regex]::Match($v, '"([A-Za-z]:\\[^"]+\.exe)"|^([A-Za-z]:\\[^"]+\.exe)')
      if ($m.Success) {
        $exe = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        $dir = Split-Path -Parent $exe
        if ($dir -and $dir -notmatch '^[A-Za-z]:\\?$' -and $dir -notmatch '^[A-Za-z]:\\Windows') { $vendorDirs += $dir }
      }
    }
  }
}
if ($vendorDirs.Count) { WB ('  从自启项里找到的厂商目录（只在这些目录里找副本）: ' + (($vendorDirs | Select-Object -Unique) -join ' ; ')) }
else { WB '  自启项里没有指向 40HX/ThrottleStop 的项（好事）' }
foreach ($vd in ($vendorDirs | Select-Object -Unique)) {
  if (Test-Path -LiteralPath $vd) {
    Get-ChildItem -LiteralPath $vd -Recurse -Filter 'ThrottleStop*' -ErrorAction SilentlyContinue |
      Select-Object -First 10 | ForEach-Object { $targets += $_.FullName }
  }
}
$found = 0
foreach ($t in ($targets | Select-Object -Unique)) {
  if (Test-Path -LiteralPath $t) {
    $i = Get-Item -LiteralPath $t
    $h = ''
    if ($i.Length -lt 1048576) { try { $h = (Get-FileHash -LiteralPath $t -Algorithm SHA256).Hash.Substring(0, 16) } catch { $h = '(读不到)' } }
    WB ('  ★ ' + $t)
    WB ('      ' + $i.Length + ' B   改于 ' + $i.LastWriteTime + '   sha256前16位=' + $h)
    $found++
  }
}
if ($found -eq 0) { WB '  （以上标准位置都没有文件 —— 已经退场过）' }
if ($Deep) {
  WB '  -- 顺带扫 ESP 上的兜底副本（\EFI\40HX\drv\）--'
  foreach ($L in @('Y', 'X', 'W', 'V', 'U')) {
    if (Test-Path ($L + ':\')) { continue }
    & mountvol ($L + ':') /s 2>&1 | Out-Null
    try {
      $espf = $L + ':\EFI\40HX\drv\ThrottleStop.sys'
      if (Test-Path -LiteralPath $espf) { $i = Get-Item -LiteralPath $espf; WB ('  ★ ' + $espf + '   ' + $i.Length + ' B   ' + $i.LastWriteTime) ; $found++ }
      else { WB ('  ' + $L + ':\EFI\40HX\drv 下没有 ThrottleStop 副本') }
    } finally { & mountvol ($L + ':') /d 2>&1 | Out-Null }
    break
  }
} else {
  WB '  （ESP 兜底副本没扫 —— 需要时加 -Deep；包里的安装/自愈不会再恢复 ThrottleStop）'
}

# ---------- 4) 谁还会把它装回来 ----------
WB ''
WB '==== 4) 谁还会加载 / 重装它（删了又回来就是这些）===='
$tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
  $a = ($_.Actions | ForEach-Object { ('' + $_.Execute) + ' ' + ('' + $_.Arguments) }) -join ' '
  ($_.TaskName -match 'ThrottleStop|40HX|Gen2|40HXUnlock') -or ($a -match 'ThrottleStop|40HX|AutoRetrain|RunPostBind|CMP40HX')
} | Where-Object { $_ })
if ($tasks.Count) {
  foreach ($t in $tasks) {
    $own = '   [厂商遗留·建议禁用]'
    if ($t.TaskName -match 'CMP40HX Gen2 PostBind') { $own = '   [我们自己的·不用动]' }
    WB ('  ★ 计划任务 ' + $t.TaskName + '  ' + $t.State + $own)
    WB ('      ' + (($t.Actions | ForEach-Object { ('' + $_.Execute) + ' ' + ('' + $_.Arguments) }) -join ' | '))
  }
}
elseif (Is-Admin) { WB '  计划任务: 没有（干净）' }
else { WB '  计划任务: 读不到（需要管理员；不等于没有）' }
$runFound = $false
foreach ($rk in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
  try { $pp = Get-ItemProperty -LiteralPath $rk -ErrorAction Stop } catch { continue }
  foreach ($n in @($pp.PSObject.Properties)) {
    if ($n.Name -match '^PS') { continue }
    if (('' + $n.Value) -match 'ThrottleStop|40HX|40HXUnlock|40HXGen2|40HXInstaller') {
      $runFound = $true
      WB ('  ★ 自启项 ' + $rk + ' → ' + $n.Name + ' = ' + $n.Value)
    }
  }
}
if (-not $runFound) { WB '  Run 自启项: 没有指向 40HX/ThrottleStop 的（干净）' }
WB '  提醒：Run 里的项**每次登录都会执行**，名字改成 *_parked/*_disabled 照样会跑 —— 要停就删掉那个值本身。'

# ---------- 5) 结论 ----------
WB ''
WB '==== 5) 结论 & 直接删掉安不安全 ===='
if ($isRunning) {
  WB '  ① 现状：驱动**正在内核里运行** → 先处理它（下面第 ② 步），否则腾讯 ACE 每次都会弹兼容性提示。'
} elseif ($isPresent) {
  WB '  ① 现状：本机**存在**它，但**没在运行** → ACE 不会因它弹窗；隐患是"哪天被拉起来"（见第 4 节）。'
} else {
  WB '  ① 现状：服务、内核、WMI 三处都没有它 → 这台机器已经干净。'
}
WB '  ② 会不会蓝屏 / 开不了机？（2026-10-04 本机实测，结论是：都不会）'
WB '     · 删一个**文件**不会蓝屏：它不是正在执行的代码。代价只是"以后谁去加载它就失败" —— 实测'
WB '       `sc start` 一个指向不存在文件的驱动 = 失败 2「系统找不到指定的文件」+ 一条 7000 事件，系统照常。'
WB '     · 也不会开不了机：本机每轮开机都有两条 7026「引导启动或系统启动驱动程序未加载」（系统自带 dam / uiomap），'
WB '       机器照常进系统；启动类驱动加载失败只是记事件。会 0x7B 蓝屏的只有"启动阶段必需的存储/文件系统类驱动"，与本驱动无关。'
WB '     · 唯一要小心的是**先停再删**：驱动正在运行且被程序（厂商工具/托盘）通过 \\.\ThrottleStop 句柄占着时，'
WB '       文件删不掉（提示"正由另一进程使用"），`sc stop` 也会卡在 STOP_PENDING → 必须先结束持句柄的进程。'
WB '  ③ 正确退役顺序（本包 ACE修复.cmd /fix 用的就是这套，走的是"挪走"而不是"删除"）:'
WB '       1) 结束持有句柄的进程（厂商 Gen2 工具/AutoRetrain/托盘），再 `sc stop <服务>`（有界等待，别死等）'
WB '       2) 删掉**所有**指向它的服务（注册表枚举出来的，名字不限，XxxName 改了也算）'
WB '       3) 把所有副本（System32 + 两个 ProgramData 源目录 + 厂商目录 + ESP 兜底）**移到备份目录**（可还原）'
WB '       4) 复查：指向它的服务 0 个、原路径文件不存在 → 完成'
WB '  ④ 只删文件、不删服务会怎样：以后每次开机都会记 7000/7026，厂商工具会报 `cannot open \\.\ThrottleStop`（退出码 10）——'
WB '     不致命，但日志噪音大、排查会被误导，所以别图省事。'
WB '  ⑤ 删掉之后的代价（要告知用户）：厂商的 legacy Gen2 路径（AutoRetrain + ThrottleStop）就没法用了，'
WB '     只能走包里的新路径（inpoutx64 / WinRing0 / ECAM）—— 这正是我们要的效果，且新路径本机已实测能上 Gen2 x16。'
WB '  ⑥ 删了又回来 = 有自启项/厂商安装器在重装它（见第 4 节）→ 先清自启项，再退役文件。'
WB ''
WB '  需要发回给我方排查时，把这些一起发：'
WB '    · 上面这份报告文件本身'
WB '    · C:\ProgramData\CMP40HXGen2\windows\logs\postbind.log 与 retrain-last.log'

Save
WB ''
WB ('报告已存: ' + $out)
