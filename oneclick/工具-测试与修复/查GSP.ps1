# ============================================================
#  CMP 40HX  GSP（GPU 固件）诊断 / 修复         ver 2026-10-04b
#  默认 = 只读诊断；加 -Fix 才写注册表（写前备份）。
#  回答三件事：① GSP 到底开没开  ② 没开的话卡在哪一步  ③ 怎么修
#  用法：查GSP.cmd            只读诊断（自动提权），报告落桌面并自动打开
#        查GSP.cmd /fix       写 EnableGpuFirmware=1（备份后），之后必须“完全关机再开机”
#  作者：Hermes / 2026-10-04
# ============================================================
param(
  [switch]$Fix,
  [switch]$DryRun,
  [switch]$NoElevate,
  [string]$OutFile = '',
  [string]$ClassRoot = ''
)
$ErrorActionPreference = 'Continue'
$VER = '2026-10-04c'

$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk) { $desk = 'C:\Users\Public\Desktop' }
$out  = if ($OutFile) { $OutFile } else { Join-Path $desk ('40HX-GSP诊断-' + $env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt') }
$CLS  = if ($ClassRoot) { $ClassRoot } else { 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' }

$sb = New-Object System.Text.StringBuilder
function W  { param([string]$s = '') [void]$sb.AppendLine($s); Write-Output $s }
function Save { try { $sb.ToString() | Out-File -Encoding utf8 $out } catch { Write-Output ('  报告写盘失败: ' + $_.Exception.Message) } }
function Is-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 提权：把所有调用者给的开关都转过去（否则 -DryRun/-ClassRoot 会丢）----------
if (-not $NoElevate -and -not (Is-Admin)) {
  Write-Output '  需要管理员权限（读 DriverStore / 事件日志 / 写 GSP 开关）→ 正在请求提权（会弹 UAC，请点“是”）...'
  # 2026-10-04c（审查发现）：-ArgumentList 原样拼命令行，含空格的路径必须自带引号，否则提权子进程参数会被拆断
  $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'),'-NoElevate','-OutFile',('"' + $out + '"'))
  if ($Fix)       { $a += '-Fix' }
  if ($DryRun)    { $a += '-DryRun' }
  if ($ClassRoot) { $a += @('-ClassRoot',('"' + $ClassRoot + '"')) }
  try { Start-Process powershell -Verb RunAs -Wait -ArgumentList $a; exit 0 }
  catch { Write-Output ('  提权失败或被取消: ' + $_.Exception.Message); exit 1 }
}

W '============================================================'
W (' CMP 40HX  GSP（GPU 固件）诊断' + $(if ($Fix) { '（含修复）' } else { '（只读）' }) + '   工具版 ' + $VER)
W (' 时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   机器: ' + $env:COMPUTERNAME + '   管理员: ' + (Is-Admin))
W '============================================================'
W ''
W '【为什么要看 GSP】CMP 40HX 解锁算力后，驱动要启用 GSP（GPU 固件）才能正常认卡；'
W '                  GSP 没开最常见的结果是设备管理器「代码 43」+ 开机黑屏一下。'
W ''

# ---------- 1) 设备与驱动层 ----------
W '==== 1) 显示适配器与驱动层 ===='
$gpu = $null
$devs = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Present })
foreach ($d in $devs) {
  $pc = if ($null -eq $d.ProblemCode) { 0 } else { [int]$d.ProblemCode }
  W ('  ' + $d.FriendlyName + '   状态=' + $d.Status + '   Problem=0x' + ('{0:X}' -f $pc) + '   ' + $d.InstanceId)
  if ($d.InstanceId -match 'VEN_10DE&DEV_1F0B') { $gpu = $d }
}
if (-not $gpu) { W '  ⚠ 没找到 VEN_10DE&DEV_1F0B 这台设备（驱动没装？设备被禁用？）' }
$gpuProblem = if ($gpu -and $null -ne $gpu.ProblemCode) { [int]$gpu.ProblemCode } else { 0 }
$isBasic = [bool]($gpu -and ($gpu.FriendlyName -match '基本显示|Basic Display'))

$svcState = 'missing'; $svcStart = '?'; $svcPath = ''
$q = (sc.exe qc nvlddmkm 2>&1 | Out-String)
if ($q -match 'SERVICE_NAME') {
  if ($q -match 'START_TYPE\s*:\s*\d+\s+(\S+)') { $svcStart = $Matches[1] }
  if ($q -match 'BINARY_PATH_NAME\s*:\s*(.+)') { $svcPath = $Matches[1].Trim() }
  $s = (sc.exe query nvlddmkm 2>&1 | Out-String)
  if ($s -match 'STATE\s*:\s*\d+\s+(\S+)') { $svcState = $Matches[1] }
}
W ('  nvlddmkm 服务: ' + $svcState + '   启动类型=' + $svcStart)
if ($svcPath) { W ('    驱动镜像: ' + $svcPath) }

# nvidia-smi：用文件重定向 + 30 秒上限（管道读取在驱动卡死时会挂住整个体检）
$smi = 'C:\Windows\System32\nvidia-smi.exe'
$smiOK = $false; $smiErr = ''; $smiText = ''; $gspLine = ''
if (Test-Path $smi) {
  $so = Join-Path $env:TEMP 'gsp-smi-out.txt'
  $se = Join-Path $env:TEMP 'gsp-smi-err.txt'
  Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
  try {
    $p = Start-Process -FilePath $smi -ArgumentList '-q' -NoNewWindow -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { }; $smiErr = 'nvidia-smi 30 秒无响应（驱动卡住）' }
    else {
      if (Test-Path $so) { $smiText = (Get-Content $so -Raw -Encoding UTF8) }
      if (-not $smiText -and (Test-Path $se)) { $smiText = (Get-Content $se -Raw -Encoding UTF8) }
    }
  } catch { $smiErr = 'nvidia-smi 启动失败: ' + $_.Exception.Message }
  $m = [regex]::Match($smiText, 'GSP Firmware Version\s*:\s*(\S.*?)\s*(\r?\n|$)')
  if ($m.Success) { $gspLine = $m.Groups[1].Value.Trim() }
  # 2026-10-04c（第21轮审查发现）：原关键字漏了"驱动通信失败"那类典型输出，会让 $smiOK 误为真、
  #   打印"nvidia-smi: 可用"，把客户引去写 GSP 开关 —— 而真实病因是驱动没通。
  if (-not $smiErr -and $smiText -match "Failed to initialize NVML|No devices were found|Unable to determine|couldn.t communicate with the NVIDIA driver|NVIDIA-SMI has failed") {
    $mm = [regex]::Match($smiText, '(Failed to initialize NVML[^\r\n]*|No devices were found|Unable to determine the device handle[^\r\n]*)')
    $smiErr = if ($mm.Success) { $mm.Groups[1].Value.Trim() } else { 'nvidia-smi 未返回设备信息' }
  }
  # 2026-10-04c："可用"必须以能解析到 Driver Version 为准，异常输出不算可用
  $smiOK = [bool]($smiText -and -not $smiErr -and ($smiText -match 'Driver Version\s*:\s*\S+'))
  $dv = [regex]::Match($smiText, 'Driver Version\s*:\s*(\S+)')
  $vb = [regex]::Match($smiText, 'VBIOS Version\s*:\s*(\S+)')
  if ($dv.Success) { W ('  驱动版本: ' + $dv.Groups[1].Value) }
  if ($vb.Success) { W ('  VBIOS   : ' + $vb.Groups[1].Value) }
} else { $smiErr = '找不到 C:\Windows\System32\nvidia-smi.exe（驱动没装全？）' }
W ('  nvidia-smi: ' + $(if ($smiOK) { '可用' } else { '不可用 —— ' + $smiErr }))
if ($gpuProblem -ne 0) { W ('  ⚠ 设备管理器给这张卡的报告的错误码 = 0x' + ('{0:X}' -f $gpuProblem) + '（0x2B = 代码 43）') }
W ''

# ---------- 2) GSP 固件文件 ----------
W '==== 2) GSP 固件文件（驱动包是否包含）===='
$fr = 'C:\Windows\System32\DriverStore\FileRepository'
$pkgDirs = New-Object System.Collections.ArrayList
if ($svcPath -match 'FileRepository\\([^\\]+)\\') { [void]$pkgDirs.Add((Join-Path $fr $Matches[1])) }
[void]$pkgDirs.Add('C:\Windows\System32\drivers')
$nvPkgs = @(Get-ChildItem $fr -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(nvac|nv_dispi|nv_dispiwa|nvam|nvao|nvhda)' } | Sort-Object LastWriteTime -Descending | Select-Object -First 4)
foreach ($d in $nvPkgs) { [void]$pkgDirs.Add($d.FullName) }
$pkgDirs = @($pkgDirs | Select-Object -Unique)
W ('  已检查的驱动包目录: ' + ($pkgDirs -join ' ; '))
$gspFiles = @()
foreach ($d in $pkgDirs) { if (Test-Path $d) { $gspFiles += @(Get-ChildItem $d -Filter 'gsp_*.bin' -ErrorAction SilentlyContinue) } }
$gspFiles = @($gspFiles | Select-Object -Unique)
$tu = @($gspFiles | Where-Object { $_.Name -match 'gsp_tu10x\.bin' })
if ($gspFiles.Count) {
  foreach ($f in $gspFiles) { W ('  ' + $f.FullName + '   ' + [math]::Round($f.Length / 1MB, 1) + ' MB   ' + $f.LastWriteTime) }
} else { W '  找不到任何 gsp_*.bin —— 这一版驱动包**不含 GSP 固件**（精简/魔改驱动常见）' }
if ($tu.Count) {
  if ($tu[0].Length -gt 5MB) { W ('  ✔ TU10x（本卡）固件在: ' + $tu[0].Name + '  ' + [math]::Round($tu[0].Length / 1MB, 1) + ' MB') }
  else { W ('  ⚠ ' + $tu[0].Name + ' 只有 ' + $tu[0].Length + ' B —— 像占位/被裁剪文件') }
} else { W '  ⚠ 没找到 gsp_tu10x.bin（TU106 / CMP 40HX 用的就是它）' }
W ''

# ---------- 3) GSP 注册表开关 ----------
W '==== 3) GSP 开关（显示类子键 EnableGpuFirmware）===='
$target = $null; $has = $false; $val = $null
foreach ($k in @(Get-ChildItem $CLS -ErrorAction SilentlyContinue)) {
  $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
  $isNv = ($p.MatchingDeviceId -match 'ven_10de&dev_1f0b') -or ($p.DriverDesc -match '40HX')
  W ('  子键 ' + $k.PSChildName + '  ' + $(if ($p.DriverDesc) { $p.DriverDesc } else { '(无描述)' }) + '   Matching=' + $p.MatchingDeviceId)
  if ($isNv) { $target = $k }
}
if (-not $target) { W '  ⚠ 没找到 ven_10de&dev_1f0b 对应的显示类子键 —— NVIDIA 驱动没在这个设备上生效' }
else {
  $tp = Get-ItemProperty -Path $target.PSPath -ErrorAction SilentlyContinue
  $has = ($tp.PSObject.Properties.Name -contains 'EnableGpuFirmware')
  if ($has) { $val = $tp.EnableGpuFirmware }
  W ('  权威子键: ' + $target.PSPath.Replace('Microsoft.PowerShell.Core\Registry::',''))
  W ('  EnableGpuFirmware = ' + $(if ($has) { $val } else { '(未设置 —— 等同未启用)' }))
  W ('  驱动版本(子键记录) = ' + $tp.DriverVersion + '   驱动日期 = ' + $tp.DriverDate + '   InfPath = ' + $tp.InfPath)
}
W ''

# ---------- 4) 结论 ----------
W '==== 4) 结论 ===='
$gspOn = ($gspLine -and $gspLine -notmatch '^(N/A|Not Supported|Unknown)$')
$regOn = ($target -and $has -and ([int]$val -eq 1))
$fwOK  = ($tu.Count -gt 0 -and $tu[0].Length -gt 5MB)
$drvOK = (($svcState -match 'RUNNING') -and (-not $isBasic) -and $gpu -and ($gpuProblem -eq 0))

if ($gspOn) {
  W ('  [OK] GSP 已启用：nvidia-smi 报 GSP Firmware Version = ' + $gspLine)
  W '       无需处理（GSP 开着时驱动认卡正常，解锁后不会因为 GSP 出代码 43）。'
} elseif (-not $drvOK) {
  W '  [!!] 判不了 GSP —— **驱动层就不正常**，现在写 GSP 开关是白写。'
  W ('       证据: nvlddmkm=' + $svcState + ' / 40HX 是基本显示适配器=' + $isBasic + ' / 设备错误码=0x' + ('{0:X}' -f $gpuProblem) + ' / nvidia-smi=' + $(if ($smiOK) { '可用' } else { '不可用（' + $smiErr + '）' }))
  W '       按顺序做：'
  W '         ① 设备管理器看这张卡有没有黄叹号、错误码多少（0x2B = 代码 43，最典型）'
  W '         ② 装 NVIDIA **官方完整**驱动（别用精简版/魔改版），装完**完全关机再开机**（不是重启）'
  W '         ③ BIOS：Above 4G Decoding = Enabled、CSM = Disabled、Fast Boot = Disabled'
  W '         ④ 装完再跑一次本脚本：nvidia-smi 能用了，才谈 GSP'
  if (-not $fwOK) { W '       另外：这台机器的驱动包里**没有可用的 gsp_tu10x.bin** —— 换官方完整驱动包再试（精简版会删掉它）。' }
} elseif (-not $fwOK) {
  W '  [!!] GSP 没开，而且**驱动包里缺 GSP 固件**（gsp_tu10x.bin 不在或过小）→ 写开关没用。'
  W '       处置：换 NVIDIA 官方**完整**驱动包重装（精简/魔改版常删掉 GSP 固件），装完完全关机再开机。'
} else {
  W ('  [!!] GSP 没开，但条件都具备（固件 ' + [math]::Round($tu[0].Length / 1MB, 1) + ' MB / nvlddmkm=' + $svcState + '）')
  W ('       当前开关 EnableGpuFirmware = ' + $(if ($has) { $val } else { '(未设置)' }))
  if ($regOn) {
    W '       ⚠ 开关已经是 1 但 nvidia-smi 仍说没启用 → 先**完全关机再开机**（不是重启）；若开机后还是 N/A，'
    W '         说明问题不在这个开关（驱动版本 / VBIOS / 固件），别反复写它。'
  } else {
    W '       处置：跑一次  查GSP.cmd /fix  （写 EnableGpuFirmware=1），然后**完全关机再开机**（不是重启）。'
    W '       开机后跑 状态自检.bat + 本脚本复查：nvidia-smi 应显示 GSP Firmware Version = 版本号。'
  }
}
W ''

# ---------- 5) 修复（-Fix）----------
if ($Fix) {
  W '==== 5) 修复动作 ===='
  if (-not $target) { W '  [X] 没有可写的权威子键 —— 先解决驱动问题（见第 4 节），本次不写任何东西。' }
  elseif ($regOn) { W '  [--] 开关 EnableGpuFirmware 已经是 1 —— 幂等跳过（重复写没有意义；先完全关机再开机）。' }   # 2026-10-04c：原来要 $regOn -and $gspOn 才跳过，导致"开关=1 但没启用"时又备份又重写，与自己第 4 节的建议矛盾
  else {
    $keyPath = $target.PSPath.Replace('Microsoft.PowerShell.Core\Registry::','') -replace '^HKEY_LOCAL_MACHINE','HKLM' -replace '^HKEY_CURRENT_USER','HKCU'
    $bk = Join-Path $desk ('40HX-GSP备份-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.reg')
    if ($DryRun) {
      W '  [DryRun] 跳过备份（DryRun 不改动任何东西）'
      W '  [DryRun] 将写入: EnableGpuFirmware = 1 (DWORD)'
    } else {
      $rc = 1
      & reg.exe export $keyPath $bk /y 2>&1 | Out-Null
      $rc = $LASTEXITCODE
      if ($rc -eq 0 -and (Test-Path $bk)) {
        W ('  已备份该子键到: ' + $bk + '   （还原：双击该 .reg，或 reg import 它）')
      } else {
        W ('  [!] 备份失败（reg exit=' + $rc + '）—— 为安全起见**不写注册表**；请先解决备份问题或手工导出该子键')
      }
      if ($rc -eq 0 -and (Test-Path $bk)) {
        try {
          New-ItemProperty -Path $target.PSPath -Name 'EnableGpuFirmware' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
          $chk = (Get-ItemProperty -Path $target.PSPath -Name 'EnableGpuFirmware' -ErrorAction SilentlyContinue).EnableGpuFirmware
          W ('  已写入 EnableGpuFirmware = ' + $chk + $(if ([int]$chk -eq 1) { '   [OK] 已生效' } else { '   [X] 写后回读不一致！' }))
        } catch { W ('  [X] 写入失败: ' + $_.Exception.Message) }
      }
    }
    W '  接下来必须：**完全关机**（开始 → 关机 → 断电 10 秒）再开机 —— 不是重启。'
    W '  （重启不会重新初始化 nvlddmkm，GSP 不会生效。）'
  }
  W ''
}

Save
W ''
W ('报告已存: ' + $out)
if ($env:NO_PAUSE -ne '1') {
  try { Start-Process notepad.exe -ArgumentList ('"' + $out + '"') } catch { }
  try { if ($Host.Name -eq 'ConsoleHost') { Write-Host ''; Read-Host '按回车退出（报告已打开）' } } catch { }
}
