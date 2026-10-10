#Requires -Version 5.1
<#
  40HX诊断.ps1  (诊断包 2026-09-30)
  =====================================================================
  用途：CMP 40HX 一键包"装完重启黑屏 1~2 分钟、进系统后设备管理器代码 43"现场取证。
  ★ 只读：不改注册表、不写 ESP/NVRAM、不 create/start 任何驱动或服务、不停/起反作弊、
         不读写 GPU 寄存器。可以放心在任何机器上跑（需要管理员才能读全）。
  产出：桌面 40HX诊断报告-<机器名>-<时间>.txt   （GBK 编码，微信/记事本都能直接看）
        桌面 40HX诊断-<时间>\  原始日志副本（40hx_log.txt / postbind.log / retrain-last.log …）
  用法：双击同目录 一键诊断.cmd（自动提权）
        或管理员 PowerShell: powershell -ExecutionPolicy Bypass -File 40HX诊断.ps1
#>
[CmdletBinding()]
param([switch]$Elevated)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(936) } catch { }

$script:R = New-Object System.Collections.ArrayList
$script:RawDir = $null
$script:Problems = New-Object System.Collections.ArrayList
$script:Ans = @{}

function Ln  { param([string]$s = '') [void]$script:R.Add([string]$s) }
function Ttl  { param([string]$s) Ln ''; Ln ('======== ' + $s + ' ========') }
function Ind  { param([string]$s) Ln ('  ' + [string]$s) }
function KV  { param([string]$k, [string]$v) Ln ('  ' + $k.PadRight(22) + ': ' + $v) }
function Step { param([string]$s) Write-Host ('  [采集中] ' + $s) -ForegroundColor Cyan }
function Native { param([scriptblock]$b) $p = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { return (& $b) } finally { $ErrorActionPreference = $p } }
function Sec { param([string]$name, [scriptblock]$body) Ttl $name; try { & $body } catch { Ind ('[本段异常] ' + $_.Exception.Message); try { Ind ('  行号 ' + $_.InvocationInfo.ScriptLineNumber + ' : ' + $_.InvocationInfo.Line.Trim()) } catch { } } }

# LocationInfo（中文系统是 "PCI 总线 1、设备 0、功能 0"，英文是 "PCI bus 1, device 0, function 0"）
# → 统一取前三个数字当 bus/dev/fn，避免中英文两套正则（首版只认英文 → 中文系统上判据 B 读不到）
function Get-BdfFromLoc {
  param([string]$loc)
  $m = [regex]::Matches([string]$loc, '\d+')
  if ($m.Count -lt 3) { return $null }
  $b = [int]$m[0].Value; $dv = [int]$m[1].Value; $fn = [int]$m[2].Value
  return [pscustomobject]@{ Bus = $b; Dev = $dv; Fn = $fn; Hex = ('0x' + ('{0:X4}' -f (($b -shl 8) -bor ($dv -shl 3) -bor $fn))) }
}

function SvcStateHint {
  param([string]$n)
  try { $q = (sc.exe query $n 2>&1 | Out-String); if ($q -match 'STATE\s*:\s*\d+\s+(\S+)') { return $Matches[1] } } catch { }
  return ''
}

# 挂载 ESP（只读用途；分两步：先找已挂载的，没有再自己挂一个）
$script:EspRoot = $null
$script:EspMountedByMe = $null
function Mount-Esp {
  if ($script:EspRoot) { return $script:EspRoot }
  foreach ($dl in @('Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K')) {
    if ((Test-Path ($dl + ':\EFI\Boot')) -or (Test-Path ($dl + ':\EFI\Microsoft'))) { $script:EspRoot = $dl + ':'; return $script:EspRoot }
  }
  foreach ($dl in @('Y','X','W','V','U','T','S','R','Q')) {
    if (-not (Test-Path ($dl + ':\'))) {
      Native { mountvol ($dl + ':') /S 2>&1 | Out-Null }
      if ((Test-Path ($dl + ':\EFI\Boot')) -or (Test-Path ($dl + ':\EFI\Microsoft'))) { $script:EspRoot = $dl + ':'; $script:EspMountedByMe = $dl + ':'; return $script:EspRoot }
    }
  }
  return $null
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$desk  = [Environment]::GetFolderPath('Desktop')
if (-not $desk) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
# 2026-10-01b（第三方审查 H18）：以 SYSTEM（计划任务）跑时"桌面"会解析到 systemprofile，
#   客户根本看不到报告 → 落到 C:\Users\Public\Desktop（所有用户可见）。
if ($desk -match 'systemprofile|Windows\\System32\\config') { $desk = 'C:\Users\Public\Desktop' }
$reportPath = Join-Path $desk ('40HX诊断报告-' + $env:COMPUTERNAME + '-' + $stamp + '.txt')
$script:RawDir = Join-Path $desk ('40HX诊断-' + $stamp)
if (-not (Test-Path $script:RawDir)) { New-Item -ItemType Directory -Force -Path $script:RawDir | Out-Null }

# ------------------------------------------------------------------ 报告头
Ln 'CMP 40HX 一键包 —— 装完重启黑屏 / 设备管理器代码 43  现场诊断报告'
Ln ('生成时间 : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Ln ('计算机名 : ' + $env:COMPUTERNAME + '     管理员: ' + $admin)
Ln ('系统     : ' + [Environment]::OSVersion.VersionString)
Ln ''
Ln '说明：本报告由 40HX诊断.ps1 只读采集（未修改任何设置）。请把整个 txt 连同'
Ln ('      桌面的 ' + (Split-Path -Leaf $script:RawDir) + ' 文件夹（或它的 zip）一起发回来。')
Ln ''
Ln '★★ 最需要回答的 4 个问题（写在报告最后"待回答"一节，或直接微信说）：'
Ln '   1) 显示器插在哪块卡上？（主板核显 / 另一张独显 / 就插在 40HX 上）'
Ln '   2) 黑屏出现在哪个阶段？（BIOS logo 之后就一直黑 / Windows 转圈时黑 / 转完圈该出桌面时黑）'
Ln '   3) 完全关机再开（不是重启）试过吗？黑屏/43 会不会消失？'
Ln '   4) 装本包之前，机器上装过厂商版 40HX 解锁工具/显卡超频工具吗？'

# ------------------------------------------------------------------ 0. 速判
Sec '0. 速判（自动判定，先看这里）' {
  Step '速判'
  $gspLine = ''; $gspVal = ''; $smiPath = ''
  $cands = @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:SystemRoot\SysWOW64\nvidia-smi.exe")
  foreach ($c in $cands) { if (Test-Path $c) { $smiPath = $c; break } }
  if (-not $smiPath) { $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue; if ($cmd) { $smiPath = $cmd.Source } }
  $q = ''
  if ($smiPath) {
    $q = (Native { & $smiPath -q 2>&1 } | Out-String)
    $m = [regex]::Match($q, '(?im)^\s*GSP Firmware Version\s*:\s*(.+?)\s*$')
    if ($m.Success) { $gspLine = $m.Value.Trim(); $gspVal = $m.Groups[1].Value.Trim() }
  }
  $clsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
  $cfEntries = New-Object System.Collections.ArrayList
  $cfNvidia = ''
  foreach ($sub in (Get-ChildItem $clsKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
    $dd = (Get-ItemProperty $sub.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
    $mid = (Get-ItemProperty $sub.PSPath -Name MatchingDeviceId -ErrorAction SilentlyContinue).MatchingDeviceId
    $ef  = (Get-ItemProperty $sub.PSPath -Name EnableGpuFirmware -ErrorAction SilentlyContinue).EnableGpuFirmware
    if ($dd -or $mid) { [void]$cfEntries.Add(('{0} DriverDesc="{1}" MatchingDeviceId="{2}" EnableGpuFirmware={3}' -f $sub.PSChildName, $dd, $mid, $(if ($null -eq $ef) { '<无>' } else { $ef }))) }
    if (($mid -match 'VEN_10DE&DEV_1F0B') -or ($dd -match 'CMP 40HX')) { $cfNvidia = ('{0} (EnableGpuFirmware={1})' -f $sub.PSChildName, $(if ($null -eq $ef) { '<无>' } else { $ef })) }
  }
  $pEF = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters' -Name EnableGpuFirmware -ErrorAction SilentlyContinue).EnableGpuFirmware
  $gspOn = ($gspVal -and $gspVal -notmatch '^(N/?A|-{1,}|未知)$')
  Ln ''
  Ln '[判据 A] GSP 固件（解锁后驱动能否认卡的决定项）'
  KV 'nvidia-smi' $(if ($smiPath) { $smiPath } else { '找不到（没装驱动？）' })
  KV 'GSP 行' $(if ($gspLine) { $gspLine } else { '<nvidia-smi -q 里没有这一行 / 没跑成>' })
  # 2026-10-10b：VBIOS 版本是案例对照的关键字段（.04 vs .06 结局不同）——显式提取，不埋在"关键行"里
  $script:VbiosVer = ''
  if ($q) { $mv = [regex]::Match($q, '(?im)^\s*VBIOS Version\s*:\s*(\S+)'); if ($mv.Success) { $script:VbiosVer = $mv.Groups[1].Value.Trim() } }
  KV 'VBIOS 版本' $(if ($script:VbiosVer) { $script:VbiosVer } else { '<读不到：NVML 没初始化/驱动异常，修好驱动后重跑本诊断就有了>' })
  KV '显示类子键(40HX)' $(if ($cfNvidia) { $cfNvidia } else { '没找到 40HX 的显示类子键' })
  # 2026-09-30：真正说了算的是 Enum\<设备实例>\Driver 指到的那个子键，光看 DriverDesc 可能挑错
  $authIdx = ''
  try {
    $d40 = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'DEV_1F0B' }) | Select-Object -First 1
    if ($d40) {
      $dk = [string](Get-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $d40.InstanceId) -Name 'Driver' -ErrorAction SilentlyContinue).Driver
      if ($dk -match '\\([0-9]{4})$') { $authIdx = $Matches[1] }
    }
  } catch { }
  KV '权威显示类子键' $(if ($authIdx) { $authIdx + '（Enum\<实例>\Driver）' } else { '读不到' })
  $script:GpuSubsys = ''
  if ($d40 -and ($d40.InstanceId -match 'SUBSYS_([0-9A-Fa-f]{8})')) { $script:GpuSubsys = $Matches[1] }
  KV 'nvlddmkm\Parameters' $(if ($null -eq $pEF) { '无 EnableGpuFirmware' } else { 'EnableGpuFirmware=' + $pEF })
  $hbNow = ''
  try { $hbNow = [string](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue).HiberbootEnabled } catch { }
  KV '快速启动' $(if ($hbNow -eq '1') { '开着（HiberbootEnabled=1）← 混合关机，驱动不重载' } elseif ($hbNow -eq '') { '注册表未设置（按关处理）' } else { '已关闭（HiberbootEnabled=' + $hbNow + '）' })
  $gspFw = @(Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Include 'gsp_tu10x.bin','gsp_ga10x.bin' -ErrorAction SilentlyContinue)
  KV 'GSP 固件文件' $(if ($gspFw.Count -gt 0) { ($gspFw | ForEach-Object { $_.Name + ' ' + [math]::Round($_.Length / 1MB, 1) + 'MB' }) -join ', ' } else { '驱动库里没找到 gsp_*.bin（驱动包装不全 → GSP 永远起不来）' })
  if ($gspOn) { Ln '   → 判定：GSP 已启用（正常，不是 43 的原因）' }
  elseif ($cfNvidia -match 'EnableGpuFirmware=1') {
    Ln '   → 判定：**开关已经是 1，但 GSP 仍是 N/A** —— 说明驱动从来没在开机时重新初始化过。'
    Ln '     最常见原因：① 快速启动开着（"关机"是混合关机，内核/驱动从 hiberfile 恢复，nvlddmkm 不重载）'
    Ln '                 ② 装完驱动后一直没真正冷启动过  ③ 驱动包里缺 GSP 固件（看上面"GSP 固件文件"行）'
    Ln '     处理：把快速启动关掉（控制面板→电源选项→选择电源按钮的功能→更改当前不可用的设置→取消"启用快速启动"）'
    Ln '           或用一键包 -Mode Repair（会自动写 HiberbootEnabled=0）→ 然后**完全关机**再开机 → 重跑本诊断复核'
  }
  else {
    Ln '   → 判定：GSP 未启用！解锁固件一旦生效，nvlddmkm 会认不了这张卡 = 黑屏 + 设备管理器代码 43。'
    Ln '     一键包旧版有两个缺陷会走到这里：①识别 GSP 时把 "N/A" 当成"已开启"；②把 EnableGpuFirmware'
    Ln '     写到了 HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters（驱动不读这里），'
    Ln '     正确位置是 显示类子键 ...\Control\Class\{4d36e968-...}\<000X>（就是上面"权威显示类子键"那个）。'
    Ln '     一键包 2026-09-30 起已修：写对位置 + 关快速启动；跑 -Mode Repair 后**完全关机**再开机。'
  }
  # 判据 B：显卡拓扑
  $inst40 = ''
  try {
    $dev = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VEN_10DE' }
    foreach ($d in @($dev)) { if ($d.InstanceId -match 'DEV_1F0B') { $inst40 = $d.InstanceId } }
    if (-not $inst40 -and @($dev).Count -gt 0) { $inst40 = @($dev)[0].InstanceId }
  } catch { }
  $bdf = ''; $bdfHex = ''; $parent = ''; $parentBdf = ''; $parentHex = ''
  if ($inst40) {
    try {
      $li = (Get-PnpDeviceProperty -InstanceId $inst40 -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data
      $lb = Get-BdfFromLoc $li
      if ($lb) { $bdf = ('bus {0} / dev {1} / fn {2}' -f $lb.Bus, $lb.Dev, $lb.Fn); $bdfHex = $lb.Hex }
      else { $bdf = '解析失败: ' + [string]$li }
    } catch { }
    try {
      $parent = (Get-PnpDeviceProperty -InstanceId $inst40 -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
      if ($parent) {
        $pli = (Get-PnpDeviceProperty -InstanceId $parent -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data
        $pname = (Get-PnpDevice -InstanceId $parent -ErrorAction SilentlyContinue).FriendlyName
        $pb2 = Get-BdfFromLoc $pli
        if ($pb2) { $parentHex = $pb2.Hex }
        $parentBdf = ('{0}  {1}  ({2})' -f $pli, $pname, $parent)
      }
    } catch { }
  }
  Ln ''
  Ln '[判据 B] 40HX 的实际 PCIe 位置（20261004e 起新路径工具按 PnP 自动探测显卡与根端口，不再写死）'
  KV '显卡实例' $(if ($inst40) { $inst40 } else { '没找到 40HX 设备' })
  KV '显卡位置' $(if ($bdf) { $bdf + '   BDF=' + $bdfHex } else { '读不到 LocationInfo' })
  KV '父设备(根端口)' $(if ($parentBdf) { $parentBdf } else { '读不到' })
  if ($bdfHex -eq '0x0100') { Ln '   → 判定：显卡就在 01:00.0（bus1/dev0/fn0），与脚本写死值一致（新路径工具能找到卡）' }
  elseif ($bdfHex) { Ln ('   → 判定：显卡不在 01:00.0（实际 ' + $bdfHex + '）→ 新路径工具会一直等卡、120 秒后 exit 12 回落到旧路径（每次开机会多花约 2 分钟）') }
  else { Ln '   → 判定：读不到显卡位置（见第 2 节原始行），无法判断' }
  if ($parentHex -eq '0x0008') { Ln '   → 判定：父根端口就是 00:01.0，与脚本写死值一致' }
  elseif ($parentHex -and $bdfHex -eq '0x0100') { Ln ('   → 判定：显卡在 01:00.0，父根端口是 ' + $parentHex + ' —— 新版工具（20261004e 起）按 PnP 自动探测，这不是问题；retrain-last.log 里的 detect 行能核对它找没找对') }
  elseif ($parentHex) { Ln ('   → 判定：父根端口是 ' + $parentHex) }
  $script:Ans['BDF'] = $bdfHex

  # 判据 C/D：解锁固件 + 开机任务
  $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
  $espLogTime = ''; $unlocked = $false; $espLogSize = $null; $espFree = ''
  $script:EfiAbort = ''; $script:EfiResultZero = $false   # 2026-10-10：固件失败特征
  try {
    $esp0 = Mount-Esp
    if ($esp0) {
      $lp = Join-Path $esp0 '40hx_log.txt'
      if (Test-Path $lp) {
        $espLogTime = [string](Get-Item $lp).LastWriteTime
        $espLogSize = (Get-Item $lp).Length
        $txt = Get-Content -LiteralPath $lp -ErrorAction SilentlyContinue
        # 2026-10-10（客户机实测踩坑）：松匹配 'UNLOCKED' 会把日志里 "SEC2 unlocked" 这类行误当已解锁
        #   —— 必须带 SS0 值才算数；同时抓失败特征（abort = 固件守卫拒绝了这张卡）
        if ($txt -match 'UNLOCKED \(SS0=0x88888888') { $unlocked = $true }
        if ($txt -match 'abort:') { $script:EfiAbort = [string](($txt | Select-String 'abort:' | Select-Object -Last 1).Line).Trim() }
        if ($txt -match 'RESULT:.*SS0=0x00000000') { $script:EfiResultZero = $true }
        # 2026-10-10b（案例库攒样本）：POST 初态 / 写入探测 / 最终态 —— 判断"平台 vs 卡个体"的关键数据
        $all = ($txt -join "`n")
        $mI = [regex]::Match($all, '\[v55 boot\]:\s*PLM=(0x[0-9A-Fa-f]+)\s+SS0=(0x[0-9A-Fa-f]+)\s+SS1=(0x[0-9A-Fa-f]+)')
        if ($mI.Success) { $script:EfiInitPlm = $mI.Groups[1].Value; $script:EfiInitSS0 = $mI.Groups[2].Value; $script:EfiInitSS1 = $mI.Groups[3].Value }
        $mP = [regex]::Match($all, 'probe:\s*SS0=(0x[0-9A-Fa-f]+)\s+SS1=(0x[0-9A-Fa-f]+)\s+after writing')
        if ($mP.Success) { $script:EfiProbeSS0 = $mP.Groups[1].Value; $script:EfiWriteIgnored = ($mP.Groups[1].Value -ne '0x88888888') }
        $mF = [regex]::Match($all, '\[v55 final\]:\s*PLM=(0x[0-9A-Fa-f]+)\s+SS0=(0x[0-9A-Fa-f]+)\s+SS1=(0x[0-9A-Fa-f]+)')
        if ($mF.Success) { $script:EfiFinalSS0 = $mF.Groups[2].Value }
        # booter 通道才是真正的分水岭：健康卡 probe 直写也被吞（回读不变），但 booter OK 后照样 UNLOCKED；
        #   锁死卡是 booter 全 halted。别拿 probe 回读不变当"硬件拒绝"（2026-10-10b 实机对照纠正）
        $script:EfiBooterOk = ($all -match 'booter OK')
        $script:EfiBooterNotOk = (-not $script:EfiBooterOk) -and ($all -match 'not-OK|halted')
      }
      try {
        $dl = $esp0.Substring(0,2)
        $dsk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $dl + "'") -ErrorAction SilentlyContinue
        if ($dsk -and $dsk.FreeSpace) { $espFree = ('{0:N1} MB' -f ($dsk.FreeSpace/1MB)) }
      } catch { }
    }
  } catch { }
  $pb = "$env:ProgramData\CMP40HXGen2\windows\logs\postbind.log"
  $lastPb = ''; $pbVerdict = '<没有 postbind.log>'; $falsePass = ''
  if (Test-Path $pb) {
    $lines = @(Get-Content -LiteralPath $pb -ErrorAction SilentlyContinue)
    $lastPb = [string](Get-Item $pb).LastWriteTime
    # 2026-10-05：只看最后 40 行会说"看不出结论"（失败那轮会把全量读数打进来把结论挤出窗口）
    #   → 改成：取**最后一次 `==== PostBind start`** 之后的全部内容来判定。
    $tail = "`n" + (($lines | Select-Object -Last 400) -join "`n")
    $si = $tail.LastIndexOf('==== PostBind start')
    if ($si -ge 0) { $tail = $tail.Substring($si) }
    # 2026-10-05（审查 H2）：结论必须走**一条** if/elseif 链。上一版把"并发轮跳过"插成独立 if，
    #   把原来的链切断 → 新路径成功那一轮会落到 else、被覆盖成"看不出结论"（实测复现）。
    $verdictBits = @()
    if ($tail -match 'PASS:\s*Gen2 reached on the new path') { $verdictBits += '新路径 PASS' }
    elseif ($tail -match 'PASS:\s*physical Gen2 post-bind step succeeded') { $verdictBits += '旧路径 PASS' }
    elseif ($tail -match 'falling back to the legacy ACE path') { $verdictBits += '新路径失败 → 回落旧路径' }
    elseif ($tail -match 'FAIL:|EXIT=[^0]') { $verdictBits += 'FAIL / 非 0 退出' }
    else { $verdictBits += '看不出结论（贴全文）' }
    if ($tail -match 'PostBind SKIP: another round is already running') { $verdictBits += '另有并发轮被锁跳过（正常）' }
    $pbVerdict = ($verdictBits -join '；')
    # 假 PASS 识别（2026-10-05 审查 L4：不再只归因"并发抢文件"—— start/EXIT 同秒也可能是命令没执行/极快失败；
    #   所以两种判据都打印证据，让人自己判）
    if ($tail -match 'PASS:\s*Gen2 reached on the new path') {
      $msx = [regex]::Matches($tail, 'NewPath start:[^\r\n]*?(\d{2}:\d{2}:\d{2})')
      $mex = [regex]::Matches($tail, 'NewPath EXIT=0[^\r\n]*?(\d{2}:\d{2}:\d{2})')
      if (($msx.Count -gt 0) -and ($mex.Count -gt 0) -and ($msx[$msx.Count-1].Groups[1].Value -eq $mex[$mex.Count-1].Groups[1].Value)) {
        $falsePass = '★ 工具的 start 与 EXIT=0 时间戳相同 → 该轮工具很可能**根本没跑**（输出文件写不进去/被占，ERRORLEVEL 残留 0）→ 这是**假 PASS**，不代表 Gen2 到位'
      } elseif ($tail -match 'GPU final\s*:\s*Gen1') {
        $falsePass = '★ PASS 行后面跟着 GPU final: Gen1 → 结论自相矛盾，属**假 PASS**'
      }
    }
  }
  Ln ''
  Ln '[判据 C] 本次开机解锁固件跑了没有（算力解锁只在开机时由 ESP 固件写入）'
  KV '本次开机时间' $(if ($boot) { [string]$boot } else { '未知' })
  KV 'ESP 40hx_log.txt' $(if ($espLogTime) { $espLogTime + '   大小: ' + $espLogSize + ' B   UNLOCKED 行: ' + $unlocked } else { '没找到（ESP 没挂载/固件没跑/不是本包装的）' })
  if ($espFree) { KV 'ESP 剩余空间' $espFree }
  if ($script:EfiInitSS0) {
    KV '卡 POST 初态' ('SS0=' + $script:EfiInitSS0 + ' SS1=' + $script:EfiInitSS1 + ' PLM=' + $script:EfiInitPlm + $(if ($script:EfiInitSS0 -eq '0x00000004' -and $script:EfiInitSS1 -eq '0x00000001') { '   （已知健康形态）' } elseif ($script:EfiInitSS0 -eq '0x00000002' -and $script:EfiInitSS1 -eq '0x00000003') { '   （★ 已知锁死形态：写入会被吞，算力解锁会失败）' } else { '   （没见过的形态，把报告发回攒样本）' }))
    if ($null -ne $script:EfiWriteIgnored) {
      if ($unlocked -or ($script:EfiFinalSS0 -eq '0x88888888')) { KV '写入探测' ('直接写回读 ' + $script:EfiProbeSS0 + ' 没变化 —— 正常：健康卡也这样，真正解锁走 booter 通道（看下一行）') }
      else { KV '写入探测' ('写 0x88888888 回读 ' + $script:EfiProbeSS0 + ' 且本次未解锁 → 疑似锁死形态（配合 booter 行看）') }
    }
    if ($script:EfiBooterOk) { KV 'booter 通道' 'booter OK（SEC2 直载成功 —— 健康形态）' }
    elseif ($script:EfiBooterNotOk) { KV 'booter 通道' 'booter 全部 halted / not-OK —— 卡拒绝加载，锁死形态特征' }
    if ($script:EfiFinalSS0) { KV '固件结束态 SS0' $script:EfiFinalSS0 }
  }
  # 2026-10-05（客户机实测）：日志 0 字节时**不能**判"解锁失败" —— 可能是 ESP 写满/写入失败，
  #   而 Windows 侧读数（retrain-last.log 的 SS0=0x88888888）说明算力其实是解锁的。旧版这里直接下"解锁没成功"= 误判。
  if ($espLogTime -and ($espLogSize -eq 0)) {
    Ln '   → 日志文件是空的（0 字节）：**不能**据此判断解锁成功/失败（可能 ESP 写满/写入失败，或固件只建了文件没写内容）。'
    Ln '     判解锁以 Windows 侧读数为准：看下面 [判据 D] 里 retrain-last.log 的 SS0 行（0x88888888 = 已解锁）。'
    if ($espFree) { Ln ('     若 ESP 剩余空间很小（现在 ' + $espFree + '），先清 ESP 垃圾文件，再让解锁固件重跑一次。') }
  }
  elseif ($espLogTime -and -not $unlocked) { Ln '   → 固件跑了但日志里没有 UNLOCKED：按"解锁没成功"处理（但先看 [判据 D] 的 SS0：若显示 0x88888888 说明是日志机制问题，不是解锁失败）' }
  if ($script:EfiAbort) {
    Ln ('   → ★★ 固件日志里解锁被中止：' + $script:EfiAbort)
    Ln '     这张卡过不了固件的身份守卫（卡批次/修订不支持）—— 半途而废的固件序列会留下残留状态，'
    Ln '     正是"每次开机代码 43"的典型成因。建议：-Mode Uninstall 卸载本包 → 完全关机再开机 → 43 应消失；'
    Ln '     这张卡要解锁请换厂商版工具（实现不同），并把本报告发回。'
  } elseif ($script:EfiResultZero -and -not $unlocked) {
    Ln '   → ★ 固件 RESULT 行 SS0=0x00000000：解锁没生效（写不进去/守卫拒绝）—— 这张卡很可能与本包固件不兼容'
  }
  Ln ''
  Ln '[判据 D] 开机任务（Gen2 落地）'
  # retrain 工具的判定行（Gen2 为什么没落地，看这里最快）
  # 2026-10-02：新版写 retrain-last.log（每次覆盖）；老机器上是 retrain-inpout.log
  $rtLog2 = "$env:ProgramData\CMP40HXGen2\windows\logs\retrain-last.log"
  if (-not (Test-Path $rtLog2)) { $rtLegacy = "$env:ProgramData\CMP40HXGen2\windows\logs\retrain-inpout.log"; if (Test-Path $rtLegacy) { $rtLog2 = $rtLegacy } }
  if (Test-Path $rtLog2) {
    Ln '  --- retrain 完整读数（retrain-last.log）最近的判定行 ---'
    foreach ($l in (@(Get-Content -LiteralPath $rtLog2 -ErrorAction SilentlyContinue) | Select-Object -Last 120 | Where-Object { $_ -match 'vbios/driver|VulnerableDriver|detect:|GPU candidate|ROOT candidate|using GPU|pre-state|start type|BAR0 \(validated\)|BOOT0 |LINK_CONFIG_0 = |PRIV_MISC_1   = |GUARD|plan  :|final|FATAL|cleanup' } | Select-Object -Last 22)) { Ln ('    ' + $l.Trim()) }
  }
  $task = Get-ScheduledTask -TaskName 'CMP40HX Gen2 PostBind' -ErrorAction SilentlyContinue
  if ($task) {
    $ti = Get-ScheduledTaskInfo -TaskName 'CMP40HX Gen2 PostBind' -ErrorAction SilentlyContinue
    KV '任务状态' ([string]$task.State)
    KV '上次运行' ([string]$ti.LastRunTime)
    KV '上次结果' ('0x' + ('{0:X}' -f $ti.LastTaskResult))
    KV 'postbind.log 末段' $pbVerdict

    KV 'postbind.log 时间' $lastPb
  }
  else { KV '任务' '未注册（Gen2 不会自动落地）' }
  # 2026-10-05（审查 L4）：假 PASS 提示放在任务判断**之外**打（任务丢了也要报；它是日志结论层面的问题）
  if ($falsePass) { Ln ('  ' + $falsePass) }
  # 2026-10-10b（案例库）：一行指纹，客户直接把这一行发回来就能横向对照
  Ln ''
  Ln '[案例指纹] 把下面 CASE 行一起发回（攒样本判断平台规律用）'
  $bbStr = ''; $cpuStr = ''
  try { $bbi = Get-CimInstance Win32_BaseBoard -ErrorAction Stop; $bbStr = (([string]$bbi.Manufacturer) + ' ' + ([string]$bbi.Product)).Trim() } catch { }
  try { $cpuStr = [string](Get-CimInstance Win32_Processor -ErrorAction Stop).Name } catch { }
  $plat = '平台未知'
  if ($cpuStr -match 'AMD|Ryzen|EPYC|Athlon|Phenom') { $plat = 'AMD' } elseif ($cpuStr -match 'Intel|Xeon|Core|Pentium|Celeron') { $plat = 'Intel' }
  $prob43 = '?'
  try {
    $ddx = @(Get-PnpDevice -Class Display -ErrorAction Stop | Where-Object { $_.InstanceId -match 'DEV_1F0B' }) | Select-Object -First 1
    if ($ddx) { $prob43 = [string](Get-PnpDeviceProperty -InstanceId $ddx.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction Stop).Data }
  } catch { }
  $caseLine = 'CASE: ' + $(if ($bbStr) { $bbStr } else { '主板未知' }) + ' | ' + $plat +
    ' | vbios=' + $(if ($script:VbiosVer) { $script:VbiosVer } else { '?' }) +
    ' | subsys=' + $(if ($script:GpuSubsys) { $script:GpuSubsys } else { '?' }) +
    ' | initSS=' + $(if ($script:EfiInitSS0) { $script:EfiInitSS0 + '/' + $script:EfiInitSS1 } else { '?' }) +
    ' | booter=' + $(if ($script:EfiBooterOk) { 'OK' } elseif ($script:EfiBooterNotOk) { 'FAIL' } else { '?' }) +
    ' | finalSS=' + $(if ($script:EfiFinalSS0) { $script:EfiFinalSS0 } else { '?' }) +
    ' | unlocked=' + $unlocked +
    ' | abort=' + $(if ($script:EfiAbort) { $script:EfiAbort } else { '-' }) +
    ' | prob=' + $prob43 +
    ' | gen2=' + $pbVerdict
  Ln ('  ' + $caseLine)
}

# ------------------------------------------------------------------ 1. 环境
Sec '1. 机器 / 固件 / 系统' {
  Step '机器信息'
  try { $cs = Get-CimInstance Win32_ComputerSystem; KV '厂商/型号' ($cs.Manufacturer + ' / ' + $cs.Model); KV 'CPU/内存' (((Get-CimInstance Win32_Processor).Name) + ' / ' + [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) + ' GB') } catch { }
  try { $bios = Get-CimInstance Win32_BIOS; KV 'BIOS' ($bios.SMBIOSBIOSVersion + '  ' + $bios.ReleaseDate) } catch { }
  try { $bb = Get-CimInstance Win32_BaseBoard; KV '主板' ($bb.Manufacturer + ' ' + $bb.Product) } catch { }
  try { KV '固件类型' ([string](Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType) } catch { }
  try { KV 'Secure Boot' ([string](Confirm-SecureBootUEFI)) } catch { KV 'Secure Boot' '读不到' }
  try { KV '系统盘分区' ([string](Get-Disk -Number (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':'))).DiskNumber).PartitionStyle) } catch { }
  try { KV 'BitLocker' ([string](Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop).ProtectionStatus) } catch { KV 'BitLocker' '未知/无' }
  try { KV '启动模式记录' ((bcdedit /enum '{current}' 2>&1 | Select-String 'path|device' | ForEach-Object { $_.Line.Trim() }) -join ' | ') } catch { }
  try {
    $hb = [string](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue).HiberbootEnabled
    KV '快速启动' $(if ($hb -eq '1') { '开启（HiberbootEnabled=1）→ "关机"其实是混合关机，显卡驱动不会重新初始化（GSP 这类改动永远不生效）' } elseif ($hb -eq '') { '注册表未设置（按已关处理）' } else { '已关闭（HiberbootEnabled=' + $hb + '）' })
  } catch { }
  try { KV 'powercfg /a' (((powercfg /a 2>&1) | Where-Object { $_ -match '休眠|快速启动|Hibernate|Hybrid|待机' } | ForEach-Object { $_.Trim() }) -join ' ; ') } catch { }
  KV '火绒' ([string]((Test-Path 'C:\ProgramData\Huorong') -or (Test-Path 'C:\Program Files (x86)\Huorong')))
  try { KV 'Defender 实时' ([string]((Get-MpPreference -ErrorAction Stop).DisableRealtimeMonitoring)) } catch { KV 'Defender 实时' '读不到/无' }
}

# ------------------------------------------------------------------ 2. 显卡 / 显示
Sec '2. 显卡 / 显示输出（黑屏和 43 都跟这里有关）' {
  Step '显卡与显示'
  Ln '--- 所有显示类设备（Status / 错误码 / 驱动版本 / 位置）---'
  foreach ($d in @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Sort-Object Status)) {
    $prob = ''; $li = ''
    try { $prob = [string](Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data } catch { }
    try { $li = [string](Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data } catch { }
    $dv = ''; try { $dv = [string](Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction SilentlyContinue).Data } catch { }
    Ln ('  - ' + $d.FriendlyName + '  [' + $d.Status + ']  Problem=' + $(if ($prob) { $prob + $(if ($prob -eq '43') { '(=代码43!)' } else { '' }) } else { '?' }) + '  位置=' + $li + '  驱动=' + $dv)
    Ln ('    ' + $d.InstanceId)
  }
  Ln ''
  Ln '--- Win32_VideoController（谁在输出画面）---'
  foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
    Ln ('  - ' + $v.Name + '  Status=' + $v.Status + '  ConfigManagerErrorCode=' + $v.ConfigManagerErrorCode + '  分辨率=' + $v.CurrentHorizontalResolution + 'x' + $v.CurrentVerticalResolution + '  AdapterCompatibility=' + $v.AdapterCompatibility)
  }
  Ln ''
  Ln '--- 显示器 ---'
  foreach ($m in @(Get-CimInstance Win32_DesktopMonitor -ErrorAction SilentlyContinue)) { Ln ('  - ' + $m.Name + '  ' + $m.ScreenWidth + 'x' + $m.ScreenHeight + '  Availability=' + $m.Availability) }
  Ln ''
  Ln '--- 所有 PCI 根端口 / 桥（看 40HX 挂在哪条链路下）---'
  foreach ($rp in @(Get-PnpDevice -Class System -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Root Port|PCI-to-PCI|PCI Express|Host Bridge' })) {
    $li = ''; try { $li = [string](Get-PnpDeviceProperty -InstanceId $rp.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data } catch { }
    Ln ('  - [' + $rp.Status + '] ' + $rp.FriendlyName + '   位置=' + $li)
  }
  Ln ''
  Ln '--- 非正常状态的设备（Problem ≠ 0）---'
  $bad = 0
  foreach ($d in @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' -and $_.Status -ne 'Unknown' })) {
    $prob = ''; try { $prob = [string](Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data } catch { }
    Ln ('  - [' + $d.Status + '] Problem=' + $prob + '  ' + $d.FriendlyName)
    $bad++
  }
  if ($bad -eq 0) { Ln '  （没有异常设备）' }
}

# ------------------------------------------------------------------ 3. nvidia-smi
Sec '3. nvidia-smi 原文（GSP / 驱动 / 链路 / 报错）' {
  Step 'nvidia-smi'
  $smi = "$env:SystemRoot\System32\nvidia-smi.exe"
  if (-not (Test-Path $smi)) { $smi = '' ; $c = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue; if ($c) { $smi = $c.Source } }
  if (-not $smi) { Ind '找不到 nvidia-smi.exe（没装 NVIDIA 驱动？）—— 这本身就是重要信息'; }
  else {
    KV '路径' $smi
    $q = (Native { & $smi -q 2>&1 } | Out-String)
    if ($q) { [IO.File]::WriteAllText((Join-Path $script:RawDir 'nvidia-smi-q.txt'), $q, [Text.Encoding]::GetEncoding(936)) }
    $lines = $q -split "`r?`n"
    Ln '  --- nvidia-smi -q 关键行 ---'
    foreach ($l in $lines) { if ($l -match 'GSP|Driver Version|Driver Model|CUDA Version|Product Name|Product Brand|VBIOS|Bus Id|PCIe|Link Width|Link Speed|Error|ERROR|Unable|Failure') { Ln ('    ' + $l.TrimEnd()) } }
    Ln '  --- 首个 ERROR 段（如果有）---'
    $idx = ($lines | Select-String -Pattern 'ERROR' | Select-Object -First 1)
    if ($idx) { Ln ('    ' + $idx.Line.Trim()) } else { Ln '    （无 ERROR 行）' }
    Ln '  --- 链路查询 ---'
    $csv = (Native { & $smi --query-gpu=name,driver_version,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv 2>&1 } | Out-String)
    foreach ($l in ($csv -split "`r?`n")) { if ($l.Trim()) { Ln ('    ' + $l.Trim()) } }
  }
}

# ------------------------------------------------------------------ 4. 注册表 / 服务
Sec '4. GSP 注册表 + 相关服务' {
  Step '注册表与服务'
  $clsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
  Ln '--- 显示类注册表（EnableGpuFirmware 就在这里才对）---'
  foreach ($sub in (Get-ChildItem $clsKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
    $dd = (Get-ItemProperty $sub.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
    $mid = (Get-ItemProperty $sub.PSPath -Name MatchingDeviceId -ErrorAction SilentlyContinue).MatchingDeviceId
    $ef = (Get-ItemProperty $sub.PSPath -Name EnableGpuFirmware -ErrorAction SilentlyContinue).EnableGpuFirmware
    Ln ('  ' + $sub.PSChildName + '  DriverDesc="' + $dd + '"  MatchingDeviceId="' + $mid + '"  EnableGpuFirmware=' + $(if ($null -eq $ef) { '<无>' } else { $ef }))
  }
  Ln '--- 权威子键（Enum\<设备实例>\Driver，驱动真正读的就是这个）---'
  try {
    foreach ($d in @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VEN_10DE' })) {
      $dk = [string](Get-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $d.InstanceId) -Name 'Driver' -ErrorAction SilentlyContinue).Driver
      Ln ('  ' + $d.InstanceId + '  →  Driver = ' + $dk)
    }
  } catch { }
  Ln '--- 驱动库里的 GSP 固件文件（缺了 GSP 永远起不来）---'
  $fw = @(Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Include 'gsp_*.bin' -ErrorAction SilentlyContinue)
  if ($fw.Count -gt 0) { foreach ($f in $fw) { Ln ('  ' + $f.FullName.Replace('C:\Windows\System32\DriverStore\FileRepository\','') + '  ' + $f.Length + ' B') } }
  else { Ln '  没找到 gsp_*.bin（驱动包被裁剪过 / 不是官方驱动包 → GSP 起不来）' }
  Ln '--- 显示驱动包（nv_dispi/nvac 等）---'
  Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^nv' } | ForEach-Object { Ln ('  ' + $_.Name) }
  Ln '--- Services\nvlddmkm\Parameters（本包旧版写错的位置）---'
  $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters'
  $v = (Get-ItemProperty $k -Name EnableGpuFirmware -ErrorAction SilentlyContinue).EnableGpuFirmware
  Ln ('  EnableGpuFirmware = ' + $(if ($null -eq $v) { '<无>' } else { $v }))
  Ln '  （整棵树里搜 EnableGpuFirmware）'
  $srch = (Native { reg query 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm' /s /f EnableGpuFirmware 2>&1 } | Out-String)
  Ln ('  ' + (($srch -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | '))
  Ln '--- 服务 ---'
  foreach ($s in @('ThrottleStop', 'WinRing0_1_2_0', 'inpoutx64T', 'nvlddmkm', 'ACE-BOOT')) {
    $q = (Native { sc.exe qc $s 2>&1 } | Out-String)
    $state = (Native { sc.exe query $s 2>&1 } | Out-String)
    $start = ''; if ($q -match 'START_TYPE\s*:\s*(\d+)\s+(\S+)') { $start = $Matches[1] + ' ' + $Matches[2] }
    $st2 = ''; if ($state -match 'STATE\s*:\s*\d+\s+(\S+)') { $st2 = $Matches[1] }
    Ln ('  ' + $s.PadRight(16) + ' 存在=' + [string]($q -notmatch '1060') + '  Start=' + $start + '  当前=' + $(if ($st2) { $st2 } else { '非运行/不存在' }))
  }
  if ((SvcStateHint 'WinRing0_1_2_0') -eq 'STOP_PENDING') {
    Ln '  ★ WinRing0_1_2_0 = STOP_PENDING：上次 stop 没收尾（进程被强杀/文件被删）→ 新路径开机时会 start 失败、' 
    Ln '    回落到旧路径（EXIT=31/30）。2026-09-30 起的一键包会先等它落定再重试；通常重启一次就好了。'
  }
  try {
    $tray = @(Get-Process 'ACE-Tray' -ErrorAction SilentlyContinue)
    if ($tray.Count -gt 0) { Ln ('  ACE-Tray 进程: 运行中  PID=' + (($tray | ForEach-Object { $_.Id }) -join ',') + '  启动于 ' + $tray[0].StartTime) }
    else { Ln '  ACE-Tray 进程: 未运行' }
  } catch { }
  Ln '--- ACE / 其它反作弊目录 ---'
  foreach ($pth in @('C:\Program Files\AntiCheatExpert', 'C:\Program Files (x86)\AntiCheatExpert', 'C:\ProgramData\Huorong')) { Ln ('  ' + $pth + ' 存在=' + (Test-Path $pth)) }
  Ln '--- HKLM\SOFTWARE\40HXUnlock 策略键 ---'
  if (Test-Path 'HKLM:\SOFTWARE\40HXUnlock') { foreach ($n in (Get-Item 'HKLM:\SOFTWARE\40HXUnlock').Property) { Ln ('  ' + $n + ' = ' + (Get-ItemProperty 'HKLM:\SOFTWARE\40HXUnlock' -Name $n).$n) } }
  else { Ln '  键不存在（一键包旧版只在"已存在"时才写 Gen2AutoHard/Gen2PnpFallback=0）' }
}

# ------------------------------------------------------------------ 5. 一键包安装物
Sec '5. 一键包安装物（文件 / 任务 / 启动项）' {
  Step '安装物'
  $files = @(
    "$env:ProgramData\CMP40HXGen2\windows\RunPostBind.cmd",
    "$env:ProgramData\CMP40HXGen2\windows\40hx-retrain-inpout.ps1",
    "$env:ProgramData\CMP40HXGen2\windows\CMP40HXGen2.exe",
    "$env:ProgramData\CMP40HXGen2\windows\ACE-Toggle.ps1",
    "$env:ProgramData\CMP40HXGen2\drivers\ThrottleStop.sys",
    "$env:ProgramData\CMP40HXGen2\drivers\WinRing0x64.sys",
    "$env:ProgramData\CMP40HXGen2\drivers\inpoutx64.sys",
    "$env:ProgramData\CMP40HXGen2\drivers\inpoutx64.dll",
    "$env:SystemRoot\System32\drivers\ThrottleStop.sys",
    "$env:SystemRoot\System32\drivers\WinRing0x64.sys",
    "$env:SystemRoot\System32\drivers\inpoutx64.sys"
  )
  foreach ($f in $files) {
    if (Test-Path $f) {
      $h = ''; try { $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.Substring(0, 16) } catch { }
      Ln ('  [有] ' + $f + '  ' + (Get-Item $f).Length + ' B  ' + (Get-Item $f).LastWriteTime + '  sha256=' + $h)
    } else { Ln ('  [无] ' + $f) }
  }
  Ln '--- 计划任务（所有含 40HX/Gen2 的，含厂商的）---'
  foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '40HX|Gen2|CMP40HX' })) {
    $ti = Get-ScheduledTaskInfo -TaskName $t.TaskName -ErrorAction SilentlyContinue
    $trg = ($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ','
    $act = ($t.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -join ' '
    Ln ('  ' + $t.TaskName + '  State=' + $t.State + '  触发=' + $trg + '  身份=' + $t.Principal.UserId + '/' + $t.Principal.RunLevel)
    Ln ('     动作: ' + $act)
    Ln ('     上次: ' + $ti.LastRunTime + '  rc=0x' + ('{0:X}' -f $ti.LastTaskResult))
  }
  Ln '--- 自启项（Run 键里含 40HX/Gen2 的）---'
  foreach ($rk in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
    $p = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
    if ($p) { foreach ($n in $p.PSObject.Properties.Name) { if (($n -match '40HX|Gen2') -or ([string]$p.$n -match '40HX|Gen2')) { Ln ('  ' + $rk + ' \ ' + $n + ' = ' + $p.$n) } } }
  }
}

# ------------------------------------------------------------------ 6. 日志
Sec '6. 一键包日志（判定"哪条路跑了、跑成什么样"）' {
  Step '日志'
  $logDir = "$env:ProgramData\CMP40HXGen2\windows\logs"
  if (Test-Path $logDir) {
    # 2026-10-02（第三方审查）：原来只列顶层文件 → logs\failures\（失败留档）与其它子目录收不进报告。
    #   改成递归，并按相对路径还原目录结构（同名文件不会互相覆盖）。
    foreach ($f in @(Get-ChildItem $logDir -Recurse -File -ErrorAction SilentlyContinue)) {
      $rel = $f.FullName.Substring($logDir.Length).TrimStart('\')
      Ln ('  - ' + $rel + '  ' + $f.Length + ' B  ' + $f.LastWriteTime)
      try {
        $dst = Join-Path $script:RawDir $rel
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction SilentlyContinue
      } catch { }
    }
    Ln ''
    foreach ($nm in @('postbind.log', 'retrain-last.log', 'retrain-inpout.log', 'last.log', 'previous.log', 'ace-state.json')) {
      $p = Join-Path $logDir $nm
      if (Test-Path $p) {
        Ln ('  ---- ' + $nm + ' 末 60 行 ----')
        foreach ($l in (@(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue) | Select-Object -Last 60)) { Ln ('    ' + $l) }
      }
    }
  } else { Ln '  没有 ' + $logDir }
}

# ------------------------------------------------------------------ 7. ESP / NVRAM
Sec '7. ESP 上的解锁固件 + 固件启动项' {
  Step 'ESP 与 NVRAM'
  $esp = Mount-Esp
  if (-not $esp) { Ln '  （没挂到 ESP：非管理员或 mountvol 失败）' }
  if ($esp) {
    KV 'ESP 挂载于' $esp
    foreach ($f in @('EFI\40HX\40HXUNLK.EFI', 'EFI\Boot\bootx64.efi', 'EFI\Boot\bootx64.efi.40hx.bak')) {
      $p = Join-Path $esp $f
      if (Test-Path $p) {
        $h1 = ''; try { $h1 = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.Substring(0, 16) } catch { $h1 = '读取失败（非管理员时 ESP 内容读不了）' }
        Ln ('  [有] ' + $f + '  ' + (Get-Item $p).Length + ' B  ' + (Get-Item $p).LastWriteTime + '  sha256=' + $h1)
      }
      else { Ln ('  [无] ' + $f) }
    }
    $lg = Join-Path $esp '40hx_log.txt'
    if (Test-Path $lg) {
      Ln ('  ---- ESP 40hx_log.txt 末 40 行（时间 ' + (Get-Item $lg).LastWriteTime + '）----')
      try { Copy-Item -LiteralPath $lg -Destination $script:RawDir -Force -ErrorAction SilentlyContinue } catch { }
      foreach ($l in (@(Get-Content -LiteralPath $lg -ErrorAction SilentlyContinue) | Select-Object -Last 40)) { Ln ('    ' + $l) }
    } else { Ln '  [无] ESP 根目录 40hx_log.txt（解锁固件这次开机没跑，或不是本包装的）' }
    $drvDir = Join-Path $esp 'EFI\40HX\drv'
    if (Test-Path $drvDir) {
      $df = @(Get-ChildItem $drvDir -File -ErrorAction SilentlyContinue)
      if ($df.Count -gt 0) { Ln ('  ESP 兜底驱动源: ' + (($df | ForEach-Object { $_.Name }) -join ', ')) } else { Ln '  ESP 兜底驱动源: 目录存在但**是空的**（安装时应该写进 4 个驱动文件；空 = 没写成功或被清掉了，跑一次 -Mode Repair）' }
    } else { Ln '  ESP 兜底驱动源: \EFI\40HX\drv 不存在（跑一次 -Mode Repair 补）' }
    # EFI 自己有没有因为基线不认识而放弃 Gen2（换 VBIOS 批次时常见）
    if (Test-Path $lg) {
      $lgTxt = Get-Content -LiteralPath $lg -ErrorAction SilentlyContinue
      if ($lgTxt -match 'abort: baseline mismatch') { Ln '  ★ EFI 侧：日志里有 "abort: baseline mismatch" → 解锁固件也认为这张卡的 Gen2 基线不认识，主动放弃了 Gen2 写入（VBIOS 批次不同）' }
      elseif ($lgTxt -match 'Root TLS=Gen2') { Ln '  EFI 侧：已写入 Gen2 预埋（Root TLS=Gen2）' }
    }
  } else { Ln '  （没挂到 ESP；非管理员或 mountvol 失败）' }

  # 固件变量（只读）
  if ($admin) {
    try {
      $sig = @"
using System;
using System.Runtime.InteropServices;
public class FwVarDiag {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct TP { public uint Count; public LUID Luid; public uint Attributes; }
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP nw, uint len, IntPtr prev, IntPtr ret);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint GetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  public static bool Enable() {
    IntPtr tok; if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
    LUID lu; if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out lu)) return false;
    TP tp = new TP(); tp.Count = 1; tp.Luid = lu; tp.Attributes = 0x2;
    return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
  }
  public static byte[] Read(string name) {
    byte[] buf = new byte[8192];
    uint len = GetFirmwareEnvironmentVariableW(name, "{8be4df61-93ca-11d2-aa0d-00e098032b8c}", buf, (uint)buf.Length);
    if (len <= 0 || len > buf.Length) return null;
    byte[] o = new byte[len]; Array.Copy(buf, o, (int)len); return o;
  }
}
"@
      Add-Type -TypeDefinition $sig -ErrorAction Stop | Out-Null
      [void][FwVarDiag]::Enable()
      $order = [FwVarDiag]::Read('BootOrder')
      if ($order) {
        $ol = @(); for ($i = 0; ($i + 1) -lt $order.Length; $i += 2) { $ol += ('{0:X4}' -f [BitConverter]::ToUInt16($order, $i)) }
        KV 'BootOrder' (($ol) -join ',')
      } else { KV 'BootOrder' '读不到' }
      $bn = [FwVarDiag]::Read('BootNext'); KV 'BootNext' $(if ($bn -and $bn.Length -ge 2) { '{0:X4}' -f [BitConverter]::ToUInt16($bn, 0) } else { '空' })
      Ln '  --- 全部 Boot#### ---'
      for ($i = 0; $i -le 255; $i++) {
        $name = 'Boot{0:X4}' -f $i
        $raw = [FwVarDiag]::Read($name)
        if ($raw -and $raw.Length -gt 6) {
          $idx = 6; $chars = New-Object System.Collections.ArrayList
          while (($idx + 1) -lt $raw.Length -and -not ($raw[$idx] -eq 0 -and $raw[$idx + 1] -eq 0)) { [void]$chars.Add([char][BitConverter]::ToUInt16($raw, $idx)); $idx += 2 }
          $idx += 2
          $desc = -join $chars.ToArray()
          $plLen = [int][BitConverter]::ToUInt16($raw, 4)
          $guidTxt = ''; $filePath = ''
          if (($idx + $plLen) -le $raw.Length) {
            $pl = New-Object byte[] $plLen; [Array]::Copy($raw, $idx, $pl, 0, $plLen)
            $k = 0
            while (($k + 4) -le $pl.Length) {
              $ty = $pl[$k]; $sb = $pl[$k + 1]; $ln = [int]$pl[$k + 2] + 256 * [int]$pl[$k + 3]
              if ($ty -eq 0x7F -or $ln -lt 4) { break }
              if ($ty -eq 0x04 -and $sb -eq 0x01 -and $ln -ge 40) {
                $g = New-Object byte[] 16; [Array]::Copy($pl, ($k + $ln - 18), $g, 0, 16)
                try { $guidTxt = ([Guid]::new($g)).ToString() } catch { }
              }
              if ($ty -eq 0x04 -and $sb -eq 0x04) {
                $cs = New-Object System.Collections.ArrayList
                for ($x = $k + 4; $x -lt ($k + $ln - 2); $x += 2) { [void]$cs.Add([char][BitConverter]::ToUInt16($pl, $x)) }
                $filePath = -join $cs.ToArray()
              }
              $k += $ln
            }
          }
          Ln ('    ' + $name + '  "' + $desc + '"  → ' + $filePath + '   [ESP GUID ' + $guidTxt + ']')
        }
      }
      try { KV '现场 ESP 分区 GUID' ([string](Get-Partition | Where-Object { ([string]$_.GptType).ToLower() -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -and $_.DiskNumber -eq (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':'))).DiskNumber } | Select-Object -First 1).Guid) } catch { }
      Ln '  提示：上面每条启动项的 [ESP GUID] 应与"现场 ESP 分区 GUID"一致；不一致的那条就是指向了别的磁盘的 ESP（固件找不到文件 → 开机黑屏一会儿再进系统）。'
    } catch { Ind ('[固件变量读取失败] ' + $_.Exception.Message) }
  } else { Ln '  （非管理员，跳过固件变量）' }
}

# ------------------------------------------------------------------ 8. 时间线
Sec '8. 开机时间线（"黑屏 1~2 分钟"到底卡在哪一步）' {
  Step '事件日志'
  try {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    KV '本次开机' ([string]$boot)
    KV '已运行' (([TimeSpan]((Get-Date) - $boot)).ToString())
  } catch { }
  try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddDays(-3) } -ErrorAction Stop |
      Where-Object { $_.Id -in @(12,13,20,27,41,100,7000,7026,7031,7034,219,225,26) -or $_.ProviderName -match 'nvlddmkm' } |
      Sort-Object TimeCreated)
    Ln ('  --- System 日志（近 3 天，共 ' + $ev.Count + ' 条）---')
    foreach ($e in ($ev | Select-Object -Last 120)) {
      $msg = ''
      try { $msg = (($e.Message -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 2) -join ' / ' } catch { }
      if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) }
      Ln ('    ' + $e.TimeCreated.ToString('MM-dd HH:mm:ss') + '  ' + $e.ProviderName + ' [' + $e.Id + ']  ' + $msg)
    }
  } catch { Ind ('[System 日志读取失败] ' + $_.Exception.Message) }
  foreach ($lg in @('Microsoft-Windows-Diagnostics-Performance/Operational', 'Microsoft-Windows-TaskScheduler/Operational', 'Microsoft-Windows-Kernel-Boot/Operational')) {
    try {
      $info = Get-WinEvent -ListLog $lg -ErrorAction Stop
      if ($info.IsEnabled) {
        $ev2 = @(Get-WinEvent -FilterHashtable @{ LogName = $lg; StartTime = (Get-Date).AddDays(-2) } -ErrorAction Stop | Sort-Object TimeCreated)
        Ln ('  --- ' + $lg + '（近 2 天 ' + $ev2.Count + ' 条，取末 60）---')
        foreach ($e in ($ev2 | Select-Object -Last 60)) {
          $msg = ''
          try { $msg = (($e.Message -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 2) -join ' / ' } catch { }
          if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) }
          Ln ('    ' + $e.TimeCreated.ToString('MM-dd HH:mm:ss') + '  [' + $e.Id + ']  ' + $msg)
        }
      } else { Ln ('  --- ' + $lg + ' 未启用（跳过）') }
    } catch { Ln ('  --- ' + $lg + ' 不可读（跳过）') }
  }
  try {
    Ln '  --- 本次开机前后 ±5 分钟的日志（重点看黑屏窗口里发生了什么）---'
    $boot2 = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $ev3 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $boot2.AddSeconds(-60); EndTime = $boot2.AddSeconds(300) } -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
    foreach ($e in $ev3) {
      $msg = ''; try { $msg = (($e.Message -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1) } catch { }
      if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
      Ln ('    +' + ((New-TimeSpan -Start $boot2 -End $e.TimeCreated).TotalSeconds.ToString('0')) + 's  ' + $e.ProviderName + ' [' + $e.Id + ']  ' + $msg)
    }
  } catch { }
}

# ------------------------------------------------------------------ 9. 待回答
Sec '9. 待客户回答（这几条决定下一步怎么修）' {
  Ln '  Q1 显示器插在哪块卡上（主板核显 / 另一张独显 / 40HX 改装输出）：'
  Ln '  Q2 黑屏出现在哪个阶段（BIOS logo 后一直黑 / Windows 转圈时黑 / 该出桌面时黑）：'
  Ln '  Q3 完全关机（拔电/长按电源）再开，黑屏与 43 会不会消失：'
  Ln '  Q4 装本包之前是否有厂商版 40HX 解锁工具、显卡超频工具（微星小飞机等）：'
  Ln '  Q5 40HX 插在第几个 PCIe 槽、另一个槽插了什么：'
  Ln '  Q6 设备管理器里 40HX 的属性→常规 里的"设备状态"原文（贴出来）：'
  Ln ''
  Ln '  （直接把上面几行补全后回传即可，不用跑别的命令）'
}

# ------------------------------------------------------------------ 输出
# 只读用途结束：把本脚本自己挂上的 ESP 卸掉（别人已经挂着的保持原样）
if ($script:EspMountedByMe) { Native { mountvol $script:EspMountedByMe /D 2>&1 | Out-Null } }
Ln ''
Ln '======== 报告结束 ========'
Ln ('报告文件: ' + $reportPath)
Ln ('原始日志: ' + $script:RawDir)

try {
  if (-not (Test-Path $script:RawDir)) { New-Item -ItemType Directory -Force -Path $script:RawDir | Out-Null }
  [IO.File]::WriteAllLines($reportPath, [string[]]$script:R.ToArray(), [Text.Encoding]::GetEncoding(936))
  # 顺手把 report 也拷进原始日志夹 + 打 zip
  Copy-Item -LiteralPath $reportPath -Destination $script:RawDir -Force -ErrorAction SilentlyContinue
  try {
    $zip = $script:RawDir + '.zip'
    if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    Compress-Archive -Path (Join-Path $script:RawDir '*') -DestinationPath $zip -Force -ErrorAction Stop
  } catch { Write-Host ('  （打包 zip 失败，直接发文件夹即可: ' + $_.Exception.Message + '）') -ForegroundColor Yellow }
} catch {
  # 2026-10-01b（第三方审查 H7）：写报告失败必须带退出码，否则调用方 .cmd 会显示"退出码 = 0 / 报告已生成"
  Write-Host ('写报告失败: ' + $_.Exception.Message) -ForegroundColor Red
  Write-Host '  → 报告没写成（磁盘满/权限/杀软拦）。把窗口里最后几行拍回去。' -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Green
Write-Host ' 采集完成。请把这些发回来：' -ForegroundColor Green
Write-Host ('   报告: ' + $reportPath) -ForegroundColor Green
Write-Host ('   附件: ' + $script:RawDir + '  （或同名的 .zip）') -ForegroundColor Green
Write-Host '=========================================================' -ForegroundColor Green
