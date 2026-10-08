#Requires -Version 5.1
<#
  Install-40HXUnlock.ps1
  ======================
  CMP 40HX 算力解锁 + PCIe Gen2 x16 一键安装 / 迁移脚本（自含，不需要厂商安装器）

  它做什么（全部由本脚本自己完成，不调用 CMP40HX-Unlock 厂商安装器：
  厂商安装器会把 ESP 上的 OnlyEFI 解锁固件覆盖掉，导致 Windows 侧 helper 守卫失败）：
    1. 前提体检：UEFI/GPT、Secure Boot、BitLocker、CMP 40HX 是否在位、GSP 是否开启、杀软
    2. 驱动：ThrottleStop.sys + WinRing0x64.sys + inpoutx64.sys/.dll（base64 还原）→ System32\drivers + 多个自愈源
             + 建服务 ThrottleStop / WinRing0_1_2_0
             （inpoutx64 不建常驻服务：开机脚本自己 create/delete 临时服务 inpoutx64T）
    3. Windows 侧 helper：CMP40HXGen2.exe + AutoRetrain.cmd + RunPostBind.cmd + 40hx-retrain-inpout.ps1 + ACE-Toggle.ps1
             → %ProgramData%\CMP40HXGen2\windows
             首选路径 = 40hx-retrain-inpout.ps1：inpoutx64 直写 MMIO + WinRing0 走 PCI 配置空间，
             **ACE-BOOT 全程不用停** → 反作弊预启动模式不被破坏，游戏不要求重启；
             旧路径（停 ACE-BOOT → AutoRetrain → 恢复 ACE-BOOT）保留为 fallback：新路径退出码非 0 才走
    4. ESP 固件：OnlyEFI v0.1.1 的 40HXUNLK.EFI（算力解锁 + Gen2 primer，EFI 阶段不重训）
             → \EFI\40HX\40HXUNLK.EFI（默认**不动** Windows 自己的 \EFI\Boot\bootx64.efi；只有显式加 -WriteBootx64 才覆盖）
    5. 固件启动项：自己写 NVRAM Boot#### 变量（"40HX Unlock"，指向解锁 EFI），
             默认把它放到 BootOrder 第一位；原 BootOrder / 全部 Boot#### 先备份
    6. 开机任务：CMP40HX Gen2 PostBind（SYSTEM/Highest，BootTrigger）→ RunPostBind.cmd
    7. 关掉厂商版自启任务/登录项、把 Gen2AutoHard/Gen2PnpFallback 置 0（永不复位显卡=不毁算力）

  2026-09-30 修复（客户机"装完重启黑屏 1~2 分钟 + 设备管理器代码 43"）：
    · GSP 判定把 nvidia-smi 的 "N/A" 误当"已开启"→ 从不写开关；且写在了驱动不读的
      Services\nvlddmkm\Parameters。现在：N/A/缺行 = 未启用，开关写进**显示类子键**
      Control\Class\{4d36e968-...}\<000X>（本机实测真正生效的位置）。
    · 策略键 Gen2AutoHard/Gen2PnpFallback 改为**无条件**建键再写 0（旧版只在厂商键已存在时才写）。
    · 厂商自启不再只认两个固定任务名：扫全部名字/命令行含 40HX 的任务逐个禁用。
    · ESP 挂载点会与系统盘 ESP 分区比对（防止挂到别的磁盘的 ESP → 固件找不到文件）。
    · 取消"必须重启"的说法：改成必须**完全关机（不是重启）**再开机，否则残留状态会变成 Code 43。

  2026-10-08 修复（客户机 Install 被「系统盘不是 GPT（未知）」挡死）：
    · Storage 模块/提供程序异常时 Get-Partition/Get-Disk 会抛异常，旧版把它吞成 '未知' 并当成 MBR 盘
      挡下整个安装（客户机 diskpart 里三块盘全是 GPT）。现在样式判定改为 5 个后端：
      Storage 模块 → CIM(Storage 命名空间) → 老 WMI → 裸读 LBA0/LBA1 → 裸读扫描+卷GUID反查；
      原始错误文本全部写进日志；只有真读出 MBR 才是硬门槛，'未知' 降级为提示 + 诊断。
    · ESP 分区身份同样带回退（Get-Partition 拿不到 → CIM → 裸读 GPT 解析出 ESP 类型分区）。
    · 新增 -Mode StorageDiag 与 工具-测试与修复\存储体检.cmd：一次把每个后端的原始结果打全，方便客户回传。

  模式（-Mode）：
    Check       只体检，不写任何东西（可非管理员运行，仅少 ESP/NVRAM 部分）
    StorageDiag 存储信息诊断：逐后端打印「系统盘样式/系统盘号/ESP 分区/逐盘裸读」的原始结果（只读，可非管理员）
    SelfTest    自检：ESP 读写往返 + NVRAM 写入/回读/删除往返 + BootOrder 原样写回（不改动状态）
    Install     一键安装/修复（幂等，可重复跑）
    Repair      只补文件/服务/任务（不动 NVRAM）
    Verify      现场取证：算力 + Gen2 + 任务结果
    MakeDefault 把 "40HX Unlock" 提到 BootOrder 第一位（安装时选 -BootMode none 才需要）
    Uninstall   卸载（还原 bootx64.efi、删启动项/任务/服务/驱动），需 -Yes

  退出码：0=成功  1=一般失败  2=前提不满足  3=载荷/哈希校验失败  4=NVRAM 操作失败  5=驱动被拦截/未就绪
#>
[CmdletBinding()]
param(
  [ValidateSet('Check','Install','Repair','Verify','SelfTest','MakeDefault','Uninstall','StorageDiag')]
  [string]$Mode = 'Check',

  # 固件启动项怎么处理：default=放进 BootOrder 第一位（推荐，配合 chainload 安全）
  #                     next=只设 BootNext 一次性试跑  none=只写变量不动顺序
  [ValidateSet('default','next','none')]
  [string]$BootMode = 'default',

  [switch]$Force,        # 忽略前提硬门槛（Secure Boot / MBR / BitLocker）
  [switch]$RunNow,       # Install/Repair 结束后立刻跑一次开机任务（要求本次开机已解锁）
  [switch]$Yes,          # Uninstall 确认
  [switch]$KeepBootx64,  # 不覆盖 ESP 的 \EFI\Boot\bootx64.efi（只写 \EFI\40HX\40HXUNLK.EFI）
  [switch]$Purge,        # Uninstall 时连 %ProgramData%\CMP40HXGen2 一起删
  [switch]$WriteBootx64  # 2026-10-01b: 显式覆盖 \EFI\Boot\bootx64.efi（默认不覆盖 —— 见 Install-Efi 的注释）
)

$ErrorActionPreference = 'Stop'
$script:PendingDriverRetry = $false   # 驱动文件被占用而跳过写入时置位（不致命，重启后由开机任务补齐）

# 原生命令（schtasks / sc / mountvol …）在 'Stop' 下的致命坑：
#   PS 5.1 里外部程序往 stderr 写字会产生 NativeCommandError，**即使写成 `... 2>&1 | Out-Null` 也会终止脚本**。
#   实测（2026-09-28）：全新机器首次安装时开机任务还不存在，`schtasks /delete` 报“系统找不到指定的文件。”
#   → 安装直接中断在 Install-Task，用户看到一堆 NativeCommandError。
# 解法：只在“调用原生命令”这一小段把 EAP 临时放回 Continue（命令本身、输出编码、文本匹配全部保持不变，
#   错误文本照旧能读到，只是不再是终止错误）。所有原生调用都必须走这个包装。
function Invoke-Native {
  param([Parameter(Mandatory = $true)][scriptblock]$Code)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { return (& $Code) } finally { $ErrorActionPreference = $prev }
}
try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936) } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------- 常量 / 路径
$script:PkgRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:PayloadDir = Join-Path $script:PkgRoot 'payload'
$script:LogDir = Join-Path $script:PkgRoot 'logs'
$script:BackupRoot = Join-Path $script:PkgRoot 'backup'
$script:StateFile = Join-Path $script:PkgRoot 'state\installed.json'
$script:EspDrvFallback = 'EFI\40HX\drv'
$script:ProgDataRoot = Join-Path $env:ProgramData 'CMP40HXGen2'
$script:ProgDataWin = Join-Path $script:ProgDataRoot 'windows'
$script:ProgDataDrv = Join-Path $script:ProgDataRoot 'drivers'
$script:VendorDrvDir = Join-Path $env:ProgramData '40HXUnlock\drivers'
$script:SysDrv = Join-Path $env:SystemRoot 'System32\drivers'
$script:TaskName = 'CMP40HX Gen2 PostBind'
# 2026-10-01 新增：登录后 60 秒的补跑任务。开机那轮跑得太早（onstart/SYSTEM），客户机上会因
#   ①杀软在开机阶段拦驱动加载(inpoutx64 起不来 exit 13) ②GPU/驱动未就绪(exit 12) ③驱动文件被清(exit 3)
#   而失败 —— 但登录后手动跑一次总是成功。所以让系统自己在登录后自动补跑一次，用户就不用手动了。
$script:TaskNameLogon = 'CMP40HX Gen2 PostBind Logon'
$script:EspRoot = $null
$script:LogPath = $null
$script:WarnCount = 0
$script:FailCount = 0
$script:ActionItems = New-Object System.Collections.ArrayList   # 跑完要"人"做的事，汇总在结尾再提示一次

# OnlyEFI v0.1.1 解锁固件（EFI 阶段：算力解锁 + 4 个 TU106 Gen2 策略寄存器 + Root TLS=2，故意不重训）
$script:EfiSha256 = '1e9ca43fab3d5ce851e8fcd09dc9be63282fbf3ce3828c3dbcdcbb21cf7ce1c7'
$script:EfiSize = 590868
# Windows 侧两个签名驱动（BYOVD 读写 PCI 配置空间用）
$script:Drivers = @(
  @{ Name = 'ThrottleStop.sys' ; Sha256 = '16f83f056177c4ec24c7e99d01ca9d9d6713bd0497eeedb777a3ffefa99c97f0' ; Service = 'ThrottleStop'    },
  @{ Name = 'WinRing0x64.sys'  ; Sha256 = '11bd2c9f9e2397c9a16e0990e4ed2cf0679498fe0fd418a3dfdac60b5c160ee5' ; Service = 'WinRing0_1_2_0' }
)
# 首选路径（2026-09-29 起）用的驱动：inpoutx64 —— 只铺文件，不建常驻服务
#   inpoutx64.sys → System32\drivers（开机脚本用它 MMIO 读写 GPU BAR0）、两个 ProgramData 自愈目录
#   inpoutx64.dll → 两个 ProgramData 自愈目录（脚本用 Add-Type 按绝对路径加载 MapPhysToLin）
#   Kinds: 'sys' = 需要进 System32\drivers；'drv' = 只进 ProgramData 目录
$script:InpoutFiles = @(
  @{ Name = 'inpoutx64.sys' ; Sha256 = 'f8965fdce668692c3785afa3559159f9a18287bc0d53abb21902895a8ecf221b' ; Kinds = @('sys','drv') },
  @{ Name = 'inpoutx64.dll' ; Sha256 = '5f27ed4d5cd58a1ee23deeb802e09e73f3a1d884ce2135f6e827f67b171269e7' ; Kinds = @('drv') }
)
$script:ExitOk = 0; $script:ExitFail = 1; $script:ExitPrereq = 2; $script:ExitHash = 3; $script:ExitNvram = 4; $script:ExitDriver = 5

# ---------------------------------------------------------------- 输出
function Say {
  param([string]$Text = '', [string]$Color = 'Gray')
  Write-Host $Text -ForegroundColor $Color
  if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $Text -Encoding UTF8 }
}
function Head { param([string]$Text) Say ''; Say ("==== " + $Text + " ====") 'Cyan' }
function Ok   { param([string]$Text) Say ("  [OK]   " + $Text) 'Green' }
function Warn { param([string]$Text) Say ("  [提示] " + $Text) 'Yellow'; $script:WarnCount++ }
function Bad  { param([string]$Text) Say ("  [失败] " + $Text) 'Red'; $script:FailCount++ }
function Info { param([string]$Text) Say ("  - " + $Text) }
function Add-Action { param([string]$Text) if ($script:ActionItems -notcontains $Text) { [void]$script:ActionItems.Add($Text) } }

function Fail {
  param([string]$Message, [int]$Code = 1, [string]$Hint = '')
  Say ''
  Say ("!! " + $Message) 'Red'
  if ($Hint) { Say ("   排查: " + $Hint) 'Yellow' }
  Show-FailureHelp $Code
  exit $Code
}

# 退出码含义 + 出错后按顺序做这 4 件事（换机器排错时最有用）
function Get-ExitCodeText {
  param([int]$Code)
  switch ($Code) {
    1 { return '有步骤失败（细节看日志里的 [失败] 行）' }
    2 { return '前提条件不满足（Secure Boot / GPT / BitLocker / 没插显卡 / 非管理员）' }
    3 { return '载荷损坏或被改动（固件/驱动/helper 的 sha256 对不上）—— 杀软删过文件 = 重新解压一份包' }
    4 { return '固件变量(NVRAM)读写失败（权限 / 主板不接受 / 槽位不够）' }
    5 { return '驱动或服务失败' }
    default { return '未分类错误' }
  }
}
function Show-FailureHelp {
  param([int]$Code)
  $dir = $script:PkgRoot
  Say ''
  Say '---- 出错怎么办 ----' 'Cyan'
  Say ("  退出码 " + $Code + " : " + (Get-ExitCodeText $Code))
  Say '  1) 完整日志（把这行贴出来最省事）:'
  Say ("     " + $script:LogPath) 'Gray'
  Say '  2) 先体检一次（只看不改）:'
  Say ('     powershell -ExecutionPolicy Bypass -File "' + (Join-Path $dir 'Install-40HXUnlock.ps1') + '" -Mode Check') 'Gray'
  Say '  3) 对照排查指引（按报错关键字查）:'
  Say ("     " + (Join-Path $dir '排查指引.md')) 'Gray'
  Say ('     常见: 杀软隔离(看第 2 节) / 前提不满足(第 3 节) / ESP 或 NVRAM(第 4 节) / 开机没解锁(第 5 节)')
  Say '  4) 卸载回滚（任何时候都能退）:'
  Say ('     powershell -ExecutionPolicy Bypass -File "' + (Join-Path $dir 'Install-40HXUnlock.ps1') + '" -Mode Uninstall -Yes') 'Gray'
}

function Exit-With {
  param([int]$Code)
  if ($Code -ne 0) { Show-FailureHelp $Code }
  exit $Code
}

# ---------------------------------------------------------------- 基础工具
function Test-Admin {
  return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NvidiaSmi {
  $cands = @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:SystemRoot\SysWOW64\nvidia-smi.exe")
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# ---- GSP（GPU 固件）状态判定 ------------------------------------------------
# 坑（2026-09-30 修）：GSP 关闭时 nvidia-smi -q 打印的是 "GSP Firmware Version : N/A"
#   （NVIDIA 文档：显示的是版本号=已启用，N/A=未启用）→ 旧版正则 (\S+) 会把 N/A 当"已开启"，
#   于是从不写 EnableGpuFirmware → 客户机解锁后 nvlddmkm 认不了卡 = 黑屏 + 代码 43。
# 返回 State: 'on'（版本号）/ 'off'（N/A、空、其它非版本号）/ 'unknown'（没驱动、没这一行）
function Get-GspState {
  param([string]$RawOutput)   # 传字符串=离线判定（自检/单测用）；不传就去跑 nvidia-smi -q
  $smi = ''
  $q = ''
  if ($RawOutput) { $q = $RawOutput }
  else {
    $smi = Get-NvidiaSmi
    if (-not $smi) { return [pscustomobject]@{ State = 'unknown'; Value = ''; Line = '找不到 nvidia-smi.exe（没装 NVIDIA 驱动？）' } }
    $q = (Invoke-Native { & $smi -q 2>&1 } | Out-String)
  }
  $m = [regex]::Match($q, '(?im)^\s*GSP Firmware Version\s*:\s*(.+?)\s*$')
  if (-not $m.Success) { return [pscustomobject]@{ State = 'unknown'; Value = ''; Line = 'nvidia-smi -q 里没有 GSP 行' } }
  $v = $m.Groups[1].Value.Trim()
  if ($v -match '^\d+(\.\d+)+') { return [pscustomobject]@{ State = 'on'; Value = $v; Line = $m.Value.Trim() } }
  return [pscustomobject]@{ State = 'off'; Value = $v; Line = $m.Value.Trim() }
}

# ---- 该设备真正使用的显示类子键（权威）：Enum\<实例>\Driver = {4d36e968-...}\<000X> ----
function Get-AuthoritativeDisplayKeyIndex {
  param([string]$InstanceId)
  try {
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $InstanceId
    $d = [string](Get-ItemProperty -Path $k -Name 'Driver' -ErrorAction SilentlyContinue).Driver
    if ($d -match '\\([0-9]{4})$') { return $Matches[1] }
  } catch { }
  return ''
}

# ---- 显示类注册表子键：GSP 开关真正生效的位置 --------------------------------
# Windows 上开 GSP 写在 HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-...}\<000X>
# （本机实测：Services\nvlddmkm\Parameters 里没有 EnableGpuFirmware，写了也不生效）
function Get-DisplayClassSubKeys {
  $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
  $out = @()
  foreach ($sub in (Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
    $mid = [string](Get-ItemProperty -Path $sub.PSPath -Name 'MatchingDeviceId' -ErrorAction SilentlyContinue).MatchingDeviceId
    $dd = [string](Get-ItemProperty -Path $sub.PSPath -Name 'DriverDesc' -ErrorAction SilentlyContinue).DriverDesc
    if ($mid -match '(?i)ven_10de&dev_1f0b' -or $dd -match 'CMP 40HX') {
      $out += [pscustomobject]@{
        Path            = $sub.PSPath
        Name            = $sub.PSChildName
        DriverDesc      = $dd
        MatchingDeviceId = $mid
        Value           = (Get-ItemProperty -Path $sub.PSPath -Name 'EnableGpuFirmware' -ErrorAction SilentlyContinue).EnableGpuFirmware
      }
    }
  }
  return @($out)
}

# ---- ESP 挂载点身份（volume GUID，GPT 下等于分区 GUID）----------------------
# 用来判断"已经挂着的那个盘符"是不是系统盘自己的 ESP —— 旧版只看哪个盘符有 \EFI\Boot，
# 可能挂到别的磁盘/旧的挂载点上，于是 NVRAM 指向的 ESP 里没有固件 → 开机干等一段再进系统。
function Get-EspVolumeGuid {
  param([string]$Letter)
  $o = (Invoke-Native { mountvol $Letter /L 2>&1 } | Out-String)
  $m = [regex]::Match($o, '(?i)Volume\{([0-9a-f-]{36})\}')
  if ($m.Success) { return $m.Groups[1].Value.ToLower() }
  return ''
}

function New-BackupFolder {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dir = Join-Path $script:BackupRoot $stamp
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  return $dir
}

function Copy-WithVerify {
  param([string]$Source, [string]$Target, [string]$ExpectedSha256 = $null)
  if (-not (Test-Path $Source)) { throw ("源文件不存在: " + $Source) }
  $dir = Split-Path -Parent $Target
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Copy-Item -LiteralPath $Source -Destination $Target -Force
  $hash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLower()
  if ($ExpectedSha256 -and $hash -ne $ExpectedSha256.ToLower()) {
    return @{ Ok = $false; Hash = $hash }
  }
  return @{ Ok = $true; Hash = $hash }
}

# 2026-10-05（客户机实测 + 审查 r4 H2/Q2）：Windows 侧 helper 守卫（CMP40HXGen2.exe）还在跑时，Copy-Item 会抛
#   "文件正由另一进程使用"，而全局 $ErrorActionPreference='Stop' 会把**整个安装**打断（客户机 exit=1）。
#   策略：① 停掉"动作命令行里引用 helper"的计划任务（Execute **和** Arguments 一起匹配 —— 厂商/本包都常用 cmd.exe /c 包装）
#        ② 停任务前先 Stop-ScheduledTask 运行实例，避免任务立刻把进程再拉起来
#        ③ 最后才结束占用进程（重试 3 次）。本函数只在"直拷失败"后才调用，不无故强杀正在干活的 helper。
function Stop-HelperHolders {
  param([string[]]$TaskMatch = @('CMP40HXGen2|AutoRetrain'), [string[]]$ProcNames = @('CMP40HXGen2'))
  foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    if ([string]$t.TaskName -eq $script:TaskName) { continue }
    if ([string]$t.TaskName -eq $script:TaskNameLogon) { continue }
    $acts = ((@($t.Actions) | ForEach-Object { ([string]$_.Execute + ' ' + [string]$_.Arguments) }) -join ' ')
    $hit = $false
    foreach ($m in $TaskMatch) { if ($acts -match $m) { $hit = $true } }
    if (-not $hit) { continue }
    try { Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null } catch { }
    if ($t.State -ne 'Disabled') {
      try { Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null; Ok ('已停用引用 helper 的计划任务: ' + $t.TaskName) } catch { }
    }
  }
  foreach ($n in $ProcNames) {
    for ($i = 1; $i -le 3; $i++) {
      $procs = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
      if ($procs.Count -eq 0) { break }
      Info ('结束占用 helper 的进程: ' + $n + ' (PID ' + (($procs | ForEach-Object { $_.Id }) -join ',') + ') 第 ' + $i + ' 次')
      try { $procs | Stop-Process -Force -ErrorAction Stop } catch { }
      Start-Sleep -Milliseconds 900
    }
  }
}

# 2026-10-05：拷贝 helper 不允许"被占用"打断安装 —— 重试 3 次，仍失败就写 <名字>.new 留给开机任务替换，只 Warn 不 Failed。
#   审查 r4 M1 / r5 F1 / r6 M1：**必须有清单里那一行的期望 md5**（参数强制），先验包内源文件；
#     不符 → 目标不动、不写 .new、不动 helper 进程。
#   审查 r6 M2a/M2c/L1/L2/L8：哈希与建目录都包 try/catch；tampered 时顺手清掉陈旧 .new（别让未校验旧内容被 swap 换上）；
#     只有"文件正被其它进程使用"这类错误才去压同名进程（其它失败原因不误杀正在干活的 helper）。
function Copy-WithVerifyLoose {
  param([string]$Source, [string]$Target, [Parameter(Mandatory=$true)][string]$ExpectedMd5)
  if (-not (Test-Path -LiteralPath $Source)) { throw ("源文件不存在: " + $Source) }
  $base = [IO.Path]::GetFileNameWithoutExtension($Target)
  $ext = [IO.Path]::GetExtension($Target)
  try { $srcMd5 = (Get-FileHash -LiteralPath $Source -Algorithm MD5).Hash.ToLower() }
  catch {
    Warn ($base + $ext + ' 读不了包内这份文件: ' + $_.Exception.Message + '（杀软拦/权限）—— 本次不写任何文件')
    return @{ Ok = $false; Kind = 'iofail'; Hash = '' }
  }
  if ($srcMd5 -ne $ExpectedMd5.ToLower()) {
    Warn ($base + $ext + ' 包内这份内容与清单不符（' + $srcMd5 + ' != ' + $ExpectedMd5 + '）—— 重新解压一份包再试；本次不写任何文件、也不动 helper 进程')
    if (Test-Path -LiteralPath ($Target + '.new')) { try { Remove-Item -LiteralPath ($Target + '.new') -Force -ErrorAction Stop; Info ('已清掉未校验的旧 ' + $base + $ext + '.new') } catch { } }
    return @{ Ok = $false; Kind = 'tampered'; Where = 'src'; Hash = $srcMd5 }
  }
  $dir = Split-Path -Parent $Target
  if (-not (Test-Path $dir)) {
    try { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
    catch { Warn ('建目录失败 ' + $dir + ': ' + $_.Exception.Message); return @{ Ok = $false; Kind = 'iofail'; Hash = '' } }
  }
  $reason = ''
  for ($try = 1; $try -le 3; $try++) {
    $sharing = $false
    try {
      Copy-Item -LiteralPath $Source -Destination $Target -Force -ErrorAction Stop
      $md5 = (Get-FileHash -LiteralPath $Target -Algorithm MD5).Hash.ToLower()
      if ($md5 -eq $ExpectedMd5.ToLower()) {
        if (Test-Path -LiteralPath ($Target + '.new')) {
          try { Remove-Item -LiteralPath ($Target + '.new') -Force -ErrorAction Stop; Info ('已清掉陈旧的 ' + $base + $ext + '.new（这次已直接写成功）') } catch { }
        }
        if ($try -gt 1) { Info ($base + $ext + ': 第 ' + $try + ' 次拷贝成功') }
        return @{ Ok = $true; Kind = 'ok'; Hash = $md5 }
      }
      Warn ($base + $ext + ' 拷进目标后内容又不一致（' + $md5 + ' != ' + $ExpectedMd5 + '，可能写坏或被别的程序改了）；重跑 -Mode Repair 仍如此请把这条日志发回')
      return @{ Ok = $false; Kind = 'tampered'; Where = 'dst'; Hash = $md5 }
    } catch {
      $reason = $_.Exception.Message
      $sharing = ($reason -match '正由另一进程使用|being used by another process|另一个程序正在使用|另一个进程')
    }
    if ($sharing -and $ext -eq '.exe') { Get-Process -Name $base -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
  }
  try {
    Copy-Item -LiteralPath $Source -Destination ($Target + '.new') -Force -ErrorAction Stop
    Warn ($base + $ext + ' 被占用写不进去（' + $reason + '）→ 已放到 ' + $base + $ext + '.new（内容已校验），下次开机由开机任务替换')
    return @{ Ok = $false; Kind = 'locked'; Hash = ''; Pending = ($Target + '.new') }
  } catch {
    Warn ($base + $ext + ' 既写不进去也放不了 .new: ' + $_.Exception.Message)
    return @{ Ok = $false; Kind = 'failed'; Hash = '' }
  }
}

function Save-PayloadFile {
  param([string]$Path, [byte[]]$Bytes, [string]$Sha256, [string]$Name, [string]$Service)
  $existing = ''
  if (Test-Path -LiteralPath $Path) { try { $existing = Get-FileSha256 $Path } catch { $existing = '' } }
  if ($existing -eq $Sha256) { Ok ($Name + ' → ' + $Path + ' (已是同一份，跳过写入)'); return $true }
  $reason = ''
  for ($try = 1; $try -le 2; $try++) {
    try { [IO.File]::WriteAllBytes($Path, $Bytes) } catch { $reason = $_.Exception.Message }
    $h = ''
    if (Test-Path -LiteralPath $Path) { try { $h = Get-FileSha256 $Path } catch { $h = '' } }
    if ($h -eq $Sha256) {
      if ($try -gt 1) { Info ($Name + ' → ' + $Path + ' (重试后写入成功)') }
      Ok ($Name + ' → ' + $Path + ' (sha256 校验通过)')
      return $true
    }
    if ($try -eq 1) {
      # 被占用：驱动还在跑或停在 STOP_PENDING。先试着把服务停掉再写一次
      if ($Service) {
        Info ($Name + ' 被占用（' + $reason + '）→ 尝试 sc stop ' + $Service + ' 后重写')
        Invoke-Native { sc.exe stop $Service 2>&1 | Out-Null }
        Start-Sleep -Seconds 3
        Invoke-Native { sc.exe stop $Service 2>&1 | Out-Null }
        Start-Sleep -Seconds 3
      } else { Start-Sleep -Milliseconds 800 }
    }
  }
  Warn ($Name + ' → ' + $Path + ' 写不进去：' + $reason + ' （驱动正被占用/停在 STOP_PENDING 时常见）')
  Info ('  本次先跳过这个文件；完全关机再开机后，开机任务会自动从 ESP 兜底源补齐（也可以先手动 sc stop ' + $(if ($Service) { $Service } else { '<服务名>' }) + ' 再跑一次 Repair）')
  $script:PendingDriverRetry = $true
  return $false
}

function Get-FileSha256 { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower() }

# 读文本文件并返回 {Text, Encoding}：先按严格 UTF-8 试，失败再按 GBK（936）。
# 必须保留原编码写回：.cmd 里的中文注释若是 UTF-8 被当 GBK 读回写，会被改坏。
function Read-TextAutoDetect {
  param([string]$Path)
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    return @{ Text = $enc.GetString($bytes, 3, $bytes.Length - 3); Encoding = $enc }
  }
  try {
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    $s = $strict.GetString($bytes)
    return @{ Text = $s; Encoding = (New-Object System.Text.UTF8Encoding($false)) }
  } catch {
    return @{ Text = ([Text.Encoding]::GetEncoding(936)).GetString($bytes); Encoding = [Text.Encoding]::GetEncoding(936) }
  }
}

# ---------------------------------------------------------------- ESP 挂载
# 坑：ESP 已经被挂载到别的盘符时，mountvol <new>: /S 会直接报“参数错误”而不是换一个字母，
#     所以必须先扫一遍现有盘符，找到已挂载出来的 ESP（实测被上一次运行留在 Y: 就是这样）。
$script:EspMountError = ''
$script:EspPreMounted = $false
function Mount-Esp {
  if ($script:EspRoot -and (Test-Path ($script:EspRoot + '\EFI'))) { return $script:EspRoot }
  $letters = @('Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K')
  $espWant = $null
  try { $espWant = Get-EspPartitionInfo } catch { }
  foreach ($dl in $letters) {
    if ((Test-Path ($dl + ':\EFI\Boot')) -or (Test-Path ($dl + ':\EFI\Microsoft'))) {
      # 2026-09-30 修：已挂着的盘符可能不是系统盘的 ESP（别的磁盘/上次运行残留）→ 用 volume GUID 比对，
      # 不一致就忽略它（否则 NVRAM 里的启动项会指向一个没有固件的 ESP → 开机干等一段再进系统）
      if ($espWant) {
        $gotGuid = Get-EspVolumeGuid ($dl + ':')
        $wantGuid = ([string]$espWant.GuidText).ToLower()
        if ($gotGuid -and $wantGuid -and $gotGuid -ne $wantGuid) {
          Warn ('盘符 ' + $dl + ': 上的 ESP 不是系统盘的（GUID ' + $gotGuid + ' ≠ ' + $wantGuid + '）→ 忽略，改挂系统盘的 ESP')
          Add-Action '有别的磁盘的 ESP 被挂在 ' + $dl + ': 上：脚本已跳过它；若仍挂载失败，先 mountvol ' + $dl + ': /D 卸掉再跑'
          continue
        }
      }
      $script:EspRoot = $dl + ':'
      $script:EspPreMounted = $true   # 2026-10-01b（审查）：本来就被挂着的盘符 —— 结束时不要卸掉别人的挂载
      return $script:EspRoot
    }
  }
  foreach ($dl in $letters) {
    if (-not (Test-Path ($dl + ':\'))) {
      $out = (Invoke-Native { mountvol ($dl + ':') /S 2>&1 | Out-String }).Trim()
      if ((Test-Path ($dl + ':\EFI\Boot')) -or (Test-Path ($dl + ':\EFI\Microsoft'))) {
        $script:EspRoot = $dl + ':'
        return $script:EspRoot
      }
      if ($out) { $script:EspMountError = ($dl + ': ' + $out) }
    }
  }
  return $null
}
function Dismount-Esp {
  # 2026-10-01b（第三方审查）：只卸载"我们自己挂的"。本来就被别人挂着的盘符保持原样。
  if ($script:EspRoot) {
    if ($script:EspPreMounted) { Info ('盘符 ' + $script:EspRoot + ' 是本来就挂着的 → 不卸载（留给原来的使用者）') }
    else { Invoke-Native { mountvol $script:EspRoot /D 2>&1 | Out-Null } }
    $script:EspRoot = $null
  }
}

# ================================================================ NVRAM (固件变量)
$script:FwGuid = '{8be4df61-93ca-11d2-aa0d-00e098032b8c}'
$script:FwTypeLoaded = $false

function Initialize-FwAccess {
  if ($script:FwTypeLoaded) { return $true }
  $signature = @"
using System;
using System.Runtime.InteropServices;
public class FwVar {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct TP { public uint Count; public LUID Luid; public uint Attributes; }
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP nw, uint len, IntPtr prev, IntPtr ret);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint GetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  // 读/写 NVRAM 必须持 SeSystemEnvironmentPrivilege，否则 err=1314
  public static string EnablePrivilege() {
    IntPtr tok;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) { return "OpenProcessToken 失败 " + Marshal.GetLastWin32Error(); }
    LUID luid;
    if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) { return "LookupPrivilegeValue 失败 " + Marshal.GetLastWin32Error(); }
    TP tp = new TP(); tp.Count = 1; tp.Luid = luid; tp.Attributes = 0x2;
    if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) { return "AdjustTokenPrivileges 失败 " + Marshal.GetLastWin32Error(); }
    return "ok";
  }
}
"@
  Add-Type -TypeDefinition $signature | Out-Null
  $r = [FwVar]::EnablePrivilege()
  if ($r -ne 'ok') { Warn ("启用 SeSystemEnvironmentPrivilege 失败: " + $r) } else { Info "SeSystemEnvironmentPrivilege 已启用" }
  $script:FwTypeLoaded = $true
  return ($r -eq 'ok')
}

function Read-FwVar {
  param([string]$Name)
  Initialize-FwAccess | Out-Null
  $buf = New-Object byte[] 8192
  $len = [FwVar]::GetFirmwareEnvironmentVariableW($Name, $script:FwGuid, $buf, [uint32]$buf.Length)
  if ($len -le 0) { return $null }
  $out = New-Object byte[] ([int]$len)
  [Array]::Copy($buf, $out, $len)
  return $out
}

function Write-FwVar {
  param([string]$Name, [byte[]]$Data)
  Initialize-FwAccess | Out-Null
  $ok = [FwVar]::SetFirmwareEnvironmentVariableW($Name, $script:FwGuid, $Data, [uint32]$Data.Length)
  $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  if (-not $ok) { Warn ("写固件变量 " + $Name + " 失败 err=" + $err) }
  return $ok
}

function Remove-FwVar {
  param([string]$Name)
  Initialize-FwAccess | Out-Null
  $empty = New-Object byte[] 0
  $ok = [FwVar]::SetFirmwareEnvironmentVariableW($Name, $script:FwGuid, $empty, [uint32]0)
  if (-not $ok) { Warn ("删除固件变量 " + $Name + " 失败 err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  return $ok
}

# ---- EFI_LOAD_OPTION 解析 / 构造 ------------------------------------------
function ConvertFrom-BootEntry {
  param([byte[]]$Bytes)
  if (-not $Bytes -or $Bytes.Length -lt 8) { return $null }
  $attrs = [BitConverter]::ToUInt32($Bytes, 0)
  $pathLen = [int][BitConverter]::ToUInt16($Bytes, 4)
  $idx = 6
  $chars = New-Object System.Collections.ArrayList
  while (($idx + 1) -lt $Bytes.Length -and -not ($Bytes[$idx] -eq 0 -and $Bytes[$idx + 1] -eq 0)) {
    [void]$chars.Add([char][BitConverter]::ToUInt16($Bytes, $idx)); $idx += 2
  }
  $idx += 2
  if (($idx + $pathLen) -gt $Bytes.Length) { return $null }
  $pathList = New-Object byte[] $pathLen
  [Array]::Copy($Bytes, $idx, $pathList, 0, $pathLen)
  $optLen = $Bytes.Length - ($idx + $pathLen)
  $optional = New-Object byte[] 0
  if ($optLen -gt 0) { $optional = New-Object byte[] $optLen; [Array]::Copy($Bytes, $idx + $pathLen, $optional, 0, $optLen) }
  # 第一个设备路径节点：type=0x04(Media) sub=0x01(HardDrive) → 就是 ESP 所在 GPT 分区标识
  $node = $null
  if ($pathList.Length -ge 4 -and $pathList[0] -eq 0x04 -and $pathList[1] -eq 0x01) {
    $nodeLen = [int]$pathList[2] + 256 * [int]$pathList[3]
    if ($nodeLen -ge 4 -and $nodeLen -le $pathList.Length) { $node = New-Object byte[] $nodeLen; [Array]::Copy($pathList, 0, $node, 0, $nodeLen) }
  }
  return [pscustomobject]@{
    Attributes   = $attrs
    PathLength   = $pathLen
    Description  = (-join $chars.ToArray())
    PathList     = $pathList
    DeviceNode   = $node
    OptionalData = $optional
    Raw          = $Bytes
  }
}

function Get-BootEntryFilePathText {
  param($Entry)
  $pl = $Entry.PathList
  $idx = 0
  $text = ''
  while (($idx + 4) -le $pl.Length) {
    $type = $pl[$idx]; $sub = $pl[$idx + 1]
    $len = [int]$pl[$idx + 2] + 256 * [int]$pl[$idx + 3]
    if ($type -eq 0x7F -or $len -lt 4) { break }
    if ($type -eq 0x04 -and $sub -eq 0x04) {
      $chars = New-Object System.Collections.ArrayList
      for ($k = $idx + 4; $k -lt ($idx + $len - 2); $k += 2) { [void]$chars.Add([char][BitConverter]::ToUInt16($pl, $k)) }
      $text = -join $chars.ToArray()
    }
    $idx += $len
  }
  return $text
}

function Get-AllBootEntries {
  Initialize-FwAccess | Out-Null
  $list = @()
  for ($i = 0; $i -le 255; $i++) {
    $name = 'Boot{0:X4}' -f $i
    $raw = Read-FwVar $name
    if ($raw -and $raw.Length -gt 6) {
      $parsed = ConvertFrom-BootEntry $raw
      if ($parsed) {
        $list += [pscustomobject]@{ Name = $name; Index = $i; Entry = $parsed; FilePath = (Get-BootEntryFilePathText $parsed) }
      }
    }
  }
  return $list
}

function New-BootEntryBytes {
  param([byte[]]$DeviceNode, [string]$Description, [string]$EfiPath, [uint32]$Attributes = 1, [byte[]]$OptionalData = $null)
  $out = New-Object System.Collections.Generic.List[byte]
  # FilePathList = HardDrive 节点 + FilePath 节点 + End 节点
  $pathUtf16 = [Text.Encoding]::Unicode.GetBytes($EfiPath)
  $fpLen = 4 + $pathUtf16.Length + 2
  $pathList = New-Object System.Collections.Generic.List[byte]
  $pathList.AddRange($DeviceNode)
  $pathList.Add(0x04); $pathList.Add(0x04)
  $pathList.Add([byte]($fpLen -band 0xFF)); $pathList.Add([byte](($fpLen -shr 8) -band 0xFF))
  $pathList.AddRange($pathUtf16); $pathList.Add(0); $pathList.Add(0)
  $pathList.Add(0x7F); $pathList.Add(0xFF); $pathList.Add(0x04); $pathList.Add(0x00)
  $descBytes = [Text.Encoding]::Unicode.GetBytes($Description)
  $out.AddRange([BitConverter]::GetBytes([uint32]($Attributes -bor 1)))
  $out.AddRange([BitConverter]::GetBytes([uint16]$pathList.Count))
  $out.AddRange($descBytes); $out.Add(0); $out.Add(0)
  $out.AddRange($pathList.ToArray())
  if ($OptionalData -and $OptionalData.Length -gt 0) { $out.AddRange($OptionalData) }
  return $out.ToArray()
}

function Get-WindowsBootManagerTemplate {
  param($Entries)
  $cands = @($Entries | Where-Object { $_.Entry.DeviceNode -ne $null -and ($_.FilePath -match 'BOOTMGFW\.EFI') })
  if ($cands.Count -eq 0) { $cands = @($Entries | Where-Object { $_.Entry.DeviceNode -ne $null }) }
  if ($cands.Count -eq 0) { return $null }
  return ($cands | Sort-Object { $_.Entry.Raw.Length } -Descending | Select-Object -First 1)
}

# ---- 从“活的” ESP 分区构造设备路径节点（比抄现成启动项可靠：实测本机 NVRAM 里的
#      Windows Boot Manager 项指向的是过期分区 GUID，且缺少 FilePath 节点）----
function Get-EspPartitionInfo {
  $espType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
  $cands = @()
  try { $cands = @(Get-Partition -ErrorAction Stop | Where-Object { ([string]$_.GptType).ToLower() -eq $espType }) } catch { $cands = @() }
  if ($cands.Count -eq 0) {
    # 2026-10-08：Storage 模块/命名空间读不到分区时（客户机实测），改用 CIM → 裸读 GPT 兜底；
    #   否则这里返回 $null，后面会退化成“抄现有启动项的节点”（可能指到过期分区 → 开机干等一段再进系统）。
    $fb = Get-EspPartitionFallback -EspType $espType
    if (-not $fb) { return $null }
    Info ('ESP 分区来源: ' + $fb.Source + '（Get-Partition 读不到候选，走了兜底）')
    return $fb
  }
  $sysDisk = $null
  try { $sysDisk = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':'))).DiskNumber } catch { }
  $sameDisk = @($cands | Where-Object { $_.DiskNumber -eq $sysDisk })
  $pick = $null
  if ($sameDisk.Count -eq 1) { $pick = $sameDisk[0] }
  elseif ($sameDisk.Count -gt 1) { $pick = $sameDisk | Sort-Object PartitionNumber | Select-Object -First 1 }
  else { $pick = $cands | Select-Object -First 1 }
  return [pscustomobject]@{
    DiskNumber      = $pick.DiskNumber
    PartitionNumber = $pick.PartitionNumber
    Offset          = [uint64]$pick.Offset
    Size            = [uint64]$pick.Size
    Guid            = [Guid]$pick.Guid
    GuidText        = ([Guid]$pick.Guid).ToString()
  }
}

function New-HardDriveNode {
  param($EspPartition)
  # UEFI Media/HardDrive 节点 = 4B 头 + 4B 分区号 + 8B 起始 LBA + 8B 扇区数
  #                            + 16B 分区 GUID + 1B MBRType(0x02=GPT) + 1B SignatureType(0x02=GUID)  = 42B
  $startLba = [uint64]($EspPartition.Offset / 512)
  $sizeLba = [uint64]($EspPartition.Size / 512)
  $node = New-Object System.Collections.Generic.List[byte]
  $node.Add(0x04); $node.Add(0x01)
  $node.Add(0x2A); $node.Add(0x00)
  $node.AddRange([BitConverter]::GetBytes([uint32]$EspPartition.PartitionNumber))
  $node.AddRange([BitConverter]::GetBytes($startLba))
  $node.AddRange([BitConverter]::GetBytes($sizeLba))
  $node.AddRange($EspPartition.Guid.ToByteArray())
  $node.Add(0x02); $node.Add(0x02)
  return $node.ToArray()
}

function Get-NodeGuidText {
  param([byte[]]$Node)
  if (-not $Node -or $Node.Length -lt 20) { return '' }
  if ($Node[0] -eq 0x04 -and $Node[1] -eq 0x01) { $off = $Node.Length - 18 } else { $off = 4 }
  if ($off + 16 -gt $Node.Length) { return '' }
  $g = New-Object byte[] 16
  [Array]::Copy($Node, $off, $g, 0, 16)
  try { return ([Guid]::new($g)).ToString() } catch { return '' }
}

function Show-EspPathCheck {
  param($Entries, $EspPart)
  if (-not $EspPart) { Info '取不到 ESP 分区记录（Get-Partition 失败），将退化为抄现有启动项的节点'; return $null }
  $node = New-HardDriveNode -EspPartition $EspPart
  Info ("ESP 分区: disk " + $EspPart.DiskNumber + " 分区 " + $EspPart.PartitionNumber + " 起始 " + $EspPart.Offset + " B / 大小 " + $EspPart.Size + " B")
  Info ("ESP GPT GUID: " + $EspPart.GuidText)
  Info ("由现场分区构造的设备路径节点(" + $node.Length + " B): " + [BitConverter]::ToString($node))
  $match = $null
  foreach ($e in $Entries) {
    if ($e.Entry.DeviceNode) {
      $gt = Get-NodeGuidText $e.Entry.DeviceNode
      if ($gt -and $gt -eq $EspPart.GuidText) { if (-not $match) { $match = $e } }
      elseif ($gt -and ($e.FilePath -match 'BOOTMGFW\.EFI')) { Info ("  注: " + $e.Name + " '" + $e.Entry.Description + "' 指向的 GUID " + $gt + " 与现场 ESP 不一致（过期项，不能用它做模板）") }
    }
  }
  if ($match) {
    $same = ([Convert]::ToBase64String($node) -eq [Convert]::ToBase64String($match.Entry.DeviceNode))
    if ($same) { Ok ("构造节点与现场启动项 " + $match.Name + " 的节点逐字节一致 → 设备路径算法已验证") }
    else { Warn ("构造节点与 " + $match.Name + " 的节点不完全一致（可能分区大小/起始有变，仍以现场分区为准）") }
  } else { Info '固件里还没有指向当前 ESP 的启动项（本脚本会创建一个）' }
  return $node
}

function Get-UnlockBootEntry {
  param($Entries)
  return ($Entries | Where-Object { $_.FilePath -match '40HXUNLK\.EFI' -or $_.Entry.Description -match '^40HX' } | Select-Object -First 1)
}

# 选空闲 Boot#### 槽位：优先 0004..00FF（0x0000-0x0003 常被固件/系统占用，如 Windows Boot Manager、
# 厂商恢复项），都没有才回头用低位。实测本机 Boot0000/0001 为空，但把解锁项放低位不如放中段保险。
function Get-FreeBootSlot {
  param($Entries)
  $used = @($Entries | ForEach-Object { $_.Index })
  foreach ($range in @((4..255), (0..3))) {
    foreach ($i in $range) { if ($used -notcontains $i) { return $i } }
  }
  return -1
}

function Get-BootOrderIndices {
  $raw = Read-FwVar 'BootOrder'
  $list = @()
  if (-not $raw) { return $list }
  for ($i = 0; ($i + 1) -lt $raw.Length; $i += 2) { $list += [int][BitConverter]::ToUInt16($raw, $i) }
  return $list
}

function Write-BootOrderIndices {
  param([int[]]$Indices, [string]$BackupDir)
  # 2026-10-01b（第三方审查 D2）：**读不到当前 BootOrder 就绝不改写**。
  #   原实现：Read-FwVar 失败 → $cur 空 → 照样写新顺序；而调用方拿到的 $order 也是空 @()，
  #   于是 BootOrder 被写成"只含解锁项 1 个元素" → Windows Boot Manager 等全部丢失 = 开不了机且无备份。
  $cur = Read-FwVar 'BootOrder'
  if (-not $cur -or $cur.Length -lt 2) {
    Warn '读不到当前 BootOrder（固件变量读取失败）→ 拒绝改写 BootOrder（防止把引导顺序写坏）'
    return $false
  }
  if (@($Indices).Count -eq 0) { Warn '新 BootOrder 为空 → 拒绝写入'; return $false }
  if ($BackupDir) {
    try { [IO.File]::WriteAllBytes((Join-Path $BackupDir 'BootOrder.before.bin'), $cur) }
    catch { Warn ('BootOrder 备份失败（' + $_.Exception.Message + '）→ 拒绝改写'); return $false }
    # 审查 H11：文档承诺"备份全部 Boot####"，这里真正落实
    try {
      $n = 0
      foreach ($e in @(Get-AllBootEntries)) {
        $v = Read-FwVar ('Boot' + ('{0:X4}' -f $e.Index))
        if ($v) { [IO.File]::WriteAllBytes((Join-Path $BackupDir ('Boot' + ('{0:X4}' -f $e.Index) + '.before.bin')), $v); $n++ }
      }
      Info ('已备份全部 Boot####: ' + $n + ' 项 → ' + $BackupDir)
    } catch { Warn ('备份 Boot#### 时出错: ' + $_.Exception.Message) }
  }
  $bytes = New-Object System.Collections.Generic.List[byte]
  foreach ($idx in $Indices) { $bytes.AddRange([BitConverter]::GetBytes([uint16]$idx)) }
  return (Write-FwVar 'BootOrder' $bytes.ToArray())
}

function Format-BootOrderIndices { param([int[]]$Indices) return (($Indices | ForEach-Object { '{0:X4}' -f $_ }) -join ',') }

# ================================================================ 存储信息：多后端探测（2026-10-08）
# 现场问题（客户机 Windows 11 26100）：Install 报「系统盘不是 GPT（未知）」，而 diskpart 里磁盘 0/1/2
#   全是 GPT —— 说明是**判定失败**：Get-Partition/Get-Disk 抛异常被 catch 吞成 '未知'，看着像 MBR 盘，
#   然后被当硬门槛挡住整台机器（装机版/精简版 Windows、Storage 提供程序异常、WMI 存储命名空间坏掉都可能这样）。
# 处理原则：
#   ① 判定改成多后端，谁先给出结论用谁（后端1 命中时行为与旧版**完全一致**）；
#   ② 每个后端的成败与**原始错误文本**都记进 $script:StorageDiag（-Mode StorageDiag 全量打印，出事能定位）；
#   ③ 只有真读出 MBR 才算硬门槛；'未知' 降级为提示 + 诊断（让后面的 ESP/固件启动项步骤说话，别提前挡死）。
# 后端顺序：
#   1 Storage 模块 Get-Partition/Get-Disk（正常机器走这条）
#   2 CIM root/Microsoft/Windows/Storage（同一提供程序，但**不需要 PowerShell 的 Storage 模块**）
#   3 root/cimv2 老 WMI（Win32_LogicalDiskToPartition / Win32_DiskPartition，提供程序与 Storage 无关）
#   4 直接读物理磁盘 LBA0/LBA1（不用任何 WMI/模块，需要管理员）
#   5 裸读扫描 0..15 号盘 + mountvol 卷 GUID 反查系统盘（完全不需要 WMI；顺带解析出 ESP 分区）
$script:StorageDiag = New-Object System.Collections.ArrayList
$script:StorageFacts = $null
$script:EspTypeGuidLc = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
function Add-StorageDiag { param([string]$Text) [void]$script:StorageDiag.Add($Text) }
function Show-StorageDiag { foreach ($l in @($script:StorageDiag)) { Info $l } }

# ---- 后端1：Storage 模块（老路径，正常机器就是这条）--------------------------
function Get-SysPartitionByCmdlet {
  param([string]$Letter)
  try {
    $p = @(Get-Partition -DriveLetter $Letter -ErrorAction Stop)
    if ($p.Count -eq 0) { Add-StorageDiag '后端1 Storage 模块: Get-Partition 返回 0 个分区'; return $null }
    if ($p.Count -gt 1) { Add-StorageDiag ('后端1 Storage 模块: 盘符 ' + $Letter + ' 命中 ' + $p.Count + ' 个分区，取第一个') }
    $p = $p[0]
    $o = [pscustomobject]@{
      DiskNumber = [int]$p.DiskNumber; PartitionNumber = [int]$p.PartitionNumber
      Offset = [uint64]$p.Offset; Size = [uint64]$p.Size; Guid = ([string]$p.Guid).ToLower()
      Source = '后端1 Storage 模块'
    }
    Add-StorageDiag ('后端1 Storage 模块: 盘符 ' + $Letter + ' → disk ' + $o.DiskNumber + ' 分区 ' + $o.PartitionNumber + ' 起始 ' + $o.Offset + ' B 大小 ' + $o.Size + ' B GUID ' + $o.Guid)
    return $o
  } catch { Add-StorageDiag ('后端1 Storage 模块: Get-Partition 失败 - ' + $_.Exception.Message); return $null }
}
function Get-DiskStyleByCmdlet {
  param([int]$Number)
  try {
    $d = Get-Disk -Number $Number -ErrorAction Stop
    $s = [string]$d.PartitionStyle
    Add-StorageDiag ('后端1 Storage 模块: Get-Disk ' + $Number + ' → ' + $s + '（' + [string]$d.FriendlyName + '）')
    return $s
  } catch { Add-StorageDiag ('后端1 Storage 模块: Get-Disk 失败 - ' + $_.Exception.Message); return '' }
}

# ---- 后端2：CIM（root/Microsoft/Windows/Storage，不需要 Storage 模块）---------
function Get-CimStorageList {
  param([string]$ClassName, [string]$Filter = '')
  $ns = 'root/Microsoft/Windows/Storage'
  try {
    if ($Filter) { return @(Get-CimInstance -Namespace $ns -ClassName $ClassName -Filter $Filter -ErrorAction Stop) }
    return @(Get-CimInstance -Namespace $ns -ClassName $ClassName -ErrorAction Stop)
  } catch {
    Add-StorageDiag ('后端2 CIM ' + $ClassName + $(if ($Filter) { '(' + $Filter + ')' } else { '' }) + ': 失败 - ' + $_.Exception.Message)
    return @()
  }
}
function Convert-DiskStyleNumber { param($V) switch ([int]$V) { 1 { return 'MBR' } 2 { return 'GPT' } default { return '' } } }
function Get-SysPartitionByCim {
  param([string]$Letter)
  $code = [uint32][char]$Letter[0]
  $arr = @(Get-CimStorageList 'MSFT_Partition' ('DriveLetter=' + $code))
  if (@($arr).Count -eq 0) { Add-StorageDiag ('后端2 CIM: 没找到盘符 ' + $Letter + ' 的分区（MSFT_Partition DriveLetter=' + $code + '）'); return $null }
  $p = @($arr)[0]
  $o = [pscustomobject]@{
    DiskNumber = [int]$p.DiskNumber; PartitionNumber = [int]$p.PartitionNumber
    Offset = [uint64]$p.Offset; Size = [uint64]$p.Size; Guid = ([string]$p.Guid).ToLower()
    Source = '后端2 CIM(Storage 命名空间)'
  }
  Add-StorageDiag ('后端2 CIM: 盘符 ' + $Letter + ' → disk ' + $o.DiskNumber + ' 分区 ' + $o.PartitionNumber + ' 起始 ' + $o.Offset + ' B 大小 ' + $o.Size + ' B GUID ' + $o.Guid)
  return $o
}
function Get-SysDiskNumberByCim {
  $arr = @(Get-CimStorageList 'MSFT_Disk' | Where-Object { $_.IsSystem -eq $true })
  if (@($arr).Count -gt 0) { Add-StorageDiag ('后端2 CIM: IsSystem 磁盘 = ' + [int]$arr[0].Number); return [int]$arr[0].Number }
  Add-StorageDiag '后端2 CIM: 没有 IsSystem 的磁盘'; return -1
}
function Get-DiskStyleByCim {
  param([int]$Number)
  $arr = @(Get-CimStorageList 'MSFT_Disk' | Where-Object { [int]$_.Number -eq $Number })
  if (@($arr).Count -eq 0) { Add-StorageDiag ('后端2 CIM: 没有 disk ' + $Number); return '' }
  $s = Convert-DiskStyleNumber $arr[0].PartitionStyle
  Add-StorageDiag ('后端2 CIM: disk ' + $Number + ' PartitionStyle=' + [int]$arr[0].PartitionStyle + ' → ' + $(if ($s) { $s } else { '未知' }) + '（' + [string]$arr[0].FriendlyName + '）')
  return $s
}

# ---- 后端3：root/cimv2 老 WMI（提供程序与 Storage 无关）-----------------------
function Get-SysDiskByOldWmi {
  try {
    $partId = ''
    foreach ($a in @(Get-CimInstance -ClassName Win32_LogicalDiskToPartition -ErrorAction Stop)) {
      if ([string]$a.Dependent -match ('LogicalDisk.*DeviceID\s*=\s*"' + [regex]::Escape($env:SystemDrive) + '"')) {
        $m = [regex]::Match([string]$a.Antecedent, 'Disk #\d+, Partition #\d+')
        if ($m.Success) { $partId = $m.Value; break }
      }
    }
    if (-not $partId) { Add-StorageDiag ('后端3 老 WMI: Win32_LogicalDiskToPartition 里没找到 ' + $env:SystemDrive); return $null }
    $dn = [int]([regex]::Match($partId, 'Disk #(\d+)').Groups[1].Value)
    $typeText = ''
    $pp = @(Get-CimInstance -ClassName Win32_DiskPartition -Filter ("DeviceID='" + $partId + "'") -ErrorAction Stop)
    if (@($pp).Count -gt 0) { $typeText = [string]$pp[0].Type }
    # 只有 'GPT: xxx' 前缀能确定是 GPT；动态磁盘/老 MBR 的 Type 文本不带前缀 → 不能反推 MBR（交给后端4）
    $style = ''
    if ($typeText -match '^GPT') { $style = 'GPT' }
    Add-StorageDiag ('后端3 老 WMI: ' + $env:SystemDrive + ' = ' + $partId + '（Type="' + $typeText + '"）→ ' + $(if ($style) { $style } else { '无法判定，需裸读确认' }))
    return [pscustomobject]@{ DiskNumber = $dn; Style = $style; Type = $typeText }
  } catch { Add-StorageDiag ('后端3 老 WMI: 失败 - ' + $_.Exception.Message); return $null }
}

# ---- GPT 分区表裸解析（后端4/5 用；不依赖任何 WMI / PowerShell 模块）---------
function New-GptEntryInfo {
  param([int]$Index, [byte[]]$Bytes)
  $t = New-Object byte[] 16; [Array]::Copy($Bytes, 0, $t, 0, 16)
  $u = New-Object byte[] 16; [Array]::Copy($Bytes, 16, $u, 0, 16)
  $first = [BitConverter]::ToUInt64($Bytes, 32)
  $last = [BitConverter]::ToUInt64($Bytes, 40)
  return [pscustomobject]@{
    PartitionNumber = $Index + 1
    TypeGuid = ([Guid]::new($t)).ToString().ToLower()
    UniqueGuid = ([Guid]::new($u)).ToString().ToLower()
    FirstLba = $first; LastLba = $last
    Offset = [uint64]($first * 512)
    Size = [uint64](($last - $first + 1) * 512)
  }
}
# 传 FileStream：物理磁盘（\\.\PHYSICALDRIVEn）和普通文件都能用 —— 普通文件便于离线单测
function Read-GptTable {
  param($Stream)
  $res = @{ Ok = $false; Err = ''; Entries = @(); DiskGuid = ''; EntryLba = 0; Count = 0; EntrySize = 0 }
  try {
    $hdr = New-Object byte[] 512
    $Stream.Position = [int64]512
    $got = $Stream.Read($hdr, 0, 512)
    if ($got -lt 92) { $res.Err = ('LBA1 只读到 ' + $got + ' 字节'); return $res }
    if ([Text.Encoding]::ASCII.GetString($hdr, 0, 8) -ne 'EFI PART') { $res.Err = 'LBA1 不是 EFI PART 签名（不是 GPT）'; return $res }
    $res.EntryLba = [BitConverter]::ToUInt64($hdr, 72)
    $res.Count = [int][BitConverter]::ToUInt32($hdr, 80)
    $res.EntrySize = [int][BitConverter]::ToUInt32($hdr, 84)
    $dg = New-Object byte[] 16; [Array]::Copy($hdr, 56, $dg, 0, 16)
    $res.DiskGuid = ([Guid]::new($dg)).ToString().ToLower()
    if ($res.Count -lt 1 -or $res.Count -gt 512 -or $res.EntrySize -lt 128 -or $res.EntrySize -gt 4096 -or ($res.EntrySize % 128) -ne 0 -or $res.EntryLba -lt 2) {
      # 2026-10-08（DSH 审查 Q3 低危项）：补两条 —— 表项大小必须是 128 的倍数（GPT 规范）、
      #   分区表 LBA 至少是 2（LBA0=MBR / LBA1=GPT 头）。损坏表头只会走到 Err，不会算出垃圾偏移/大小。
      $res.Err = ('GPT 头异常: 表项数=' + $res.Count + ' 表项大小=' + $res.EntrySize + ' 表项LBA=' + $res.EntryLba); return $res
    }
    $total = $res.Count * $res.EntrySize
    $buf = New-Object byte[] $total
    $Stream.Position = [int64]($res.EntryLba * 512)
    $read = 0
    while ($read -lt $total) { $n = $Stream.Read($buf, $read, $total - $read); if ($n -le 0) { break }; $read += $n }
    if ($read -lt $total) { $res.Err = ('分区表读不全: ' + $read + '/' + $total); return $res }
    $list = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $res.Count; $i++) {
      $off = $i * $res.EntrySize
      $zero = $true
      for ($k = 0; $k -lt 16; $k++) { if ($buf[$off + $k] -ne 0) { $zero = $false; break } }
      if ($zero) { continue }
      $e = New-Object byte[] $res.EntrySize
      [Array]::Copy($buf, $off, $e, 0, $res.EntrySize)
      [void]$list.Add((New-GptEntryInfo -Index $i -Bytes $e))
    }
    $res.Entries = @($list); $res.Ok = $true
    return $res
  } catch { $res.Err = $_.Exception.Message; return $res }
}
function Get-DiskRawProbe {
  param([int]$Number, $Stream = $null)   # Stream 只给离线单测用：塞一个普通文件流，就能跑同一条解析路径
  # 只读打开物理磁盘，读 LBA0（MBR/保护性 MBR）+ LBA1（GPT 头 + 分区表）
  $fs = $Stream
  $mine = $false
  try {
    if (-not $fs) {
      $fs = New-Object IO.FileStream(('\\.\PHYSICALDRIVE' + $Number), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      $mine = $true
    }
    $sec = New-Object byte[] 512
    $fs.Position = [int64]0
    $n = $fs.Read($sec, 0, 512)
    if ($n -lt 512) { return @{ Ok = $false; Err = ('LBA0 只读到 ' + $n + ' 字节') } }
    $gpt = Read-GptTable -Stream $fs
    return @{
      Ok = $true; Err = ''; Gpt = $gpt
      FirstType = [int]$sec[450]                       # 第一个分区表项的类型（0xEE = 保护性 MBR = GPT）
      MbrSig = ($sec[510] -eq 0x55 -and $sec[511] -eq 0xAA)
      Active = ([int]$sec[446] -eq 0x80)               # 第一个分区表项的活动标志
      DiskSig = ('{0:X8}' -f [BitConverter]::ToUInt32($sec, 440))
    }
  } catch { return @{ Ok = $false; Err = $_.Exception.Message } } finally { if ($mine -and $fs) { $fs.Dispose() } }
}
function Get-RawStyleFromProbe {
  param($Probe)
  if (-not $Probe -or -not $Probe.Ok) { return '' }
  if ($Probe.Gpt -and $Probe.Gpt.Ok) { return 'GPT' }
  if ($Probe.FirstType -eq 0xEE) { return 'GPT' }      # 4Kn 盘 GPT 头在 LBA1*4096，靠保护性 MBR 认出来
  if ($Probe.MbrSig) { return 'MBR' }
  return ''
}
# 磁盘号是连续的：碰到“找不到文件”就说明后面没有更多磁盘了 —— 别把 10..15 的噪音打满屏
function Test-RawDiskMissing { param([string]$Err) return ($Err -match '未能找到文件|cannot find the file|系统找不到指定的文件') }

# ---- 后端5：裸读扫描 + mountvol 卷 GUID 反查系统盘（完全不需要 WMI）----------
function Get-SysDiskByRawScan {
  $vol = Get-EspVolumeGuid ($env:SystemDrive)
  if (-not $vol) { Add-StorageDiag ('后端5 裸读扫描: mountvol 读不到 ' + $env:SystemDrive + ' 的卷 GUID'); return $null }
  Add-StorageDiag ('后端5 裸读扫描: ' + $env:SystemDrive + ' 卷 GUID=' + $vol + ' → 在磁盘 0..15 的 GPT 分区表里反查')
  $bootCands = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt 16; $i++) {
    $pr = Get-DiskRawProbe -Number $i
    if (-not $pr.Ok) {
      Add-StorageDiag ('后端5 裸读扫描: disk ' + $i + ' 打不开 - ' + $pr.Err)
      if (Test-RawDiskMissing ([string]$pr.Err)) { Add-StorageDiag ('后端5 裸读扫描: disk ' + $i + ' 之后没有更多磁盘，停止扫描'); break }
      continue
    }
    if ($pr.Gpt -and $pr.Gpt.Ok) {
      Add-StorageDiag ('后端5 裸读扫描: disk ' + $i + ' = GPT（分区 ' + @($pr.Gpt.Entries).Count + ' 个，磁盘 GUID ' + $pr.Gpt.DiskGuid + '）')
      if (@($pr.Gpt.Entries | Where-Object { $_.UniqueGuid -eq $vol }).Count -gt 0) {
        Add-StorageDiag ('后端5 裸读扫描: disk ' + $i + ' 的分区表里含 ' + $env:SystemDrive + ' 的卷 GUID → 这就是系统盘')
        return @{ DiskNumber = $i; Style = 'GPT'; StyleByGuess = $false; Probe = $pr; VolumeGuid = $vol }
      }
    } else {
      $st = Get-RawStyleFromProbe $pr
      Add-StorageDiag ('后端5 裸读扫描: disk ' + $i + ' 不是 GPT（LBA1: ' + [string]$pr.Gpt.Err + '；LBA0 首分区类型=0x' + ('{0:X2}' -f $pr.FirstType) + ' 启动签名=' + [string]$pr.MbrSig + '）')
      if ($st -eq 'MBR' -and $pr.Active) { [void]$bootCands.Add($i) }
    }
  }
  if ($bootCands.Count -gt 0) {
    Add-StorageDiag ('后端5 裸读扫描: 有活动(0x80)分区的 MBR 盘 = ' + ($bootCands -join ',') + ' → 按推断取 disk ' + $bootCands[0])
    return @{ DiskNumber = [int]$bootCands[0]; Style = 'MBR'; StyleByGuess = $true; Probe = $null; VolumeGuid = $vol }
  }
  Add-StorageDiag '后端5 裸读扫描: 没反查到系统盘'
  return $null
}

# ---- 汇总：系统盘样式 + 系统盘分区 + ESP 分区（带缓存，一次运行只算一次）-----
function Get-StorageFacts {
  if ($script:StorageFacts) { return $script:StorageFacts }
  $f = @{ Style = '未知'; StyleSource = ''; StyleConfirmed = $false; StyleError = ''
          SysDisk = -1; SysPart = $null; EspPart = $null; VolumeGuid = ''; RawProbe = $null }
  $script:StorageFacts = $f
  $letter = $env:SystemDrive.TrimEnd(':')
  # 后端1
  $p = Get-SysPartitionByCmdlet $letter
  if ($p) {
    $f.SysPart = $p; $f.SysDisk = $p.DiskNumber
    $st = Get-DiskStyleByCmdlet $p.DiskNumber
    if ($st) { $f.Style = $st; $f.StyleSource = '后端1 Storage 模块 (Get-Disk)'; $f.StyleConfirmed = $true }
  }
  # 后端2
  if ($f.Style -eq '未知') {
    if (-not $f.SysPart) { $p = Get-SysPartitionByCim $letter; if ($p) { $f.SysPart = $p; $f.SysDisk = $p.DiskNumber } }
    $dn = $f.SysDisk
    if ($dn -lt 0) { $dn = Get-SysDiskNumberByCim }
    if ($dn -ge 0) {
      $st = Get-DiskStyleByCim $dn
      if ($st) {
        $f.Style = $st; $f.StyleSource = '后端2 CIM (MSFT_Disk)'; $f.StyleConfirmed = $true
        if ($f.SysDisk -lt 0) { $f.SysDisk = $dn }
      }
    }
  }
  # 后端3
  if ($f.Style -eq '未知' -or $f.SysDisk -lt 0) {
    $w = Get-SysDiskByOldWmi
    if ($w) {
      if ($f.SysDisk -lt 0) { $f.SysDisk = $w.DiskNumber }
      if ($f.Style -eq '未知' -and $w.Style) { $f.Style = $w.Style; $f.StyleSource = '后端3 root/cimv2 (Win32_DiskPartition)'; $f.StyleConfirmed = $true }
    }
  }
  # 后端4（已知磁盘号 → 裸读确认）
  if ($f.Style -eq '未知' -and $f.SysDisk -ge 0) {
    $pr = Get-DiskRawProbe -Number $f.SysDisk
    if ($pr.Ok) {
      $f.RawProbe = $pr
      $st = Get-RawStyleFromProbe $pr
      if ($st) { $f.Style = $st; $f.StyleSource = ('后端4 裸读 LBA0/LBA1 (disk ' + $f.SysDisk + ')'); $f.StyleConfirmed = $true }
    } else { Add-StorageDiag ('后端4 裸读: disk ' + $f.SysDisk + ' 失败 - ' + [string]$pr.Err) }
  }
  # 后端5（裸读扫描 + 卷 GUID 反查）—— 只在“样式还没定”或“系统盘号还不知道”时才扫，
  #   正常机器（后端1 已给出结论）不要为了兜底去开 16 个物理磁盘句柄。
  if ($f.Style -eq '未知' -or $f.SysDisk -lt 0) {
    $s = Get-SysDiskByRawScan
    if ($s) {
      if ($f.SysDisk -lt 0) { $f.SysDisk = $s.DiskNumber }
      $f.VolumeGuid = [string]$s.VolumeGuid
      if ($f.Style -eq '未知' -and $s.Style) {
        $f.Style = $s.Style
        $f.StyleSource = $(if ($s.StyleByGuess) { '后端5 裸读扫描 + 活动分区推断（不确定）' } else { '后端5 裸读扫描 + 卷 GUID 反查' })
        $f.StyleConfirmed = (-not $s.StyleByGuess)
      }
      if ($s.Probe) { $f.RawProbe = $s.Probe }
    }
  }
  if ($f.Style -eq '未知') { $f.StyleError = '所有后端都读不出分区样式（Storage 模块 / CIM 存储命名空间 / 老 WMI / 裸读 全失败，逐条见下面的「存储信息诊断」）' }
  return $f
}

# ---- ESP 兜底：Get-Partition 拿不到候选时，改用 CIM → 裸读 GPT --------------
function New-EspPartFromRaw {
  param([int]$DiskNumber, [int]$PartitionNumber, [uint64]$Offset, [uint64]$Size, [string]$Guid, [string]$Source = '')
  if ([string]::IsNullOrEmpty($Guid)) { return $null }
  $g = [Guid]$Guid
  return [pscustomobject]@{
    DiskNumber = $DiskNumber; PartitionNumber = $PartitionNumber
    Offset = $Offset; Size = $Size; Guid = $g; GuidText = $g.ToString().ToLower(); Source = $Source
  }
}
function Get-EspPartitionFallback {
  param([string]$EspType = $script:EspTypeGuidLc)
  $f = Get-StorageFacts
  # 坑（2026-10-08 离线单测抓到）：调用方传进来的是**带花括号**的形式 '{c12a7328-…}'（Get-Partition 的 GptType 就是带括号的），
  #   而裸读 GPT 解析出的 TypeGuid 是**不带花括号的小写** → 直接比对永远不中，ESP 兜底会静默失效。
  #   这里统一成不带括号的小写；给 CIM 用的时候再补回花括号。
  $espNorm = ([string]$EspType).Trim().Trim('{', '}').ToLower()
  # 系统盘号都不知道（Storage + CIM + 老 WMI 全挂了）→ 先用卷 GUID 裸读反查一遍
  if ($f.SysDisk -lt 0) {
    $s = Get-SysDiskByRawScan
    if ($s) { $f.SysDisk = $s.DiskNumber; $f.VolumeGuid = [string]$s.VolumeGuid; if ($s.Probe) { $f.RawProbe = $s.Probe } }
  }
  # ① CIM（Storage 命名空间；老路径的 Get-Partition 挂了，CIM 可能还活着）
  $arr = @(Get-CimStorageList 'MSFT_Partition' ("GptType='{" + $espNorm + "}'"))
  if (@($arr).Count -gt 0) {
    $same = @($arr | Where-Object { [int]$_.DiskNumber -eq $f.SysDisk })
    $pick = $null
    if ($same.Count -gt 0) { $pick = @($same | Sort-Object { [int]$_.PartitionNumber })[0] } else { $pick = @($arr | Sort-Object { [int]$_.PartitionNumber })[0] }
    Add-StorageDiag ('ESP 兜底(CIM): disk ' + [int]$pick.DiskNumber + ' 分区 ' + [int]$pick.PartitionNumber + ' 起始 ' + [uint64]$pick.Offset + ' B 大小 ' + [uint64]$pick.Size + ' B')
    $o = New-EspPartFromRaw -DiskNumber ([int]$pick.DiskNumber) -PartitionNumber ([int]$pick.PartitionNumber) -Offset ([uint64]$pick.Offset) -Size ([uint64]$pick.Size) -Guid ([string]$pick.Guid) -Source 'CIM(Storage 命名空间)'
    if ($o) { return $o }
  }
  # ② 裸读 GPT（完全不需要 WMI）
  $pr = $f.RawProbe
  if ((-not $pr -or -not $pr.Ok) -and $f.SysDisk -ge 0) { $pr = Get-DiskRawProbe -Number $f.SysDisk }
  if ($pr -and $pr.Ok -and $pr.Gpt -and $pr.Gpt.Ok) {
    $esp = @($pr.Gpt.Entries | Where-Object { $_.TypeGuid -eq $espNorm })
    if ($esp.Count -gt 0) {
      $pick = @($esp | Sort-Object PartitionNumber)[0]
      Add-StorageDiag ('ESP 兜底(裸读): disk ' + $f.SysDisk + ' 分区 ' + $pick.PartitionNumber + ' 起始 ' + $pick.Offset + ' B 大小 ' + $pick.Size + ' B GUID ' + $pick.UniqueGuid)
      return (New-EspPartFromRaw -DiskNumber $f.SysDisk -PartitionNumber $pick.PartitionNumber -Offset $pick.Offset -Size $pick.Size -Guid $pick.UniqueGuid -Source ('裸读 GPT (disk ' + $f.SysDisk + ')'))
    }
    Add-StorageDiag 'ESP 兜底(裸读): 系统盘的分区表里没有 ESP 类型分区'
  }
  return $null
}

# ---- 只读预检：样式"未知"的机器，只要 ESP 也挂不上，就必须在**动手改任何东西之前**停
# 2026-10-08（按 DSH 审查 Q4 加）：'未知' 不再当硬门槛后，真 MBR/非 UEFI 引导的机器会一路走到
#   Install-Efi 的挂 ESP 那一步才失败 —— 但它前面已经落了驱动/服务/注册表/任务 6 步改动，留下半成品。
#   这里用只读事实补回来：Get-CheckReport 里已经试挂过 ESP（$rep.Esp，管理员才会有值），
#   挂不上 = 这台机器确实没有可用的 EFI 系统分区 → 按旧版行为"一步都不改"地停住（只是理由写得对）。
#   反过来：GPT 盘 + 存储接口坏（客户机那种）照样能装 —— ESP 挂得上，这条不成立。
function Test-EspPrecheckBlocked {
  param($Report)
  if ([string]$Report.DiskStyle -eq 'GPT') { return $false }
  # 只有「MBR **且已确认**」才跳过 —— 那种情况下上面那条 Bad 已经拦了，别重复计数。
  # 坑（2026-10-08 DSH 第二轮审查 · 必修）：原来是只要 DiskStyle 等于 MBR 就无条件跳过，
  #   而后端5「活动分区推断」会产出 Style='MBR' 但 Confirmed=$false —— 那种机器会落进 elseif
  #   （因为调用方的 Bad 条件是 `MBR -and Confirmed`），然后被这个函数放过，于是照样先落 6 步写操作、
  #   到挂 ESP 才失败 = Q4 没堵全。现在改成必须"已确认"才跳过。
  if ([string]$Report.DiskStyle -eq 'MBR' -and $Report.DiskStyleConfirmed) { return $false }
  if (-not $Report.Admin) { return $false }                   # 没试挂过（非管理员）→ 不据此下结论
  if ($Report.Esp) { return $false }
  return $true
}

# ---- 诊断模式：把上面所有后端的原始结果打全（客户机让你一眼看出为什么判定失败）----
function Invoke-StorageDiag {
  Head '存储信息诊断（StorageDiag）'
  Info ('管理员   : ' + (Test-Admin))
  Info ('系统盘   : ' + $env:SystemDrive + '    机器名: ' + $env:COMPUTERNAME)
  try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop; Info ('系统     : ' + [string]$os.Caption + '  ' + [string]$os.Version + '  build ' + [string]$os.BuildNumber) } catch { Info ('系统     : 读不到（' + $_.Exception.Message + '）') }
  try { Info ('固件类型 : ' + (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType) } catch { Info ('固件类型 : 读不到（' + $_.Exception.Message + '）') }
  $modDir = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules\Storage'
  $mods = @()
  try { $mods = @(Get-Module -ListAvailable -Name Storage -ErrorAction SilentlyContinue | ForEach-Object { $_.Path }) } catch { }
  Info ('Storage 模块: 目录存在=' + (Test-Path $modDir) + '（' + $modDir + '）  Get-Module 找到=' + $mods.Count + $(if ($mods.Count -gt 0) { ' → ' + ($mods -join ' ; ') } else { '' }))
  Info '（上面这行是关键：装机版/精简版 Windows 常把 Storage 模块删掉，Get-Partition/Get-Disk 就整个不可用）'
  Info ('C: 卷 GUID: ' + (Get-EspVolumeGuid $env:SystemDrive) + '（mountvol，不需要 WMI）')
  Head '各后端结论'
  $f = Get-StorageFacts
  Info ('分区样式 : ' + $f.Style + $(if ($f.StyleConfirmed) { '（已确认）' } else { '（未确认）' }) + '    来源: ' + $(if ($f.StyleSource) { $f.StyleSource } else { '无' }))
  Info ('系统盘号 : ' + $(if ($f.SysDisk -ge 0) { [string]$f.SysDisk } else { '未知' }))
  if ($f.SysPart) { Info ('C: 分区  : disk ' + $f.SysPart.DiskNumber + ' 分区 ' + $f.SysPart.PartitionNumber + ' 起始 ' + $f.SysPart.Offset + ' B 大小 ' + $f.SysPart.Size + ' B 来源=' + $f.SysPart.Source) } else { Info 'C: 分区  : 拿不到' }
  # ESP：主路径（Get-Partition）与最终结果分开打印 —— 兜底到底有没有用上，一眼可见
  $mainN = -1; $mainErr = ''
  try { $mainN = @(Get-Partition -ErrorAction Stop | Where-Object { ([string]$_.GptType).ToLower() -eq $script:EspTypeGuidLc }).Count } catch { $mainErr = $_.Exception.Message }
  Info ('ESP 主路径: Get-Partition 候选 = ' + $(if ($mainN -lt 0) { '调用失败 - ' + $mainErr } else { [string]$mainN + ' 个' }))
  $esp = $null
  try { $esp = Get-EspPartitionInfo } catch { Info ('ESP 分区  : Get-EspPartitionInfo 抛异常 - ' + $_.Exception.Message) }
  if ($esp) { Info ('ESP 分区  : disk ' + $esp.DiskNumber + ' 分区 ' + $esp.PartitionNumber + ' 起始 ' + $esp.Offset + ' B 大小 ' + $esp.Size + ' B GUID ' + $esp.GuidText + ' 来源=' + $(if ($esp.PSObject.Properties['Source']) { $esp.Source } else { '主路径 Get-Partition' })) }
  else { Info 'ESP 分区  : 拿不到（主路径与兜底都没找到）' }
  Head '逐盘裸读（0..15，不需要 WMI；需要管理员）'
  for ($i = 0; $i -lt 16; $i++) {
    $pr = Get-DiskRawProbe -Number $i
    if (-not $pr.Ok) {
      Info ('disk ' + $i + ' : 打不开 - ' + [string]$pr.Err)
      if (Test-RawDiskMissing ([string]$pr.Err)) { Info ('disk ' + $i + ' 之后没有更多磁盘，停止扫描'); break }
      continue
    }
    $st = Get-RawStyleFromProbe $pr
    $line = 'disk ' + $i + ' : ' + $(if ($st) { $st } else { '样式无法判定' }) + '  LBA0首分区类型=0x' + ('{0:X2}' -f $pr.FirstType) + ' 启动签名=' + [string]$pr.MbrSig + ' 磁盘签名=' + [string]$pr.DiskSig
    if ($pr.Gpt -and $pr.Gpt.Ok) {
      $line += '  GPT: 分区 ' + @($pr.Gpt.Entries).Count + ' 个 磁盘GUID=' + $pr.Gpt.DiskGuid
      Info $line
      foreach ($e in @($pr.Gpt.Entries)) { Info ('          分区 ' + $e.PartitionNumber + ' 类型 ' + $e.TypeGuid + ' 起始 ' + $e.Offset + ' B 大小 ' + $e.Size + ' B GUID ' + $e.UniqueGuid + $(if ($e.TypeGuid -eq ([string]$script:EspTypeGuidLc).Trim('{', '}').ToLower()) { '   <== ESP' } else { '' })) }
    } else { Info ($line + '  非 GPT: ' + [string]$pr.Gpt.Err) }
  }
  Head '后端调用明细（原始错误文本）'
  Show-StorageDiag
  Say ''
  Say '   把这一屏（或本次 run-*.log）发给作者即可定位。' 'Yellow'
}

# ================================================================ 体检
function Get-CheckReport {
  $r = [ordered]@{}
  $r.Admin = Test-Admin
  try { $r.Firmware = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType } catch { $r.Firmware = '未知' }
  try { $r.SecureBoot = (Confirm-SecureBootUEFI) } catch { $r.SecureBoot = '未知' }
  # 2026-10-08：多后端判定系统盘样式。客户机（装机版/精简版 Windows）上 Get-Partition/Get-Disk 会抛异常，
  #   旧版直接吞成 '未知' → 被当成 MBR 盘挡死安装（现场：diskpart 里磁盘 0/1/2 全是 GPT）。
  #   现在顺序：1 Storage 模块 → 2 CIM(Storage 命名空间) → 3 老 WMI → 4 裸读 LBA0/LBA1 → 5 裸读扫描+卷GUID反查；
  #   每个后端的原始错误文本都进 $script:StorageDiag（-Mode StorageDiag 可全量打印）。
  try {
    $facts = Get-StorageFacts
    $r.DiskStyle = $facts.Style
    $r.DiskStyleSource = $facts.StyleSource
    $r.DiskStyleConfirmed = $facts.StyleConfirmed
    $r.DiskStyleError = $facts.StyleError
    $r.SysDiskNumber = $facts.SysDisk
  } catch {
    $r.DiskStyle = '未知'; $r.DiskStyleSource = ''; $r.DiskStyleConfirmed = $false
    $r.DiskStyleError = ('多后端判定本身出错: ' + $_.Exception.Message); $r.SysDiskNumber = -1
  }
  try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    $r.BitLocker = [string]$bl.ProtectionStatus
  } catch { $r.BitLocker = '未知(或无 BitLocker)' }
  $r.Gpus = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VEN_10DE' })
  $r.Target = @($r.Gpus | Where-Object { $_.InstanceId -match 'DEV_1F0B' })
  $r.Smi = Get-NvidiaSmi
  # 2026-09-30：GSP 判定必须把 "N/A" 当未启用（旧版当成已开启 → 从不写开关 → 客户机 Code 43）
  $gspNow = Get-GspState
  $r.GspState = $gspNow.State
  $r.GspValue = $gspNow.Value
  $r.GspLine = $gspNow.Line
  $r.Gsp = $gspNow.Value
  $r.GspKeys = @(Get-DisplayClassSubKeys)
  $r.Vbios = ''
  if ($r.Smi) {
    try { $vb = (Invoke-Native { & $r.Smi --query-gpu=vbios_version --format=csv,noheader 2>&1 } | Out-String).Trim(); if ($vb) { $r.Vbios = $vb } } catch { }
  }
  $r.Blocklist = ''
  # 易受攻击驱动阻止列表：开着时可能把 ThrottleStop / WinRing0 的服务改成"禁用"（客户机实测 Start=4 → sc start 1058）
  try { $r.Blocklist = [string](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Name 'VulnerableDriverBlocklistEnable' -ErrorAction SilentlyContinue).VulnerableDriverBlocklistEnable } catch { }
  $r.Hiberboot = ''
  try { $r.Hiberboot = [string](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue).HiberbootEnabled } catch { }
  # 2026-09-30：快速启动 = 1 时"关机"是混合关机（内核/驱动从 hiberfile 恢复）→ nvlddmkm 不重新初始化，
  # GSP 这类驱动级设置永远不生效 → 客户机会一直 43/黑屏。厂商安装器也关它（其"电源三项"之一）。
  if ($r.Hiberboot -eq '1') { $r.HiberbootOn = $true } else { $r.HiberbootOn = $false }
  $r.Huorong = (Test-Path 'C:\ProgramData\Huorong') -or (Test-Path 'C:\Program Files (x86)\Huorong')
  $r.AceBoot = Test-Path 'C:\Program Files\AntiCheatExpert\ACE-BOOT.sys'
  $r.AceTray = Test-Path 'C:\Program Files\AntiCheatExpert\ACE-Tray.exe'
  $r.Esp = $null
  if ($r.Admin) { $r.Esp = Mount-Esp }
  return $r
}

function Show-Check {
  param($Report, [switch]$FromInstall)   # Install/Repair 阶段：GSP 由本脚本自动补 → 只报提示，不把退出码变成 1
  Head '前提体检'
  Info ("管理员权限 : " + $Report.Admin)
  $fwOk = ($Report.Firmware -eq 'Uefi')
  if ($fwOk) { Ok ("固件类型   : " + $Report.Firmware + "（UEFI 必需）") } else { Bad ("固件类型   : " + $Report.Firmware + " —— 必须是 UEFI，MBR 盘要先 mbr2gpt") }
  if ($Report.DiskStyle -eq 'GPT') { Ok ("系统盘分区 : GPT" + $(if ($Report.DiskStyleSource) { "（判定来源: " + $Report.DiskStyleSource + "）" } else { "" })) }
  elseif ($Report.DiskStyle -eq 'MBR' -and $Report.DiskStyleConfirmed) { Bad "系统盘分区 : MBR —— 必须是 GPT（UEFI 引导 + ESP 是前提；MBR 盘先 mbr2gpt /convert /allowFullOS）" }
  else {
    # 2026-10-08：读不到分区样式 ≠ MBR 盘（客户机实测：diskpart 里三块盘全是 GPT，只是 Storage 接口坏了）
    Warn ("系统盘分区 : 读不到（" + $Report.DiskStyle + "）—— 这不等于 MBR 盘；逐后端诊断见下")
    Info ("判定来源: " + $(if ($Report.DiskStyleSource) { $Report.DiskStyleSource } else { '所有后端都失败' }))
    if ($Report.DiskStyleError) { Info ("说明    : " + $Report.DiskStyleError) }
    Show-StorageDiag
    Add-Action '系统盘分区样式读不到：跑 工具-测试与修复\存储体检.cmd（等价 -Mode StorageDiag）把输出和本次日志发给作者'
  }
  if ($Report.SecureBoot -eq $false) { Ok "Secure Boot: 已关闭（必需关闭，否则解锁 EFI 不加载）" }
  elseif ($Report.SecureBoot -eq $true) { Bad "Secure Boot: 开启 —— 请在 BIOS 里关闭" }
  else { Warn ("Secure Boot: " + $Report.SecureBoot + "（读不到，请自行确认已关闭）"); Add-Action '固件里读不到 Secure Boot 状态：请进 BIOS 自行确认已关闭' }
  if ($Report.BitLocker -match 'On|1') { Bad ("BitLocker  : " + $Report.BitLocker + " —— 改引导链会索要恢复密钥，请先暂停/解密") }
  else { Ok ("BitLocker  : " + $Report.BitLocker) }

  Head '硬件'
  if ($Report.Target.Count -gt 0) {
    foreach ($d in $Report.Target) { Ok ("CMP 40HX   : " + $d.InstanceId + "  Status=" + $d.Status) }
  } else {
    if ($Report.Gpus.Count -gt 0) { Bad ("未找到 CMP 40HX（DEV_1F0B），当前 NVIDIA 设备: " + (($Report.Gpus | ForEach-Object { $_.InstanceId }) -join '; ')) }
    else { Bad "未找到 NVIDIA 显卡（VEN_10DE）" }
  }
  if ($Report.Smi) {
    $csv = (Invoke-Native { & $Report.Smi --query-gpu=name,driver_version,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current --format=csv,noheader 2>&1 } | Out-String).Trim()
    Info ("nvidia-smi : " + $csv)
    # 2026-09-30：Install 阶段这里是「本脚本会自己补」的事项 → 记提示 + 待办；只有 -Mode Check（纯体检）才记失败
    $gspSev = 'Bad'; if ($FromInstall) { $gspSev = 'Warn' }
    if ($Report.GspState -eq 'on') { Ok ("GSP 固件   : " + $Report.GspValue + "（已启用，正常）") }
    elseif ($Report.GspState -eq 'off') {
      & $gspSev ("GSP 固件   : 未启用（" + $Report.GspLine + "）—— 解锁后 nvlddmkm 认不了卡 = 黑屏 + 设备管理器代码 43")
      Info 'Install 会写 EnableGpuFirmware=1（显示类子键，设备真正读的那一个）；写完必须完全关机再开机才生效'
      Add-Action 'GSP 未启用：确认日志里有「GSP 开关已写」，然后【完全关机】（不是重启）再开机，再用 -Mode Verify 复核 GSP 行显示版本号'
    }
    else {
      & $gspSev ("GSP 固件   : " + $Report.GspLine + " —— 状态未知，解锁后可能 Code 43")
      Add-Action 'GSP 状态未知：先把 NVIDIA 驱动装好（nvidia-smi 能用），再重跑 Install，然后完全关机再开机'
    }
  } else { & $gspSev "nvidia-smi : 找不到 —— 先把 NVIDIA 驱动装好再解锁（没驱动就解锁 = 黑屏 + Code 43）"; Add-Action '机器上没有 nvidia-smi：先装 NVIDIA 驱动，再重跑 Install' }
  if ($Report.Vbios) { Info ('显卡 VBIOS : ' + $Report.Vbios + '   （批次不同 → Gen2 基线不同；本包按位判定，不是写死常量）') }
  if ($Report.Blocklist -eq '1') {
    Warn '易受攻击驱动列表 : 开着（VulnerableDriverBlocklistEnable=1）—— 它/360/ACE 都可能把 ThrottleStop·WinRing0 的服务改成“禁用”，表现为老路径 sc start 失败 1058；本包每次开机都会自愈：WinRing0 启动类型纠正回 demand；ThrottleStop 则被停掉并禁用（它加载在内核里会被腾讯 ACE-BOOT 判为兼容性问题）'
    Add-Action '易受攻击驱动列表开着：想彻底关掉（厂商安装器也关它）就用 reg add "HKLM\SYSTEM\CurrentControlSet\Control\CI\Config" /v VulnerableDriverBlocklistEnable /t REG_DWORD /d 0 /f 然后重启；不关也行，本包每次开机都会纠正服务启动类型'
  } else { Ok ('易受攻击驱动列表 : ' + $(if ($Report.Blocklist -eq '') { '未设置（按关处理）' } else { '已关（0）' })) }
  if ($Report.HiberbootOn) {
    Warn '快速启动   : 开着（HiberbootEnabled=1）—— "关机"其实是混合关机：内核和显卡驱动从 hiberfile 恢复、不重新初始化，GSP 这类改动永远不生效（Install 会自动关掉它）'
    Add-Action '快速启动开着：Install 已把它关掉；重启/关机后请确认 HiberbootEnabled=0（关掉后"关机"才是真关机）'
  } else { Ok ('快速启动   : 已关闭（HiberbootEnabled=' + $(if ($Report.Hiberboot -eq '') { '未设置，按关处理' } else { $Report.Hiberboot }) + '）') }
  Info "BIOS 里必须确认: Above 4G Decoding = Enabled、CSM = Disabled、Fast Boot = Disabled（这三项 OS 侧读不到，是头号失败原因）"

  Head '杀软 / 反作弊'
  if ($Report.Huorong) {
    Warn '检测到火绒 —— 必须在“信任区”加入下面这几项，否则驱动会被隔离、服务被删（自愈源可救，但会反复）'
    Add-Action '火绒/其它杀软：把 README 第 1.1 节那几项加进信任区（System32\drivers 下 ThrottleStop.sys / WinRing0x64.sys / inpoutx64.sys 全路径 + C:\ProgramData\CMP40HXGen2 + 本包目录），并关掉它的“启动项保护”'
    Info ('文件: ' + $script:SysDrv + '\ThrottleStop.sys')
    Info ('文件: ' + $script:SysDrv + '\WinRing0x64.sys')
    Info ('文件: ' + $script:SysDrv + '\inpoutx64.sys')
    Info ('目录: ' + $script:ProgDataRoot)
    Info ('目录: ' + $script:PkgRoot)
    Info '安装时火绒大概率会弹一次 “Exploit/Vulndriver.ad” 拦截（这几个都是 BYOVD 类驱动，属预期）——按提示“信任/恢复”即可，脚本有 ESP 兜底源自愈'
  } else { Ok '未检测到火绒' }
  # 2026-10-01: 七彩虹 iGame Center 会占用 WinRing0_1_2_0 这个公用服务名（客户机实测）
  try {
    $wrName = $null
    foreach($k in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)){
      $ip = (Get-ItemProperty -LiteralPath $k.PSPath -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
      if($ip -and $ip -match 'iGameCenter|iGame\\'){ $wrName = $k.PSChildName; break }
    }
    if ($wrName) {
      Info ('检测到七彩虹 iGame Center（服务 ' + $wrName + '）—— 它会占用 WinRing0 驱动；本包已自动避让：优先用 ECAM(不需 WinRing0)，必要时改用独立服务名 WinRing0_40HX')
      Add-Action '如遇 Gen2 写不进去：先退出 iGame Center（托盘右键退出）再跑；本包不会改动它的任何配置'
    }
  } catch {}

  if ($Report.AceBoot) { Warn '检测到腾讯 ACE-BOOT 反作弊（会在映像加载阶段拦 ThrottleStop.sys）—— 首选新路径用 inpoutx64 直写寄存器，ACE-BOOT 全程不用停；只有新路径失败才回落到“停ACE→重训→恢复ACE”，无需手工关闭' }
  else { Ok '未检测到 ACE-BOOT' }

  Head '现状'
  if ($Report.Esp) {
    Info ("ESP 挂载于 " + $Report.Esp)
    $efi1 = Join-Path $Report.Esp 'EFI\40HX\40HXUNLK.EFI'
    $efi2 = Join-Path $Report.Esp 'EFI\Boot\bootx64.efi'
    foreach ($p in @($efi1, $efi2)) {
      if (Test-Path $p) {
        $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
        if ($h -eq $script:EfiSha256) { Ok ($p + " = OnlyEFI 解锁固件 (sha256 " + $h.Substring(0, 16) + "…)") }
        else { Warn ($p + " 不是 OnlyEFI 解锁固件 (sha256 " + $h.Substring(0, 16) + "…)") }
      } else { Info ($p + " 不存在") }
    }
    $log = Join-Path $Report.Esp '40hx_log.txt'
    if (Test-Path $log) {
      $txt = Get-Content -LiteralPath $log -ErrorAction SilentlyContinue
      # 2026-10-02（第三方审查）：40hx_log.txt 是**跨开机累积**的 —— 只查“有没有 UNLOCKED 行”会把历史成功当成本次成功。
      #   必须带“本次开机”的时间门槛（EFI 先写、Windows 后起，容差 10 分钟）。
      $btC = $null
      try { $btC = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime } catch { }
      $freshC = $false
      if ($btC -and ((Get-Item $log).LastWriteTime -ge $btC.AddMinutes(-10))) { $freshC = $true }
      if (($txt -match 'UNLOCKED \(SS0=0x88888888 SS1=0x8\)') -and $freshC) { Ok ("40hx_log.txt: 本次开机解锁成功 *** UNLOCKED (SS0=0x88888888 SS1=0x8) ***  (" + (Get-Item $log).LastWriteTime + ")") }
      elseif (($txt -match 'UNLOCKED \(SS0=0x88888888 SS1=0x8\)') -and (-not $btC)) { Warn '读不到本次开机时间，无法确认 40hx_log.txt 里的 UNLOCKED 是不是本次开机 → 建议管理员身份重跑 -Mode Check' }
      elseif ($txt -match 'UNLOCKED \(SS0=0x88888888 SS1=0x8\)') { Warn ('40hx_log.txt 里的 UNLOCKED 是**之前开机**的记录（文件时间 ' + (Get-Item $log).LastWriteTime + '）→ 本次开机解锁固件很可能没跑，别按“已解锁”处理') }
      else { Warn "40hx_log.txt 里没有 UNLOCKED 行（EFI 这次开机可能没跑）" }
      $tls = $txt | Select-String -Pattern 'TLS|NO-RETRAIN' | Select-Object -Last 3
      foreach ($l in $tls) { Info ("  " + $l.Line) }
    } else { Info "40hx_log.txt 不存在（解锁固件这次开机没运行）" }
    Dismount-Esp
  } elseif ($Report.Admin) { Warn '找不到 ESP 分区（Windows 恢复/RE 环境下才会这样）' }
  else { Info '非管理员：跳过 ESP 与固件启动项检查（用 Install-40HXUnlock.ps1 -Mode Check 提权跑才完整）' }

  if ($Report.Admin) {
    Initialize-FwAccess | Out-Null
    $entries = Get-AllBootEntries
    $order = Get-BootOrderIndices
    Info ("BootOrder = " + (Format-BootOrderIndices $order))
    $unlock = Get-UnlockBootEntry $entries
    if ($unlock) { Ok ("固件启动项 " + $unlock.Name + " = '" + $unlock.Entry.Description + "' → " + $unlock.FilePath) }
    # 2026-10-02（第三方审查）：读不到 NVRAM 时列表为空 —— 不能说成“还没有”（同“读不到≠没有”家族）
    elseif (@($entries).Count -eq 0 -or @($order).Count -eq 0) { Warn '固件变量（NVRAM）读不到 → 不能判断 "40HX Unlock" 启动项在不在；别据此重装，重启/提权后再跑一次 -Mode Check' }
    else { Info '固件启动项：还没有 "40HX Unlock"（Install 会创建）' }
    foreach ($e in $entries) {
      $gt = ''
      if ($e.Entry.DeviceNode) { $gt = '  [node guid ' + (Get-NodeGuidText $e.Entry.DeviceNode) + ']' }
      Info ("  " + $e.Name + " '" + $e.Entry.Description + "' → " + $e.FilePath + $gt)
    }
    $espPart = Get-EspPartitionInfo
    Show-EspPathCheck -Entries $entries -EspPart $espPart | Out-Null
  }

  Head 'Windows 侧现状'
  foreach ($d in $script:Drivers) {
    $p = Join-Path $script:SysDrv $d.Name
    if (Test-Path $p) {
      $h = Get-FileSha256 $p
      if ($h -eq $d.Sha256) { Ok ($d.Name + " 已就位 (" + (Get-Item $p).Length + " B)") } else { Warn ($d.Name + " 存在但哈希不同 (" + $h.Substring(0, 16) + "…)") }
    } else { Info ($d.Name + " 不在 System32\drivers") }
    $q = (Invoke-Native { sc.exe query $d.Service 2>&1 } | Out-String)
    if ($q -match 'STATE\s+:\s+\d+\s+(\S+)') { Info ("服务 " + $d.Service + " = " + $Matches[1]) } else { Info ("服务 " + $d.Service + " 不存在") }
  }
  # 新路径（首选）需要的文件：inpoutx64.sys / inpoutx64.dll + 重训工具
  foreach ($f in $script:InpoutFiles) {
    $p = Join-Path $script:SysDrv $f.Name
    if (-not (Test-Path $p)) { $p = Join-Path $script:ProgDataDrv $f.Name }
    if (Test-Path $p) {
      $hf = Get-FileSha256 $p
      if ($hf -eq $f.Sha256) { Ok ($f.Name + " 已就位 (" + (Get-Item $p).Length + " B, " + (Split-Path -Parent $p) + ")") }
      else { Warn ($f.Name + " 存在但哈希不同 (" + $hf.Substring(0, 16) + "…) —— 跑一次 -Mode Repair") }
    } else { Info ($f.Name + " 没铺（新路径需要它，Install/Repair 会铺）") }
  }
  $newTool = Join-Path $script:ProgDataWin '40hx-retrain-inpout.ps1'
  if (Test-Path $newTool) { Ok '新路径工具 40hx-retrain-inpout.ps1 已就位（开机不停 ACE-BOOT）' }
  else { Info '新路径工具还没铺（没它时开机走旧路径 = 每次开机停一次 ACE-BOOT）' }
  $lastLog = Join-Path $script:ProgDataWin 'logs\last.log'
  if (Test-Path $lastLog) {
    $c = Get-Content -LiteralPath $lastLog
    $guard = ($c | Select-String 'GUARD=' | Select-Object -Last 1)
    $pass = ($c | Select-String 'PASS:' | Select-Object -Last 1)
    $exit = ($c | Select-String 'EXIT=' | Select-Object -Last 1)
    if ($guard) { Info ("helper: " + $guard.Line.Trim()) }
    # 2026-10-02（第三方审查）：last.log 是旧路径的日志，新路径生效后就不再更新 —— 里面的 PASS 可能是很久以前的，
    #   必须带上"是不是本次开机写的"，否则会显示成 [OK] 让人以为一切正常（本机实测停在 2026-09-29）。
    $lastFresh = $false
    try {
      $btL = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
      if ($btL -and ((Get-Item $lastLog).LastWriteTime -ge $btL.AddMinutes(-10))) { $lastFresh = $true }
    } catch { }
    if ($pass -and $lastFresh) { Ok ("helper: " + $pass.Line.Trim()) }
    elseif ($pass -and -not $btL) { Warn ("helper: " + $pass.Line.Trim() + "   ← 读不到本次开机时间，无法确认这条 PASS 是不是本次开机的") }
    elseif ($pass) { Warn ("helper: " + $pass.Line.Trim() + "   ← 但这是**之前开机**留下的记录（last.log 时间 " + (Get-Item $lastLog).LastWriteTime + "），不代表本次") }
    elseif ($exit) { Warn ("helper: " + $exit.Line.Trim()) }
    Info ("last.log 时间: " + (Get-Item $lastLog).LastWriteTime + $(if ($lastFresh) { '（本次开机）' } else { '（不是本次开机 —— 旧路径已不再使用属正常）' }))
  } else { Info 'last.log 不存在（旧路径没跑过；新路径只写 postbind.log + retrain-last.log，属正常）' }
  $pbLog = Join-Path $script:ProgDataWin 'logs\postbind.log'
  if (Test-Path $pbLog) {
    (Get-Content -LiteralPath $pbLog | Select-Object -Last 4) | ForEach-Object { Info ('postbind: ' + $_) }
  } else { Info 'postbind.log 不存在（开机任务还没跑过）' }
  $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($t) {
    $ti = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($ti.LastTaskResult -eq 267011) { Ok ("开机任务 " + $script:TaskName + " 已注册（还没跑过 —— 刚注册或被重装过，重启/运行一次就有了）") }
    else { Ok ("开机任务 " + $script:TaskName + " 已注册, 上次 " + $ti.LastRunTime + " rc=0x" + ('{0:X}' -f $ti.LastTaskResult)) }
  } else {
    # 2026-10-02：非管理员身份查不到 SYSTEM 任务（实测 unelevated schtasks 直接「拒绝访问」）——
    #   不能把"读不到"说成"没注册"（会误导用户去重装）。
    if (Test-Admin) { Info ("开机任务 " + $script:TaskName + " 未注册") }
    else { Warn ("开机任务 " + $script:TaskName + " 读不到 —— 当前不是管理员，非管理员查不了 SYSTEM 任务；要确认就跑管理员：-Mode Verify（或 -Mode Repair）") }
  }
  $t2 = Get-ScheduledTask -TaskName $script:TaskNameLogon -ErrorAction SilentlyContinue
  if ($t2) {
    $ti2 = Get-ScheduledTaskInfo -TaskName $script:TaskNameLogon -ErrorAction SilentlyContinue
    Ok ("登录后补跑任务 " + $script:TaskNameLogon + " 已注册（开机那轮没修好时，登录 60 秒后自动再修一次）")
  } else {
    if (Test-Admin) { Warn ("登录后补跑任务 " + $script:TaskNameLogon + " 未注册 —— 开机那轮失败时没人补跑（跑 -Mode Repair 补上）") }
    else { Warn ("登录后补跑任务 " + $script:TaskNameLogon + " 读不到 —— 当前不是管理员（非管理员查不了 SYSTEM 任务）；要确认就跑管理员：-Mode Verify") }
  }
  # 安全加固现状（2026-10-01b）
  foreach ($h in $script:HardeningDirs) {
    if (-not (Test-Path -LiteralPath $h.Path)) { continue }
    $wr = @(Get-UsersWriteRights $h.Path)
    if ($wr.Count -eq 0) { Ok ("目录权限: " + $h.Path + " = 只有 SYSTEM/Administrators 可写") }
    else { Warn ("目录权限: " + $h.Path + " 普通用户可写（" + ($wr -join ', ') + "）= 本地提权面 —— 跑一次 -Mode Repair 收紧（只改 ACL，有备份可回滚）"); Add-Action ('目录权限没收紧: ' + $h.Path + ' → 跑 -Mode Repair（改 ACL，备份在 logs\acl-backup-*，可双击 工具-测试与修复\回滚-安全加固.cmd 退回）') }
  }
  foreach ($d in @($script:ProgDataDrv, (Join-Path $env:ProgramData '40HXUnlock\drivers'))) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    # inpoutx64.dll 是工具运行时必须落地的（Add-Type 要按路径加载它），不算"多余的面"，排除掉
    $raws = @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.sys', '.dll') -and $_.Name -notin @('inpoutx64.dll', 'ThrottleStop.sys') })
    $b64s = @(Get-ChildItem -LiteralPath $d -File -Filter '*.b64' -ErrorAction SilentlyContinue)
    if ($raws.Count -eq 0 -and $b64s.Count -gt 0) { Ok ("驱动源形态: " + $d + " = 只有 base64 文本（磁盘上没有可直接被加载的驱动副本）") }
    elseif ($raws.Count -gt 0) {
      Warn ("驱动源形态: " + $d + " 还有 " + $raws.Count + " 个裸驱动文件（" + (($raws | ForEach-Object { $_.Name }) -join ', ') + "）—— 跑一次 -Mode Repair 转成 base64")
      if (@($raws | Where-Object { $_.Name -eq 'HwRwDrv.sys' }).Count -gt 0) { Warn '源目录里有厂商遗留的 HwRwDrv.sys（WinIO 类 BYOVD；只有厂商工具用得到）—— 本包不用它，也不删它，只如实提示：它是磁盘上一个可被加载的签名驱动' }
    }
  }
}

# ================================================================ 安装各部件
# ================================================================
# 安全加固（2026-10-01b，按用户要求：不删任何必要文件、不退役任何路径，只做"降低被滥用面"）
#   ① 源目录权限：去掉 BUILTIN\Users 的写权限
#      实测（非提权 PowerShell）：C:\ProgramData\CMP40HXGen2\{,drivers} 与 C:\ProgramData\40HXUnlock\drivers
#      原来对普通用户可写 —— 任何本地普通用户都能替换里面的 .sys，下次开机 RunPostBind 以 SYSTEM 身份
#      把它拷进 System32\drivers 并加载 = 本地提权。收紧到 SYSTEM/Administrators 独占即可堵住，零功能影响
#      （本包的工具都以管理员/SYSTEM 运行，厂商安装器也提权运行）。
#      备份：<包目录>\logs\acl-backup-<时间>\*.acl.txt  →  双击 工具-测试与修复\回滚-安全加固.cmd 可退回
#   ② 源文件形态：ProgramData 两处只留 *.b64 文本（先写 b64 + 逐字节校验，通过后才删裸文件）
#      好处：a) 杀软不会把 base64 文本当 BYOVD 驱动秒删 → 自愈源更可靠
#            b) 磁盘上不留"能被 SCM 直接加载"的签名驱动副本（运行时由 Unpack-Drivers.ps1 解码落地）
#      安全：任何一步失败都保留裸文件，只记为提示，不影响功能
# ================================================================
$script:HardeningDirs = @(
  @{ Path = $script:ProgDataRoot                            ; Label = '本包目录' },
  @{ Path = $script:ProgDataDrv                             ; Label = '本包驱动源' },
  @{ Path = (Join-Path $env:ProgramData '40HXUnlock')       ; Label = '厂商目录' },
  @{ Path = (Join-Path $env:ProgramData '40HXUnlock\drivers'); Label = '厂商驱动源' }
)
function Get-UsersWriteRights([string]$Path) {
  # 返回"普通用户身份被授予写类权限"的条目（空数组 = 已收紧）
  $hits = @()
  try {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    foreach ($r in $acl.Access) {
      if ($r.AccessControlType -ne 'Allow') { continue }
      $id = $r.IdentityReference.Value
      if ($id -match 'SYSTEM|Administrators|TrustedInstaller|OWNER RIGHTS') { continue }
      if ($id -notmatch 'Users|Everyone|INTERACTIVE|Authenticated') { continue }
      $fr = [string]$r.FileSystemRights
      if ($fr -match 'Write|Modify|FullControl|CreateFiles|AppendData|TakeOwnership|ChangePermissions') { $hits += ($id + ':' + $fr) }
    }
  } catch { }
  return $hits
}
function Backup-DirAcl([string]$Path) {
  $file = ''
  try {
    $bakDir = Join-Path (Join-Path $script:ProgDataRoot 'logs') ('acl-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (-not (Test-Path -LiteralPath $bakDir)) { New-Item -ItemType Directory -Force -Path $bakDir | Out-Null }
    $file = Join-Path $bakDir (($Path -replace '[\\:]', '_') + '.acl.txt')
    Invoke-Native { icacls "$Path" /save "$file" /T /C 2>&1 | Out-Null }
    if (-not (Test-Path -LiteralPath $file)) { $file = '' }
  } catch { $file = '' }
  return $file
}
function Set-DirAclHardened([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return 'skip' }
  if (@(Get-UsersWriteRights $Path).Count -eq 0) { return 'ok' }
  $bak = Backup-DirAcl $Path
  # 只改"目录自身"的 ACL，**绝不加 /T**。
  #   2026-10-01b 本机实测踩到：icacls /T + /inheritance:r 会把"只有继承 ACE"的子文件清成无 DACL
  #   → 连管理员都读不了（文件所有者不是 Administrators，只能 takeown 才救回来；本次就是这么坏的）。
  #   子对象会自动继承父目录的新 ACE，所以改父目录就够。
  #   顺序：① 先 grant 显式权限 ② 再断继承 + 删 Users 系多余授权 ③ 最后再 grant 一次兜底。
  try {
    [void](Invoke-Native { icacls "$Path" /grant "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" /C 2>&1 | Out-Null })
    [void](Invoke-Native { icacls "$Path" /inheritance:r /remove:g "*S-1-5-32-545" "*S-1-5-11" "*S-1-1-0" "*S-1-5-4" /C 2>&1 | Out-Null })
    [void](Invoke-Native { icacls "$Path" /grant "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" /C 2>&1 | Out-Null })
  } catch { return ('fail:' + $_.Exception.Message) }
  # 兜底自愈：递归找出"读不了"的子对象（历史操作遗留的坏 ACL），逐对象 takeown + grant 修回来。
  #   注意这里是**逐个文件**调用 icacls（不带 /T），因为 /T 正是会清空 DACL 的那个坑。
  $repaired = 0
  try {
    foreach ($it in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)) {
      if ($it.PSIsContainer) { continue }
      $bad = $false
      try { $null = [IO.File]::ReadAllBytes($it.FullName) } catch { $bad = $true }
      if (-not $bad) { continue }
      [void](Invoke-Native { takeown /f $it.FullName /a 2>&1 | Out-Null })
      [void](Invoke-Native { icacls $it.FullName /grant "*S-1-5-18:F" "*S-1-5-32-544:F" "*S-1-5-32-545:RX" /C 2>&1 | Out-Null })
      try { $null = [IO.File]::ReadAllBytes($it.FullName); $repaired++ } catch { }
    }
  } catch { }
  if ($repaired -gt 0) { Ok ('  顺带修回了 ' + $repaired + ' 个丢权限的文件（历史 ACL 操作遗留）') }
  if (@(Get-UsersWriteRights $Path).Count -gt 0) { return 'fail:still-writable' }
  if ($bak) { return ('changed:' + $bak) }
  return 'changed'
}
function Set-DriverSourceB64([string]$Dir, [string]$Name) {
  # <Dir>\<Name> → <Dir>\<Name>.b64（逐字节校验通过后才删裸文件）
  if (-not (Test-Path -LiteralPath $Dir)) { return 'nodir' }
  $raw = Join-Path $Dir $Name
  $b64 = Join-Path $Dir ($Name + '.b64')
  if (-not (Test-Path -LiteralPath $raw)) {
    if (Test-Path -LiteralPath $b64) { return 'already-b64' }
    return 'missing'
  }
  try {
    $bytes = [IO.File]::ReadAllBytes($raw)
    $txt = [Convert]::ToBase64String($bytes)
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $txt.Length; $i += 76) { [void]$sb.AppendLine($txt.Substring($i, [Math]::Min(76, $txt.Length - $i))) }
    [IO.File]::WriteAllText($b64, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    $back = [Convert]::FromBase64String(((Get-Content -LiteralPath $b64 -Raw) -replace '[\r\n\s]', ''))
    if ($back.Length -ne $bytes.Length) { return 'fail:length' }
    for ($i = 0; $i -lt $bytes.Length; $i++) { if ($back[$i] -ne $bytes[$i]) { return 'fail:bytes' } }
    Remove-Item -LiteralPath $raw -Force -ErrorAction Stop
    return 'converted'
  } catch { return ('fail:' + $_.Exception.Message) }
}
function Install-Hardening {
  Head '安全加固（驱动源改 base64 + 目录权限；都不删必要文件）'
  # 顺序：先"读源文件 → 写 .b64 → 校验 → 删裸文件"，再收紧目录权限（见下面第 1 步的说明）。
  # 2026-10-01b（第三方审查）：ThrottleStop.sys **不**转 base64 —— 旧回退路径（legacy）靠它执行，
  #   而自愈逻辑只认裸文件；转成 .b64 之后它就再也补不回来了。
  # 2026-10-01b（第三方审查）：这段原来写了两遍（$names0/$names 同值，每个文件转两次），
  #   合并成一遍（幂等：第二次本来就只会报 already-b64，纯属冗余日志）。
  $names = @('WinRing0x64.sys', 'inpoutx64.sys', 'inpoutx64.dll')
  foreach ($d0 in @($script:ProgDataDrv, (Join-Path $env:ProgramData '40HXUnlock\drivers'))) {
    if (-not (Test-Path -LiteralPath $d0)) { continue }
    foreach ($n0 in $names) {
      $r0 = Set-DriverSourceB64 $d0 $n0
      if ($r0 -eq 'converted') { Ok ('源已转 base64（裸文件已删，字节已校验）: ' + (Join-Path $d0 $n0)) }
      elseif ($r0 -eq 'already-b64') { Info ('源本来就是 base64: ' + (Join-Path $d0 ($n0 + '.b64'))) }
      elseif ($r0 -eq 'missing') { Info ('源里没有 ' + $n0 + '（不需要补就在这里放同名 .b64）') }
      elseif ($r0 -eq 'nodir') { }
      elseif ($r0 -like 'fail:*') { Warn ('源转 base64 失败（裸文件保留）: ' + (Join-Path $d0 $n0) + ' → ' + $r0) }
    }
  }
  # ---- 1) 目录权限（放在 base64 转换之后：转换要读文件，而收紧后可能读不到）----
  foreach ($t in $script:HardeningDirs) {
    if (-not (Test-Path -LiteralPath $t.Path)) { Info ('跳过（不存在）: ' + $t.Path); continue }
    $r = Set-DirAclHardened $t.Path
    if ($r -eq 'ok') { Ok ('目录权限已是最严（普通用户不可写）: ' + $t.Path) }
    elseif ($r -eq 'changed') { Ok ('已收紧目录权限: ' + $t.Path + ' → 只剩 SYSTEM/Administrators 可写') }
    elseif ($r -like 'changed:*') { Ok ('已收紧目录权限: ' + $t.Path + '（ACL 备份: ' + $r.Substring(8) + '）') }
    else { Warn ('收紧目录权限失败: ' + $t.Path + ' → ' + $r + '（不影响解锁/Gen2，只是少了一层保护）'); Add-Action ('目录权限没收紧: ' + $t.Path + ' —— 可手工跑 icacls "' + $t.Path + '" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "Users:(OI)(CI)RX"') }
  }
  # 若之前误把 ThrottleStop.sys 转成了 .b64（老版本行为），这里解回裸文件
  foreach ($d2 in @($script:ProgDataDrv, (Join-Path $env:ProgramData '40HXUnlock\drivers'))) {
    if (-not (Test-Path -LiteralPath $d2)) { continue }
    $b64f = Join-Path $d2 'ThrottleStop.sys.b64'
    $rawf = Join-Path $d2 'ThrottleStop.sys'
    if ((Test-Path -LiteralPath $b64f) -and -not (Test-Path -LiteralPath $rawf)) {
      try {
        [IO.File]::WriteAllBytes($rawf, [Convert]::FromBase64String(((Get-Content -LiteralPath $b64f -Raw) -replace '[\r\n\s]', '')))
        Ok ('已把 ThrottleStop.sys 解回裸文件（legacy 回退要用）: ' + $rawf)
      } catch { Warn ('解回 ThrottleStop.sys 失败: ' + $_.Exception.Message) }
    }
  }
  Ok '加固完成：平时 ProgramData 里没有"可直接被加载"的驱动副本；需要时由 Unpack-Drivers.ps1 解码落地'
  Info '要退回这次加固：双击 工具-测试与修复\回滚-安全加固.cmd（恢复目录权限 + 写回裸驱动文件）'
}

function Install-DriverFiles {
  param([string]$BackupDir)
  Head '驱动 + 服务'
  $rawDir = Join-Path $script:PayloadDir 'drivers'
  foreach ($d in $script:Drivers) {
    $b64 = Join-Path $rawDir ($d.Name + '.b64')
    if (-not (Test-Path $b64)) { Fail ("载荷缺失: " + $b64) $script:ExitHash '包不完整（漏拷/杀软删过载荷）→ 重新解压一份完整包再跑，别只拷 Install-40HXUnlock.ps1' }
    # base64 文本 → 二进制（避开杀软对“裸 .sys 放在任意目录”的秒删）
    $bytes = [IO.File]::ReadAllBytes($b64)
    $text = [Text.Encoding]::ASCII.GetString($bytes) -replace "[\r\n\s]", ''
    $bin = [Convert]::FromBase64String($text)
    $sha = [Security.Cryptography.SHA256]::Create()
    $binHash = ([BitConverter]::ToString($sha.ComputeHash($bin)) -replace '-', '').ToLower()
    if ($binHash -ne $d.Sha256) { Fail ($d.Name + " 载荷解码后哈希不符: " + $binHash) $script:ExitHash ('期望 ' + $d.Sha256 + ' —— 传输损坏或杀软改过文件，重新解压一份包') }
    Ok ($d.Name + " 载荷解码 + 哈希校验通过 (" + $bin.Length + " B)")
    $targets = @(
      (Join-Path $script:SysDrv $d.Name),
      (Join-Path $script:ProgDataDrv $d.Name),
      (Join-Path $script:VendorDrvDir $d.Name)
    )
    foreach ($t in $targets) {
      $parent = Split-Path -Parent $t
      if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
      [void](Save-PayloadFile -Path $t -Bytes $bin -Sha256 $d.Sha256 -Name $d.Name -Service $d.Service)
    }
    # 服务：厂商脚本只 start 不 create，这里必须建（缺了会 1060）
    $q = (Invoke-Native { sc.exe query $d.Service 2>&1 } | Out-String)
    if ($q -notmatch $d.Service) {
      Invoke-Native { sc.exe create $d.Service type= kernel start= demand binPath= ("\SystemRoot\System32\drivers\" + $d.Name) 2>&1 | Out-Null }
      Info ("创建服务 " + $d.Service)
    } else { Ok ("服务 " + $d.Service + " 已存在") }
  }
  # 火绒在不在 10 秒内动手，装完等一会儿确认
  Start-Sleep -Seconds 10
  $survived = $true
  foreach ($d in $script:Drivers) {
    foreach ($t in @((Join-Path $script:ProgDataDrv $d.Name), (Join-Path $script:SysDrv $d.Name))) {
      if (-not (Test-Path $t)) { $survived = $false; Warn ("驱动被删: " + $t + " —— 杀软隔离，请把它加入信任区后重跑 Install"); Add-Action '杀软隔离了驱动：加完信任区后跑一次 -Mode Repair' }
    }
  }
  if ($survived) { Ok '10 秒后驱动仍在（没被杀软清理）' }
  # ESP 兜底源自愈（杀软不扫 EFI 分区）
  $espRoot = Mount-Esp
  if ($espRoot) {
    $drvEsp = Join-Path $espRoot $script:EspDrvFallback
    if (-not (Test-Path $drvEsp)) { New-Item -ItemType Directory -Force -Path $drvEsp | Out-Null }
    foreach ($d in $script:Drivers) {
      Copy-Item -LiteralPath (Join-Path $script:SysDrv $d.Name) -Destination (Join-Path $drvEsp $d.Name) -Force
    }
    Ok ("ESP 兜底驱动源已就位: " + $drvEsp)
  } else { Warn 'ESP 挂载失败，未部署 ESP 兜底驱动源'; Add-Action 'ESP 兜底驱动源没部署成功：重启后若 Gen2 没落地，跑 -Mode Repair（或看 排查指引.md 第 4 节）' }
}

function Install-WindowsFiles {
  Head 'Windows 侧 helper'
  $src = Join-Path $script:PayloadDir 'windows'
  # 2026-10-05（审查 r4 M2 / r6 M1/M2b）：期望 md5 从 payload\sha256.txt 读（该清单内容就是 md5）。
  #   清单缺失/读不了 → 不再"静默跳过校验"，而是明确告警并跳过 helper 拷贝（完整性校验不能被旁路）。
  $wantMd5 = @{}
  $sumFile = Join-Path $script:PayloadDir 'sha256.txt'
  if (-not (Test-Path -LiteralPath $sumFile)) {
    Warn '包里没有 payload\sha256.txt —— 无法校验 helper 完整性，本次不拷贝 helper（重新解压一份完整包再装）'
    Add-Action 'payload\sha256.txt 缺失：重新解压完整包后跑一次 一键安装.cmd'
  } else {
    try {
      foreach ($ln in @(Get-Content -LiteralPath $sumFile -ErrorAction Stop)) {
        if ($ln -match '^([0-9a-fA-F]{32})\s+\d+\s+(.+)$') { $wantMd5[$matches[2].Trim()] = $matches[1].ToLower() }
      }
      Info ('载荷清单: ' + $wantMd5.Count + ' 条')
      if ($wantMd5.Count -eq 0) {
        # 2026-10-05（审查 r6 M1）：清单里一条都解析不出来 = 格式被改/被杀软动过 → 明确告警，别静默降级
        Warn 'payload\sha256.txt 一条都没解析出来（格式不对或被杀软改过）—— 本次不拷贝 helper；重新解压一份完整包'
        Add-Action 'payload\sha256.txt 解析为 0 条：重新解压完整包后跑 一键安装.cmd'
      }
    } catch {
      Warn ('读不了 payload\sha256.txt: ' + $_.Exception.Message + ' —— 本次不拷贝 helper（无法校验完整性）')
      Add-Action 'payload\sha256.txt 读不了（杀软/权限）：重新解压后跑 一键安装.cmd'
      $wantMd5 = @{}
    }
  }
  $helperList = @('CMP40HXGen2.exe', 'AutoRetrain.cmd', 'Status.cmd', 'Uninstall_Auto.cmd', 'ACE-Toggle.ps1', '40hx-retrain-inpout.ps1', 'Unpack-Drivers.ps1')
  foreach ($f in $helperList) {
    $s = Join-Path $src $f
    if (-not (Test-Path $s)) { Fail ("载荷缺失: " + $s) $script:ExitHash '包不完整 → 重新解压一份完整包（payload 目录必须跟脚本在一起）' }
  }
  # 2026-10-05（审查 r4 Q2-1）：先直接拷 —— 没被占用就别去动 helper 进程；只有真失败才清占用者并重试
  $failed = @()        # 被占用/写失败 -> 值得停占用者后重试
  $tamperedSrc = @()   # 包内源文件与清单不符 -> 重新解压包
  $tamperedDst = @()   # 源没问题、写进目标后内容又变了 -> 重跑 Repair / 发日志（审查 r8 R2）
  foreach ($f in $helperList) {
    $key = 'windows/' + $f
    if (-not $wantMd5.ContainsKey($key)) {
      Warn ($f + ' 在 payload\sha256.txt 里没有条目 —— 跳过（不写未校验的 helper）；重新解压一份完整包再装')
      Add-Action ($f + ' 缺清单条目：重新解压完整包后跑 一键安装.cmd')
      Bad ($f + ' 缺清单条目，未安装')
      continue
    }
    $cp = Copy-WithVerifyLoose (Join-Path $src $f) (Join-Path $script:ProgDataWin $f) $wantMd5[$key]
    if ($cp.Ok) { Ok ($f + " → " + $script:ProgDataWin) }
    elseif ($cp.Kind -eq 'tampered') { if ($cp.Where -eq 'src') { $tamperedSrc += $f } else { $tamperedDst += $f } }
    elseif ($cp.Kind -eq 'iofail') { Bad ($f + ' IO 异常，本次跳过（见上面原因）'); Add-Action ($f + ' IO 异常：处理权限/杀软后跑 -Mode Repair') }
    else { $failed += $f }
  }
  if ($tamperedSrc.Count -gt 0) {
    Bad ('这些 helper 包内内容与清单不符，已跳过: ' + ($tamperedSrc -join ', ') + ' —— 重新解压一份完整包再装')
    Add-Action ('helper 载荷校验不符（' + ($tamperedSrc -join ', ') + '）：重新解压一份包再跑 一键安装.cmd')
  }
  if ($tamperedDst.Count -gt 0) {
    Bad ('这些 helper 源文件没问题、写进目标后内容又变了: ' + ($tamperedDst -join ', ') + ' —— 重跑 -Mode Repair；仍如此请把日志发回')
    Add-Action ('helper 写后内容变化（' + ($tamperedDst -join ', ') + '）：重跑 -Mode Repair；仍如此把日志发回')
  }
  if ($failed.Count -gt 0) {
    Info ('有 ' + $failed.Count + ' 个 helper 文件没写进去 → 停掉引用它们的任务/进程后重试: ' + ($failed -join ', '))
    Stop-HelperHolders
    foreach ($f in $failed) {
      $cp = Copy-WithVerifyLoose (Join-Path $src $f) (Join-Path $script:ProgDataWin $f) $wantMd5[('windows/' + $f)]
      if ($cp.Ok) { Ok ($f + " → " + $script:ProgDataWin + ' (清占用后成功)') }
      elseif ($cp.Kind -eq 'tampered') { Bad ($f + ' 内容与清单不符（包完好的话，可能是写下去后被改/写坏）—— 重跑 -Mode Repair 仍如此就把日志发回'); Add-Action ($f + ' 内容与清单不符：先重解压一份包；仍如此请把日志发回') }
      elseif ($cp.Kind -eq 'locked') { Warn ($f + ' 仍被占用 —— 已放 ' + $f + '.new，完全关机再开机后由开机任务替换（或先手工结束 CMP40HXGen2.exe 再跑 -Mode Repair）'); Add-Action ($f + ' 仍被占用：完全关机再开机 或 手工结束 CMP40HXGen2.exe 后跑 -Mode Repair') }
      elseif ($cp.Kind -eq 'iofail') { Bad ($f + ' IO 异常 —— 处理权限/杀软后跑 -Mode Repair'); Add-Action ($f + ' IO 异常：处理权限/杀软后跑 -Mode Repair') }
      else { Bad ($f + ' 写失败（既没写进目标也没放成 .new）—— 跑 -Mode Repair 或看日志'); Add-Action ($f + ' 写失败：看日志后跑 -Mode Repair') }
    }
  }
  # 2026-10-05（审查 r5 F3）：helper 段剩下的裸 IO 也都加保护，别让权限/磁盘异常打断整个安装
  try {
    foreach ($sub in @('logs', 'state')) {
      $p = Join-Path $script:ProgDataWin $sub
      if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    }
  } catch {
    Warn ('logs/state 目录建不出来: ' + $_.Exception.Message)
    Add-Action 'logs/state 目录没建成功：检查 C:\ProgramData\CMP40HXGen2 的权限后跑 -Mode Repair'
  }
  # RunPostBind.cmd：沿用已验证的逻辑，只把“驱动自愈源列表”换成这台机器的实际路径
  # （原编码原样写回：上游这份是 UTF-8，被当 GBK 读回写会把中文注释改坏）
  # 2026-10-05（审查 r6 L7）：读模板失败只跳过"重写"这一段，**不要 return** —— 后面还有"新路径工具是否就位"的检查要做
  # 2026-10-05（审查 r7 F1）：RunPostBind.cmd 也要落到 %ProgramData% 并被 SYSTEM 执行，改写前同样要过清单
  #   （校验**包内源模板**；写回后的内容因路径替换与源不同，所以清单条目天然只描述源文件）。
  $tplPath = Join-Path $src 'RunPostBind.cmd'
  $tplOk = $true
  $tplKey = 'windows/RunPostBind.cmd'
  if (-not $wantMd5.ContainsKey($tplKey)) {
    Warn 'RunPostBind.cmd 在 payload\sha256.txt 里没有条目 —— 跳过本次重写（不写未校验的文件）；重新解压一份完整包'
    Add-Action 'RunPostBind.cmd 缺清单条目：重新解压完整包后跑 一键安装.cmd'
    $tplOk = $false
  }
  else {
    try {
      $tplMd5 = (Get-FileHash -LiteralPath $tplPath -Algorithm MD5).Hash.ToLower()
      if ($tplMd5 -ne $wantMd5[$tplKey].ToLower()) {
        Warn ('RunPostBind.cmd 包内模板与清单不符（' + $tplMd5 + ' != ' + $wantMd5[$tplKey] + '）—— 跳过重写；重新解压一份包')
        Add-Action 'RunPostBind.cmd 模板与清单不符：重新解压完整包后再装'
        $tplOk = $false
      }
    }
    catch {
      Warn ('算不了 RunPostBind.cmd 模板的哈希: ' + $_.Exception.Message + ' —— 跳过重写')
      Add-Action 'RunPostBind.cmd 模板哈希算不了（权限/杀软）：处理后重装'
      $tplOk = $false
    }
  }
  $read = $null
  if ($tplOk) {
    try {
      $read = Read-TextAutoDetect $tplPath
      Info ('RunPostBind.cmd 模板编码: ' + $read.Encoding.WebName)
    }
    catch {
      Warn ('读不了包内 RunPostBind.cmd 模板: ' + $_.Exception.Message + ' —— 跳过本次重写，开机任务保持旧版（下面的新路径检查照做）')
      Add-Action 'RunPostBind.cmd 模板读失败：重新解压一份完整包后跑 -Mode Repair'
      $read = $null
    }
  }
  # 2026-10-05（审查 r7 F3）：模板不可用（读不到 / 不过清单）时，整段"替换 + 校验 + 写回"都不做 ——
  #   否则 $text='' 会让"没替换成功"的判断成立、报出误导性的 Bad（还顺手把退出码变成 1）。
  if ($null -eq $read) {
    Info '本次跳过 RunPostBind.cmd 重写（模板不可用，详见上面的 Warn/待办）'
  }
  else {
    $text = $read.Text
    $sourceList = '"' + $script:ProgDataDrv + '" "' + $script:VendorDrvDir + '"'
    $newLine = 'for %%S in (' + $sourceList + ') do ('
    # 注意 CRLF：用 lookahead 匹配行尾，避免把 \r 吃掉（.NET 的 (?m)$ 匹配在 \n 之前）
    $replaced = $text -replace '(?m)^for %%S in \(.*\) do \((?=\r?$)', $newLine
    if ($replaced -eq $text) {
      # 幂等：包里的模板本来就写着本机路径 → 内容没变是正常的。
      # 只有连"本机路径那一行"都找不到，才算真的没替换成功（旧版在这里一律报失败，会让 -Mode Repair 的退出码变成 1）
      $alreadyLocal = $text -match ('(?m)^for %%S in \(' + [regex]::Escape($sourceList) + '\) do \(')
      if ($alreadyLocal) { Ok 'RunPostBind.cmd 驱动自愈源本来就是这个本机路径（无需改动）' }
      else { Bad 'RunPostBind.cmd 的驱动源行没替换成功（保持原样），请检查载荷是否被改动'; Add-Action 'RunPostBind.cmd 的驱动自愈源没按本机路径重写：把包内 payload\windows\RunPostBind.cmd 发回来' }
    }
    else {
      $chk = ([regex]::Matches($replaced, [regex]::Escape($script:ProgDataDrv))).Count
      if ($chk -ge 1) { Ok ('RunPostBind.cmd 驱动自愈源已按本机路径重写（含 ' + $script:ProgDataDrv + '）') } else { Bad 'RunPostBind.cmd 重写后没找到本机自愈源路径' }
    }
    # 2026-10-05（审查 r8 R1）：写回与收尾 Ok 挪进 else —— 模板不可用时既不写、也不再报"写不进去"、更不打假 Ok
    try {
      [IO.File]::WriteAllText((Join-Path $script:ProgDataWin 'RunPostBind.cmd'), $replaced, $read.Encoding)
    } catch {
      Warn ('RunPostBind.cmd 写不进去: ' + $_.Exception.Message + ' —— 开机任务可能还是旧版；先手工结束 CMP40HXGen2.exe 再跑 -Mode Repair')
      Add-Action 'RunPostBind.cmd 没更新成功：跑 -Mode Repair 或手工结束 CMP40HXGen2.exe 后重装一次'
    }
    Ok ('RunPostBind.cmd → ' + $script:ProgDataWin + '（首选新路径 + 旧 ACE 路径 fallback + 多源自愈 + 3 次重试）')
  }
  $tnew = Join-Path $script:ProgDataWin '40hx-retrain-inpout.ps1'
  if (Test-Path $tnew) { Ok '40hx-retrain-inpout.ps1 就位 → 开机走新路径（inpoutx64 直写 MMIO，ACE-BOOT 全程不停）' }
  else { Warn '40hx-retrain-inpout.ps1 没铺上 → 开机任务会回落到旧路径（每次开机停一次 ACE-BOOT）'; Add-Action '新路径工具缺失：重新解压完整包后跑一次 -Mode Repair' }
  Info ('自愈源: ' + $script:ProgDataDrv + ' , ' + $script:VendorDrvDir + ' , ESP \EFI\40HX\drv（兜底）')
  # 注意：不要把裸 .sys 再拷到包目录/C:\Temp 之类的非信任路径 —— 实测火绒会立刻报
  # Exploit/Vulndriver.ad 并删除文件（只有 System32\drivers、%ProgramData% 下那两处和 ESP 存活）
}

function Install-InpoutFiles {
  param([string]$BackupDir)
  Head '新路径驱动 (inpoutx64) —— ACE 不用停的那条路'
  $rawDir = Join-Path $script:PayloadDir 'drivers'
  foreach ($f in $script:InpoutFiles) {
    $b64 = Join-Path $rawDir ($f.Name + '.b64')
    if (-not (Test-Path $b64)) { Fail ("载荷缺失: " + $b64) $script:ExitHash '包不完整（漏拷/杀软删过载荷）→ 重新解压一份完整包再跑，别只拷 Install-40HXUnlock.ps1' }
    $bytes = [IO.File]::ReadAllBytes($b64)
    $b64text = [Text.Encoding]::ASCII.GetString($bytes) -replace "[\r\n\s]", ''
    $bin = [Convert]::FromBase64String($b64text)
    $sha = [Security.Cryptography.SHA256]::Create()
    $binHash = ([BitConverter]::ToString($sha.ComputeHash($bin)) -replace '-', '').ToLower()
    if ($binHash -ne $f.Sha256) { Fail ($f.Name + " 载荷解码后哈希不符: " + $binHash) $script:ExitHash ('期望 ' + $f.Sha256 + ' —— 传输损坏或杀软改过文件，重新解压一份包') }
    Ok ($f.Name + " 载荷解码 + 哈希校验通过 (" + $bin.Length + " B)")
    $targets = New-Object System.Collections.ArrayList
    if ($f.Kinds -contains 'sys') { [void]$targets.Add((Join-Path $script:SysDrv $f.Name)) }
    [void]$targets.Add((Join-Path $script:ProgDataDrv $f.Name))
    [void]$targets.Add((Join-Path $script:VendorDrvDir $f.Name))
    foreach ($t in ($targets | Select-Object -Unique)) {
      $parent = Split-Path -Parent $t
      if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
      [void](Save-PayloadFile -Path $t -Bytes $bin -Sha256 $f.Sha256 -Name $f.Name -Service $f.Service)
    }
  }
  Start-Sleep -Seconds 10
  $ioSurvived = $true
  foreach ($f in $script:InpoutFiles) {
    # 只检查“本来就该存在”的路径：inpoutx64.dll 本来就不进 System32\drivers（Kinds=drv），检查它会造成假警报
    $chkTargets = New-Object System.Collections.ArrayList
    if ($f.Kinds -contains 'sys') { [void]$chkTargets.Add((Join-Path $script:SysDrv $f.Name)) }
    [void]$chkTargets.Add((Join-Path $script:ProgDataDrv $f.Name))
    foreach ($t in $chkTargets) {
      if (-not (Test-Path $t)) { $ioSurvived = $false; Warn ("新路径驱动被删: " + $t + " —— 杀软隔离，请加信任区后重跑 Install/Repair"); Add-Action '杀软隔离了 inpoutx64：把 README 第 1.1 节那几项加进信任区后跑一次 -Mode Repair' }
    }
  }
  if ($ioSurvived) { Ok '10 秒后 inpoutx64 仍在（没被杀软清理）' }
  $espRoot = Mount-Esp
  if ($espRoot) {
    $drvEsp = Join-Path $espRoot $script:EspDrvFallback
    if (-not (Test-Path $drvEsp)) { New-Item -ItemType Directory -Force -Path $drvEsp | Out-Null }
    foreach ($f in $script:InpoutFiles) {
      Copy-Item -LiteralPath (Join-Path $script:ProgDataDrv $f.Name) -Destination (Join-Path $drvEsp $f.Name) -Force -ErrorAction SilentlyContinue
    }
    Ok ("ESP 兜底驱动源已含新路径驱动: " + $drvEsp)
  } else { Warn 'ESP 挂载失败，未部署 ESP 兜底驱动源'; Add-Action 'ESP 兜底驱动源没部署成功：重跑 -Mode Repair（或看 排查指引.md 第 4 节）' }
}

function Install-Efi {
  param([string]$BackupDir)
  Head 'ESP 解锁固件'
  $espRoot = Mount-Esp
  if (-not $espRoot) {
    $hint = 'ESP 挂载失败（需要管理员；或 ESP 被 BitLocker/其他工具占用）'
    if ($script:EspMountError) { $hint += ' ; mountvol 报: ' + $script:EspMountError }
    $tip = '① 必须是管理员窗口（一键安装.cmd 会自动提权）；② 手动敲 mountvol 看有没有卷被占用；③ BitLocker 开着会挂不上，先暂停；④ 虚拟机/WSL 里跑不了，要在真机 Windows 上跑'
    Fail $hint $script:ExitHash $tip
  }
  $srcEfi = Join-Path $script:PayloadDir 'EFI\40HXUNLK.EFI'
  if (-not (Test-Path $srcEfi)) { Fail ("载荷缺失: " + $srcEfi) $script:ExitHash '包的 payload\EFI 目录丢了（漏拷或杀软删）→ 重新解压一份完整包' }
  $srcHash = Get-FileSha256 $srcEfi
  $srcSize = (Get-Item $srcEfi).Length
  if ($srcHash -ne $script:EfiSha256) {
    Fail ("解锁固件哈希不符: " + $srcHash + "（期望 " + $script:EfiSha256 + "）") $script:ExitHash '包被改过 → 重新解压；若你确实换了固件版本，请同步改脚本顶部的 $script:EfiSha256'
  }
  Ok ("解锁固件载荷校验通过: " + $srcSize + " B  sha256 " + $srcHash.Substring(0, 16) + "…")

  # 2026-10-01b（第三方审查 D3）：默认**不再覆盖** \EFI\Boot\bootx64.efi。
  #   那是 Windows 自己的引导文件；覆盖后万一固件不认我们的启动项、chainload 又出问题 → 开不了机，
  #   而"进不了系统就跑不了 Uninstall"，ESP 上的 .40hx.bak 也就用不上。
  #   本机实测：自建 NVRAM 启动项（Boot#### → \EFI\40HX\40HXUNLK.EFI）+ BootOrder 已能正常解锁并进系统，不需要覆盖。
  #   只有确认"主板连 Boot#### 都不认"时，才用 -WriteBootx64 显式打开。
  $targets = @((Join-Path $espRoot 'EFI\40HX\40HXUNLK.EFI'))
  if ($KeepBootx64) { Info '（-KeepBootx64 现在默认生效：\EFI\Boot\bootx64.efi 不动）' }
  if ($WriteBootx64) {
    $targets += (Join-Path $espRoot 'EFI\Boot\bootx64.efi')
    Warn '按 -WriteBootx64 显式要求：将覆盖 Windows 的 \EFI\Boot\bootx64.efi（原文件备份成 .40hx.bak，卸载会还原）'
  }
  foreach ($dst in $targets) {
    $parent = Split-Path -Parent $dst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path $dst) {
      $curHash = Get-FileSha256 $dst
      if ($curHash -eq $srcHash) { Ok ("已是最新，跳过写入: " + $dst); continue }
      $bakName = (Split-Path -Leaf $dst) + '.pre40hx.bak'
      Copy-Item -LiteralPath $dst -Destination (Join-Path $BackupDir $bakName) -Force
      Info ("原文件已备份: " + (Join-Path $BackupDir $bakName) + " (sha256 " + $curHash.Substring(0, 16) + "…)")
      # 标准兜底备份名（Uninstall 会用它还原）
      if ((Split-Path -Leaf $dst) -eq 'bootx64.efi') {
        $stdBak = $dst + '.40hx.bak'
        if (-not (Test-Path $stdBak)) { Copy-Item -LiteralPath $dst -Destination $stdBak -Force; Info ("保留原始 Windows 引导文件备份: " + $stdBak) }
      }
    }
    Copy-Item -LiteralPath $srcEfi -Destination $dst -Force
    $newHash = Get-FileSha256 $dst
    if ($newHash -eq $srcHash) { Ok ("写入并回读校验通过: " + $dst) } else { Bad ("写入后哈希不符: " + $dst + " = " + $newHash) }
  }
  Dismount-Esp
}

function Install-BootEntry {
  param([string]$BackupDir, [string]$BootMode)
  Head '固件启动项 (NVRAM)'
  if (-not (Initialize-FwAccess)) { Fail '无法获得固件变量读写权限' $script:ExitNvram '① 必须管理员；② 360/火绒/联想等的「启动项保护 / UEFI 保护」会拒写固件变量，临时关掉再跑；③ 老主板(纯 Legacy)不支持' }
  $entries = Get-AllBootEntries
  Info ("现有固件启动项: " + (($entries | ForEach-Object { $_.Name }) -join ', '))
  $espPart = Get-EspPartitionInfo
  $tpl = Get-WindowsBootManagerTemplate $entries
  $attrs = 1
  if ($tpl) {
    $attrs = $tpl.Entry.Attributes
    Info ("参考项: " + $tpl.Name + " '" + $tpl.Entry.Description + "' 属性=0x" + ('{0:X}' -f $attrs))
  }
  $node = Show-EspPathCheck -Entries $entries -EspPart $espPart
  if (-not $node) {
    if (-not $tpl) { Fail '既取不到 ESP 分区、也没有可参考的启动项，无法构造设备路径' $script:ExitNvram '系统盘必须 GPT + UEFI，并且存在 EFI 系统分区；先跑 -Mode Check 看「系统盘分区 / 固件类型」两行' }
    $node = $tpl.Entry.DeviceNode
    Warn '退化处理：设备路径节点沿用现有启动项的字节'
  }

  $unlock = Get-UnlockBootEntry $entries
  $created = $false
  if ($unlock) {
    Ok ("已存在解锁启动项 " + $unlock.Name + " '" + $unlock.Entry.Description + "' → " + $unlock.FilePath + "（复用，不重复创建）")
    $name = $unlock.Name
    $index = $unlock.Index
  } else {
    $index = Get-FreeBootSlot $entries
    if ($index -lt 0) { Fail '没有空闲 Boot#### 槽位' $script:ExitNvram 'NVRAM 满了（少见）→ 进 BIOS 启动项里删掉几个没用的再跑' }
    $name = 'Boot{0:X4}' -f $index
    $bytes = New-BootEntryBytes -DeviceNode $node -Description '40HX Unlock' -EfiPath '\EFI\40HX\40HXUNLK.EFI' -Attributes $attrs -OptionalData $null
    [IO.File]::WriteAllBytes((Join-Path $BackupDir ($name + '.new.bin')), $bytes)
    Info ("构造 " + $name + ": " + $bytes.Length + " 字节 (描述 '40HX Unlock' → \EFI\40HX\40HXUNLK.EFI)")
    if (-not (Write-FwVar $name $bytes)) { Fail ('写 ' + $name + ' 失败') $script:ExitNvram '同上：先关安全软件的启动项/UEFI 保护；或改用 -BootMode next 一次性启动项试跑' }
    $readback = Read-FwVar $name
    if (-not $readback) { Fail ('回读 ' + $name + ' 失败') $script:ExitNvram '有的主板对某些 Boot 槽位行为异常 → 重跑一次，或直接进 BIOS 手动选启动项 "40HX Unlock"（自建启动项已建好）' }
    if ([Convert]::ToBase64String($readback) -ne [Convert]::ToBase64String($bytes)) {
      [IO.File]::WriteAllBytes((Join-Path $BackupDir ($name + '.readback.bin')), $readback)
      Fail ('回读内容与写入不一致（已存证到 backup 目录）') $script:ExitNvram '主板固件改写了内容（少见）→ 进 BIOS 手动设启动项；backup 目录里有原始字节可对照'
    }
    Ok ("写入并逐字节回读校验通过: " + $name)
    $created = $true
  }

  $order = Get-BootOrderIndices
  Info ("当前 BootOrder = " + (Format-BootOrderIndices $order))
  if ($BootMode -eq 'next') {
    $bn = New-Object byte[] 2
    [Array]::Copy([BitConverter]::GetBytes([uint16]$index), 0, $bn, 0, 2)
    if (Write-FwVar 'BootNext' $bn) {
      $rb = Read-FwVar 'BootNext'
      if ($rb -and $rb.Length -eq 2 -and [BitConverter]::ToUInt16($rb, 0) -eq $index) { Ok ("BootNext=" + ('{0:X4}' -f $index) + "（只在下次开机生效一次，之后自动失效）") }
      else { Warn 'BootNext 回读不符' }
    }
  } elseif ($BootMode -eq 'default') {
    if ($order.Count -gt 0 -and $order[0] -eq $index) {
      Ok ("BootOrder 第一位已经是 " + ('{0:X4}' -f $index) + "，不改动")
    } elseif (@($order).Count -eq 0) {
      # 2026-10-01b（第三方审查 N3）：这属于"安装没做到"—— 原来只 Warn，脚本结尾仍打印"安装步骤全部成功"并 exit 0
      Bad '读不到 BootOrder（固件变量读取失败）→ 拒绝改写（防止把引导顺序写成只有解锁项）。先重启重试，或进 BIOS 把 "40HX Unlock" 手动设为第一启动项'
      Add-Action 'BootOrder 读不到：重启后再跑一次 Install/Repair；或在 BIOS 里手动把 "40HX Unlock" 排到第一位'
    } else {
      $newOrder = @($index) + @($order | Where-Object { $_ -ne $index })
      if (Write-BootOrderIndices -Indices $newOrder -BackupDir $BackupDir) {
        $rb = Get-BootOrderIndices
        if ((Format-BootOrderIndices $rb) -eq (Format-BootOrderIndices $newOrder)) {
          Ok ("BootOrder 现在 = " + (Format-BootOrderIndices $rb) + "（原顺序已备份）")
        } else { Bad ("BootOrder 回读不符: " + (Format-BootOrderIndices $rb)) + '（解锁大概率不生效）' ; Add-Action 'BootOrder 回读不符：进 BIOS 手动把 "40HX Unlock" 排到第一位' }
      } else {
        # 2026-10-01b（第三方审查）：写失败原来只内部 Warn → 脚本仍可能以 0 退出、打印"安装成功"。
        #   引导顺序没写好 = 解锁不会自动生效，必须算失败并把手工做法写进"待办"。
        Bad 'BootOrder 写入失败（引导顺序没改，解锁不会自动生效）'
        Add-Action 'BootOrder 写失败：① 先关安全软件的"启动项保护"再重跑；② 或进 BIOS 把 "40HX Unlock" 手动设为第一启动项'
      }
    }
    if (Read-FwVar 'BootNext') { Remove-FwVar 'BootNext' | Out-Null; Info '清掉遗留的 BootNext' }
  } else {
    Info ("BootMode=none：只写了变量，" + $name + " 已经在 BootOrder 里（如果不在，请手动在 BIOS 里选 '40HX Unlock' 启动项）")
  }

  # 状态文件，供 Verify/Uninstall 用
  $stateDir = Split-Path -Parent $script:StateFile
  if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
  $state = [ordered]@{
    InstalledAt     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    BootEntry       = $name
    BootEntryIndex  = $index
    BootEntryCreated = $created
    BootMode        = $BootMode
    BootOrder       = (Format-BootOrderIndices (Get-BootOrderIndices))
    EspRoot         = $script:EspRoot
    PkgRoot         = $script:PkgRoot
    EfiSha256       = $script:EfiSha256
    EfiBackupName   = 'bootx64.efi.40hx.bak'
    EspPartitionGuid = $(if ($espPart) { $espPart.GuidText } else { '' })
    DeviceNodeHex   = $(if ($node) { [BitConverter]::ToString($node) } else { '' })
    BackupDir       = $BackupDir
    ComputerName    = $env:COMPUTERNAME
  }
  ($state | ConvertTo-Json) | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
  Info ('状态文件: ' + $script:StateFile)
}

function Install-Task {
  Head '开机任务 + 厂商自启收尾'
  $cmdLine = 'cmd.exe /d /c ' + (Join-Path $script:ProgDataWin 'RunPostBind.cmd')
  if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
    Invoke-Native { schtasks /delete /tn $script:TaskName /f 2>&1 | Out-Null }
  }
  $out = (Invoke-Native { schtasks /create /tn $script:TaskName /sc onstart /ru SYSTEM /rl HIGHEST /tr $cmdLine /f 2>&1 } | Out-String)
  if ($out -match '成功|SUCCESS') { Ok ('任务已注册: ' + $script:TaskName + ' (BootTrigger, SYSTEM/Highest)') }
  elseif ($out -match 'ERROR|错误') { Warn ('任务注册可能失败: ' + $out.Trim()) }
  else { Info ('schtasks: ' + $out.Trim()) }
  $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($t) {
    $act = ($t.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -join ' '
    Info ('  动作: ' + $act)
    Info ('  触发器: ' + (($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', ') + ' ; 身份: ' + $t.Principal.UserId + '/' + $t.Principal.RunLevel)
  } else { Bad '任务未注册成功' }
  # 2026-10-01：登录后 60 秒自动补跑一次（见 $script:TaskNameLogon 的注释）。
  # 为什么需要：开机那轮是最早的一批服务，客户机实测会因杀软拦驱动 / GPU 未就绪 / 驱动文件被清而失败，
  #   而用户登录后手动跑一次总是成功 —— 那就别让用户点，由系统自己补跑。
  # 幂等：已经到 Gen2 时工具输出 PASS: already physical Gen2 x16; no writes needed.，不做任何写入。
  if (Get-ScheduledTask -TaskName $script:TaskNameLogon -ErrorAction SilentlyContinue) {
    Invoke-Native { schtasks /delete /tn $script:TaskNameLogon /f 2>&1 | Out-Null }
  }
  $out2 = (Invoke-Native { schtasks /create /tn $script:TaskNameLogon /sc onlogon /delay 0001:00 /ru SYSTEM /rl HIGHEST /tr $cmdLine /f 2>&1 } | Out-String)
  if ($out2 -match '成功|SUCCESS') { Ok ('登录后补跑任务已注册: ' + $script:TaskNameLogon + ' (LogonTrigger +60s, SYSTEM/Highest)') }
  else { Warn ('登录后补跑任务注册可能失败: ' + $out2.Trim() + ' —— 需要它的话跑 -Mode Repair 重试') }
  # 厂商自启（会在本机把算力清掉/覆盖 EFI）一律停掉
  # 2026-09-30 修：不再只认两个固定任务名（厂商换名就漏），改成按"名字或动作命令行里含 40HX"全扫
  $dis = 0
  foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    if ([string]$t.TaskName -eq $script:TaskName) { continue }
    if ([string]$t.TaskName -eq $script:TaskNameLogon) { continue }
    $acts = ((@($t.Actions) | ForEach-Object { ([string]$_.Execute + ' ' + [string]$_.Arguments) }) -join ' ')
    if (([string]$t.TaskName -match '40HX|CMP40HX') -or ($acts -match '40HX|CMP40HX')) {
      if ($t.State -ne 'Disabled') {
        # 2026-10-05（审查 r5 N4）：同族修复 —— 带的 TaskPath，避免同名叶任务分布在不同文件夹时指错对象
        Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue | Out-Null
        Ok ('已禁用其它 40HX 自启任务: ' + $t.TaskName)
        $dis++
      }
    }
  }
  if ($dis -eq 0) { Info '没有发现其它需要禁用的 40HX 任务' }
  $runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
  $v = (Get-ItemProperty -Path $runKey -Name '40HXGen2' -ErrorAction SilentlyContinue).'40HXGen2'
  if ($v) {
    Set-ItemProperty -Path $runKey -Name '40HXGen2_parked' -Value $v -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runKey -Name '40HXGen2' -ErrorAction SilentlyContinue
    Ok '已摘掉 HKCU Run 的厂商登录自启 40HXGen2（存为 40HXGen2_parked）'
  }
  # 2026-09-30 修：旧版只在厂商键已存在时才写 → 干净机器上（该键是厂商安装器建的）这两个
  # "永不复位显卡"的策略根本没写；而厂商 Gen2AutoHard 默认 1 = Stage2（Link Disable + PnP 复位显卡）
  # = 清算力 + 可能留 Code 43（厂商文档也说 40HX 是唯一显示卡时登录后会黑屏几秒）。
  if (-not (Test-Path 'HKLM:\SOFTWARE\40HXUnlock')) { New-Item -Path 'HKLM:\SOFTWARE\40HXUnlock' -Force | Out-Null }
  foreach ($kv in @(@('Gen2AutoHard', 0), @('Gen2PnpFallback', 0))) {
    New-ItemProperty -Path 'HKLM:\SOFTWARE\40HXUnlock' -Name $kv[0] -PropertyType DWord -Value $kv[1] -Force | Out-Null
  }
  Ok '策略键 Gen2AutoHard=0 / Gen2PnpFallback=0（绝不复位显卡 = 不毁算力；键不存在也会建）'
  # 杀软排除（Defender；火绒要在 UI 里加，Check 已列出 4 个路径）
  try {
    Add-MpPreference -ExclusionPath $script:ProgDataRoot -ErrorAction Stop
    Add-MpPreference -ExclusionProcess 'CMP40HXGen2.exe' -ErrorAction SilentlyContinue
    Ok 'Windows Defender 已加排除: C:\ProgramData\CMP40HXGen2'
  } catch { Info '跳过 Defender 排除（未启用或无权限）' }
}

function Install-Gsp {
  # 2026-09-30 修：①不再把 nvidia-smi 的 "N/A" 当"已开启" ②开关写进显示类子键（设备真正读的那一个）
  $g = Get-GspState
  $script:GspStateBeforeInstall = $g   # 2026-10-04（审查 L5）：注意这是**写 EnableGpuFirmware 之前**读到的状态；供后面的按需体检复用，别再跑一遍 nvidia-smi
  if ($g.State -eq 'on') { Ok ('GSP 已开启 (' + $g.Value + ')'); return }
  # 设备权威子键（Enum\<实例>\Driver）
  $authIdx = ''
  try {
    $d40 = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'DEV_1F0B' }) | Select-Object -First 1
    if ($d40) { $authIdx = Get-AuthoritativeDisplayKeyIndex $d40.InstanceId }
  } catch { }
  if ($authIdx) { Info ('该显卡设备真正使用的显示类子键: ' + $authIdx + '（Enum\<实例>\Driver）') }
  if ($g.State -eq 'unknown') {
    Warn ('GSP 状态未知（' + $g.Line + '）—— 没驱动就解锁 = 黑屏 + 代码 43')
    Add-Action '机器上还没有可用的 NVIDIA 驱动/nvidia-smi：先装驱动，再重跑 -Mode Repair，然后【完全关机】再开机'
    return
  }
  # State = 'off'：写显示类子键
  $keys = @(Get-DisplayClassSubKeys)
  if ($keys.Count -eq 0) {
    Warn '没找到 CMP 40HX 的显示类子键（驱动没装全？）→ 退化只写 Services\nvlddmkm\Parameters（实测该处不生效）'
    Add-Action '没找到 40HX 的显示类子键：装好驱动后重跑 -Mode Repair，让 GSP 开关写到正确位置'
  }
  $alreadyWasOne = $true
  foreach ($k in $keys) {
    $before = $k.Value
    if ($null -eq $before -or [int]$before -ne 1) { $alreadyWasOne = $false }
    New-ItemProperty -Path $k.Path -Name 'EnableGpuFirmware' -PropertyType DWord -Value 1 -Force | Out-Null
    $after = (Get-ItemProperty -Path $k.Path -Name 'EnableGpuFirmware' -ErrorAction SilentlyContinue).EnableGpuFirmware
    $mark = ''
    if ($authIdx -and $k.Name -eq $authIdx) { $mark = ' (设备权威子键)' }
    if ($after -eq 1) { Ok ('GSP 开关已写: 显示类子键 ' + $k.Name + $mark + ' [' + $k.DriverDesc + '] EnableGpuFirmware ' + $(if ($null -eq $before) { '<无>' } else { [string]$before }) + ' -> 1') }
    else { Bad ('写显示类子键 ' + $k.Name + ' 的 EnableGpuFirmware 失败（回读=' + [string]$after + '）') }
  }
  # 权威子键没被 MatchingDeviceId 匹配到（少见）→ 按 Enum 给出的索引直接写一份，避免写错地方
  if ($authIdx -and (@($keys | Where-Object { $_.Name -eq $authIdx }).Count -eq 0)) {
    $ap = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\' + $authIdx
    if (Test-Path $ap) {
      New-ItemProperty -Path $ap -Name 'EnableGpuFirmware' -PropertyType DWord -Value 1 -Force | Out-Null
      $av = (Get-ItemProperty -Path $ap -Name 'EnableGpuFirmware' -ErrorAction SilentlyContinue).EnableGpuFirmware
      Ok ('GSP 开关已写: 设备权威子键 ' + $authIdx + '（MatchingDeviceId 没匹配到它）EnableGpuFirmware -> ' + [string]$av)
    } else { Warn ('Enum 指向的权威子键 ' + $authIdx + ' 不存在（设备刚重装驱动？）') }
  }
  if ($alreadyWasOne) {
    # 值本来就是 1、GSP 却是 N/A → 几乎都是"驱动没真正重新加载过"（快速启动/混合关机）或驱动包装不全
    Warn '注意：GSP 开关本来就是 1，但 nvidia-smi 显示 N/A —— 说明驱动从来没在开机时重新初始化过'
    Info '常见原因：① 快速启动开着（"关机"=混合关机，驱动不重载）② 装完驱动后没真正冷启动过'
    Info '本脚本已把快速启动关掉（见上面的"快速启动"行）；请【完全关机】再开机后复核；若仍是 N/A，请跑 工具-测试与修复\查GSP.cmd（或包根 GSP体检.cmd）把报告发回来'
    Add-Action 'GSP 开关本来就是 1 但状态仍是 N/A：完全关机（不是重启）再开机 → 跑 -Mode Verify 复核；仍 N/A 就跑 工具-测试与修复\查GSP.cmd（包根 GSP体检.cmd）把报告发回来'
  }
  # 兼容冗余：老位置也写一份（无害，万一某版驱动读那里）
  $legacyKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters'
  if (-not (Test-Path $legacyKey)) { New-Item -Path $legacyKey -Force | Out-Null }
  New-ItemProperty -Path $legacyKey -Name 'EnableGpuFirmware' -PropertyType DWord -Value 1 -Force | Out-Null
  Warn 'GSP 原为未启用 → 已写入 EnableGpuFirmware=1（显示类子键 + 兼容位置）'
  Warn '必须【完全关机再开机】才生效 —— 不是"重启"！重启可能留下状态 = 黑屏 + 代码 43'
  Add-Action '本次刚打开 GSP：必须【完全关机】（开始菜单→关机，最好拔电 10 秒）再开机；开机后跑 -Mode Verify 复核 GSP 行显示版本号'
}

function Install-Power {
  # 2026-09-30 新增：关快速启动（HiberbootEnabled=0）。
  # 为什么必须：快速启动 = 1 时"关机"是混合关机，内核与 nvlddmkm 状态从 hiberfile 恢复、不重新初始化
  # → GSP / 驱动类设置永远不生效，"开机黑屏 + 代码 43"就一直是这个样子。厂商安装器的"电源三项"里也关它。
  Head '电源：快速启动'
  $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
  try {
    $v = (Get-ItemProperty -Path $k -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($v -eq 1) {
      New-ItemProperty -Path $k -Name 'HiberbootEnabled' -PropertyType DWord -Value 0 -Force | Out-Null
      $after = (Get-ItemProperty -Path $k -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue).HiberbootEnabled
      if ($after -eq 0) { Ok '快速启动已关闭（HiberbootEnabled 1 -> 0）：这样"关机"才是真关机，显卡驱动会重新初始化' }
      else { Bad ('关快速启动失败，回读 HiberbootEnabled=' + [string]$after) }
    }
    elseif ($null -eq $v) {
      New-ItemProperty -Path $k -Name 'HiberbootEnabled' -PropertyType DWord -Value 0 -Force | Out-Null
      Ok '快速启动：注册表里原本没有该项 → 已写 HiberbootEnabled=0（保险起见）'
    }
    else { Ok ('快速启动本来就是关的（HiberbootEnabled=' + [string]$v + '）') }
  } catch {
    Warn ('关快速启动失败: ' + $_.Exception.Message)
    Add-Action '关快速启动失败：手动到 控制面板→电源选项→选择电源按钮的功能→更改当前不可用的设置→取消勾选"启用快速启动"'
  }
}

# ================================================================ GSP 体检（并入安装流程，只读）
function Invoke-GspHealthCheck {
  # 2026-10-04 新增（用户要求：**按需触发**）：装完只在 GSP 没启用时才跑这一次体检。
  #   只读 = 不写系统；副作用只有"落一份报告"（桌面 + 包内 logs 各一份）。
  #   绝不改变安装结论：不动 $script:FailCount / $script:WarnCount / 退出码，异常一律 Info。
  Head 'GSP 体检（只读，不写系统；报告落桌面）'
  $tool = Join-Path $script:PkgRoot '工具-测试与修复\查GSP.ps1'
  if (-not (Test-Path -LiteralPath $tool)) { Info '包内没有 工具-测试与修复\查GSP.ps1 → 跳过（不影响安装）'; return }
  $desk = [Environment]::GetFolderPath('Desktop')
  if (-not $desk) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
  $out = Join-Path $desk ('40HX-GSP体检-' + $env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  # 2026-10-04（第 22 轮审查 H1）：体检脚本结尾在"非 NO_PAUSE"时会弹记事本 + Read-Host 等回车 ——
  #   在一键安装里那等于**卡死安装**（提示还被吞掉，用户只看到界面停住）。临时传 NO_PAUSE=1，try/finally 还原。
  $oldNoPause = $env:NO_PAUSE
  try { $env:NO_PAUSE = '1' } catch { }
  $tmpOut = Join-Path $env:TEMP ('gsp-check-out-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
  $tmpErr = $tmpOut + '.err'
  try {
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $tool + '"'),'-NoElevate','-OutFile',('"' + $out + '"'))
    $finished = $false
    $proc = $null
    # 2026-10-04（第 23 轮审查 中-1）：**抑制子进程 stdout/stderr** —— 报告只落桌面（+包内 logs），
    #   控制台保留安装器自己的"结论/报告"两行；否则整份报告会刷进一键安装界面。
    try {
      $proc = Start-Process -FilePath $psExe -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -ErrorAction Stop
    } catch { $proc = $null }   # 2026-10-04（审查 低-2）：try 只包 Start-Process，回退不会重复跑一次体检
    if ($proc) {
      # 2026-10-04（审查 M2）：整体超时 120 秒，绝不让安装无限等待
      if ($proc.WaitForExit(120000)) { $finished = $true }
      else {
        try { $proc.Kill(); $null = $proc.WaitForExit(5000) } catch { }   # 2026-10-04（审查 低-5）：Kill 后等它收尾再读报告
        Info 'GSP 体检超过 120 秒已被终止（不影响安装）；需要时手动跑 工具-测试与修复\查GSP.cmd'
      }
    } else {
      # 回退路径（某些宿主 -NoNewWindow 不可用）。2026-10-04（审查 低-1）：必须走 Invoke-Native ——
      #   本脚本硬规则：PS 5.1 下外部程序往 stderr 写字即使 2>&1|Out-Null 也会终止脚本；且此处是全包最后的保险，别绕过它。
      Info 'GSP 体检改用同步调用（Start-Process 不可用）'
      try { Invoke-Native { & $psExe -NoProfile -ExecutionPolicy Bypass -File $tool -NoElevate -OutFile $out } | Out-Null } catch { }
      $finished = $true
    }
    if (Test-Path -LiteralPath $out) {
      $verdict = @(Get-Content -LiteralPath $out -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*\[(OK|!!|X)\]' } | Select-Object -First 1)
      if ($verdict.Count -gt 0) { Info ('结论：' + $verdict[0].Trim()) }
      else { Info '报告里没有 [OK]/[!!]/[X] 结论行 —— 请人工看一眼（不影响安装）' }   # 审查 L3
      Info ('报告：' + $out)
      if ($verdict.Count -gt 0 -and $verdict[0] -match '\[OK\]') { Ok 'GSP 体检通过（GSP 已启用 —— 不会因为 GSP 出代码 43）' }
      # 审查 L4：包内 logs 也留一份（防 UAC 用另一管理员账户提权时报告只落在别人桌面）；
      #   2026-10-04（审查 低-4）：只保留最近 5 份，别让 logs 无限长大（它不在 run-*.log 瘦身策略内）。
      try {
        $logDir = Split-Path -Parent $script:LogPath
        if ($logDir -and (Test-Path -LiteralPath $logDir)) {
          Copy-Item -LiteralPath $out -Destination $logDir -Force -ErrorAction SilentlyContinue
          $old = @(Get-ChildItem -LiteralPath $logDir -Filter '40HX-GSP体检-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5)
          foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        }
      } catch { }
    } elseif ($finished) {
      Info 'GSP 体检没有生成报告（不影响安装）；需要时手动跑 工具-测试与修复\查GSP.cmd'   # 审查 L1：Info 而非 Warn，保持"体检不改变任何计数"
    }
  } catch { Info ('GSP 体检执行异常（不影响安装）: ' + $_.Exception.Message) }
  finally {
    try { $env:NO_PAUSE = $oldNoPause } catch { }
    Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
  }
}



# ================================================================ 自检（NVRAM/ESP 往返）
function Invoke-SelfTest {
  param([string]$BackupDir)
  $problems = 0
  $script:SelfTestProblems = 0
  Head '自检 1/4: 权限'
  if (Initialize-FwAccess) { Ok '固件变量权限 OK' } else { Bad '固件变量权限失败'; $problems++ }

  Head '自检 2/4: ESP 读写往返'
  $espRoot = Mount-Esp
  if (-not $espRoot) { Bad 'ESP 挂载失败'; $problems++ }
  else {
    Ok ("ESP = " + $espRoot)
    $probe = Join-Path $espRoot 'efi-selftest.tmp'
    $data = New-Object byte[] 4096
    (New-Object Random).NextBytes($data)
    [IO.File]::WriteAllBytes($probe, $data)
    if (Test-Path $probe) {
      $back = [IO.File]::ReadAllBytes($probe)
      if ([Convert]::ToBase64String($back) -eq [Convert]::ToBase64String($data)) { Ok '写入/回读 4KB 随机数据一致' }
      else { Bad 'ESP 回读内容不一致'; $problems++ }
      Remove-Item -LiteralPath $probe -Force
      if (-not (Test-Path $probe)) { Ok '测试文件已删除' } else { Bad '测试文件删不掉'; $problems++ }
    } else { Bad 'ESP 写入失败'; $problems++ }
    foreach ($p in @((Join-Path $espRoot 'EFI\40HX\40HXUNLK.EFI'), (Join-Path $espRoot 'EFI\Boot\bootx64.efi'))) {
      if (Test-Path $p) {
        $h = Get-FileSha256 $p
        if ($h -eq $script:EfiSha256) { Ok ($p + " = OnlyEFI 解锁固件") } else { Warn ($p + " 哈希 " + $h.Substring(0, 16) + "… ≠ OnlyEFI") }
      } else { Info ($p + ' 不存在') }
    }
    Dismount-Esp
  }

  Head '自检 3/4: NVRAM 写入/回读/删除往返（用临时项，不动 BootOrder）'
  $entries = Get-AllBootEntries
  $tpl = Get-WindowsBootManagerTemplate $entries
  $espPart = Get-EspPartitionInfo
  $node = Show-EspPathCheck -Entries $entries -EspPart $espPart
  if (-not $node) {
    if (-not $tpl) { Bad '既取不到 ESP 分区也没有可参考启动项'; $problems++ }
    else { $node = $tpl.Entry.DeviceNode; Warn '退化为沿用现有启动项的节点字节' }
  }
  if ($node) {
    $slot = Get-FreeBootSlot $entries
    if ($slot -lt 0) { Bad '没有空闲槽位'; $problems++ }
    else {
      $testName = 'Boot{0:X4}' -f $slot
      $bytes = New-BootEntryBytes -DeviceNode $node -Description '40HX Selftest (delete me)' -EfiPath '\EFI\40HX\40HXUNLK.EFI' -Attributes 1 -OptionalData $null
      Info ("构造测试项 " + $testName + ": " + $bytes.Length + " 字节")
      if (Write-FwVar $testName $bytes) {
        $rb = Read-FwVar $testName
        if ($rb -and ([Convert]::ToBase64String($rb) -eq [Convert]::ToBase64String($bytes))) { Ok ('写入 + 逐字节回读一致 (' + $testName + ')') }
        else { Bad '回读不一致'; $problems++; if ($rb) { [IO.File]::WriteAllBytes((Join-Path $BackupDir ($testName + '.readback.bin')), $rb) } }
        $parsed = ConvertFrom-BootEntry $rb
        if ($parsed) { Info ("  回读解析: 描述='" + $parsed.Description + "' 路径=" + (Get-BootEntryFilePathText $parsed)) }
        Remove-FwVar $testName | Out-Null
        if (-not (Read-FwVar $testName)) { Ok ('测试项已删除 (' + $testName + ')') } else { Bad '测试项删不掉'; $problems++ }
      } else { Bad 'NVRAM 写入失败'; $problems++ }
    }
  }

  Head '自检 4/4: BootOrder 原样写回往返'
  $order = Get-BootOrderIndices
  Info ("当前 BootOrder = " + (Format-BootOrderIndices $order))
  $raw = Read-FwVar 'BootOrder'
  # 2026-10-01b（第三方审查 D2 旁路 A，致命）：读不到就**绝不能**调 Write-FwVar —— 把 $null 传进去
  #   长度算 0，而 SetFirmwareEnvironmentVariableW(name,guid,0,0) 的语义是**删除这个变量**，
  #   等于把 BootOrder 清空（Windows 的启动项全丢），更糟的是下面还会打印"BootOrder 未被改动"。
  if (-not $raw -or $raw.Length -lt 2) {
    Warn 'BootOrder 读不到（或长度异常 <2 字节）→ 这一项跳过、不写入（防止把启动顺序清空）'
    Info '  这不代表解锁有问题：重启后再跑一次自检即可；连续读不到见 排查指引.md「固件变量读不到」'
    $problems++
  } else {
    try { [IO.File]::WriteAllBytes((Join-Path $BackupDir 'BootOrder.selftest.bin'), $raw) } catch { Warn ('原值落盘失败（仍继续：只是原样写回）: ' + $_.Exception.Message) }
    if (Write-FwVar 'BootOrder' $raw) {
      $rb = Read-FwVar 'BootOrder'
      if ($rb -and ([Convert]::ToBase64String($rb) -eq [Convert]::ToBase64String($raw))) { Ok ('BootOrder 写回 + 回读一致 (' + $raw.Length + " 字节，值未变)") }
      else { Bad 'BootOrder 回读不一致'; $problems++ }
    } else { Bad 'BootOrder 写入失败'; $problems++ }
    $after = Get-BootOrderIndices
    if ((Format-BootOrderIndices $after) -eq (Format-BootOrderIndices $order)) { Ok ('BootOrder 未被改动: ' + (Format-BootOrderIndices $after)) } else { Bad 'BootOrder 变了！'; $problems++ }
  }
  if (-not (Read-FwVar 'BootNext')) { Ok 'BootNext 为空（没留一次性启动项）' } else { Warn 'BootNext 有值（注意下次开机走一次性项）' }

  Say ''
  if ($problems -eq 0) { Say '自检结论: 全部通过（ESP 读写、NVRAM 写入/回读/删除、BootOrder 写回 均正常）' 'Green' }
  else { Say ('自检结论: ' + $problems + ' 项失败，见上') 'Red' }
  $script:SelfTestProblems = $problems
  return
}

# ================================================================ 日志瘦身 + “状态是否已经正常”判据（2026-10-02）
# 用户要求：解锁状态完全正常了，就不要再往包里堆日志、也不要再跳“下一步”指引。
# 这里的策略是“保留最近 N 份 + 只删自己生成的空备份目录”，别人的文件一律不动。
function Invoke-Retention {
  $kept = @()
  try {
    $runLogs = @(Get-ChildItem -LiteralPath $script:LogDir -Filter 'run-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($runLogs.Count -gt 10) {
      foreach ($f in ($runLogs | Select-Object -Skip 10)) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        $kept += ('日志 ' + $f.Name)
      }
    }
    # 备份目录里只有“空目录”才删（没存到任何东西的那种，本机实测 33 个里有 26 个是空的）；
    # 存了 NVRAM/ACL/固件的备份一律留着 —— 那是出事时的回滚料。
    $bks = @(Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue)
    foreach ($b in $bks) {
      $has = @(Get-ChildItem -LiteralPath $b.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
      if ($has.Count -eq 0) { Remove-Item -LiteralPath $b.FullName -Recurse -Force -ErrorAction SilentlyContinue; $kept += ('空备份 ' + $b.Name) }
    }
    # 机器上的开机日志：postbind.log 由开机任务自己裁剪（超过 64 KB 只留最后 200 行）；
    # 老版本那份“只增不减”的 retrain-inpout.log 只保留最后 200 行。
    $pdLogs = Join-Path $script:ProgDataWin 'logs'
    foreach ($lf in @('retrain-inpout.log')) {
      $fp = Join-Path $pdLogs $lf
      if ((Test-Path $fp) -and ((Get-Item $fp).Length -gt 131072)) {
        Set-Content -LiteralPath $fp -Value (@(Get-Content -LiteralPath $fp -Tail 200)) -Encoding Default
        $kept += ('裁剪 ' + $lf)
      }
    }
  } catch { }
  if ($kept.Count -gt 0) { Info ('已清理旧日志/空备份（日志保留最近 10 份）: ' + ($kept -join ', ')) }
}

function Test-LiveAllGood {
  # 本次开机是不是已经“两全”——用来决定还要不要给用户留“下一步”指引。
  # ① ESP 的 40hx_log.txt 有 UNLOCKED 行，且文件时间就是本次开机（EFI 先写、Windows 后起，±10 分钟）
  # ② 开机任务这次开机跑过且 rc=0（新路径 PASS 才是 0）
  # ③ GSP 已开 + 40HX 没有代码 43
  $ok = $false
  $bt = $null
  try { $bt = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime } catch { }
  try {
    $espRoot = Mount-Esp
    if ($espRoot) {
      $lg = Join-Path $espRoot '40hx_log.txt'
      if (Test-Path $lg) {
        $hit = (Get-Content -LiteralPath $lg | Select-String 'UNLOCKED \(SS0=0x88888888 SS1=0x8\)' | Select-Object -Last 1)
        if ($hit) {
          # 2026-10-02（第三方审查）：读不到开机时间时**不能**当成“已解锁”（宁严不松）
          if (-not $bt) { $ok = $false }
          elseif ((Get-Item $lg).LastWriteTime -ge $bt.AddMinutes(-10)) { $ok = $true }
        }
      }
      Dismount-Esp
    }
  } catch { $ok = $false }
  if ($ok) {
    try {
      $ti = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction SilentlyContinue
      $bt2 = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
      # 2026-10-02（第三方审查）：任务信息或开机时间读不到 → 一律不算“本次已跑”（宁严不松，否则会误删指引）
      if (-not $ti -or -not $bt2) { $ok = $false }
      elseif ($ti.LastTaskResult -ne 0) { $ok = $false }
      elseif ($ti.LastRunTime -lt $bt2.AddMinutes(-10)) { $ok = $false }
    } catch { $ok = $false }
  }
  if ($ok) { try { if ((Get-GspState).State -ne 'on') { $ok = $false } } catch { $ok = $false } }
  if ($ok) {
    try {
      $gpuBad = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'DEV_1F0B' -and $_.Status -ne 'OK' })
      if ($gpuBad.Count -gt 0) { $ok = $false }
    } catch { }
  }
  return $ok
}

# ================================================================ 取证
function Invoke-Verify {
  Head '取证：算力（EFI 侧）'
  $compute = 'FAIL'; $gen2 = 'FAIL'
  # 2026-10-02（第三方审查 H）：ESP 的 40hx_log.txt 与 postbind.log 都是**跨开机累积**的 ——
  #   只查“存在 PASS/UNLOCKED 行”会把历史成功当成本次成功，进而误删“下一步”指引。
  #   这里统一先取本次开机时间，所有"本次开机"判据都以它为门槛（读不到就按不通过处理，宁严不松）。
  $boot = $null
  try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime } catch { }
  $freshCut = $null
  if ($boot) { $freshCut = $boot.AddMinutes(-10) } else { Warn '读不到本次开机时间（LastBootUpTime）→ 下面所有“本次开机”判据按不通过处理（宁严不松）' }
  $espRoot = Mount-Esp
  if ($espRoot) {
    $log = Join-Path $espRoot '40hx_log.txt'
    if (Test-Path $log) {
      $txt = Get-Content -LiteralPath $log
      $hit = $txt | Select-String 'UNLOCKED \(SS0=0x88888888 SS1=0x8\)' | Select-Object -Last 1
      $espFresh = $false
      if ($hit -and $freshCut -and ((Get-Item $log).LastWriteTime -ge $freshCut)) { $espFresh = $true }
      if ($espFresh) { $compute = 'PASS'; Ok ("*** UNLOCKED (SS0=0x88888888 SS1=0x8) ***  文件时间 " + (Get-Item $log).LastWriteTime) }
      elseif ($hit -and -not $freshCut) { Bad '读不到本次开机时间，无法确认 40hx_log.txt 里的 UNLOCKED 是不是本次开机 → 按不通过处理（宁严不松）' }
      elseif ($hit) { Bad ('40hx_log.txt 里的 UNLOCKED 是**之前开机**的记录（文件时间 ' + (Get-Item $log).LastWriteTime + '）→ 本次开机解锁固件很可能没跑；别按“已解锁”处理') }
      else { Bad '40hx_log.txt 里没有本次开机的 UNLOCKED 行' }
      $txt | Select-String -Pattern 'NO-RETRAIN|Root TLS=Gen2|chainload' | Select-Object -Last 4 | ForEach-Object { Info ($_.Line) }
    } else { Bad '40hx_log.txt 不存在 → 解锁固件这次开机没跑（算力一定没解锁）' }
    Dismount-Esp
  } else { Bad 'ESP 挂载失败' }

  Head '取证：PCIe Gen2（Windows 侧）'
  # 首选路径证据（2026-09-29 起）：postbind.log 的 "PASS: Gen2 reached on the new path"
  # + retrain-last.log 的逐条硬件读数（每次覆盖；老版本是 retrain-inpout.log）。判 Gen2 看 LNKSTA（0x1102/0xF102），别看 nvidia-smi 的 link.gen.current（空闲会降速）
  $newPass = $null
  $pbLog2 = Join-Path $script:ProgDataWin 'logs\postbind.log'
  # 2026-10-02：新版本把完整读数写 retrain-last.log（每次覆盖）；老机器上可能还有追加式的 retrain-inpout.log
  $rtLog = Join-Path $script:ProgDataWin 'logs\retrain-last.log'
  if (-not (Test-Path $rtLog)) { $rtLogLegacy = Join-Path $script:ProgDataWin 'logs\retrain-inpout.log'; if (Test-Path $rtLogLegacy) { $rtLog = $rtLogLegacy } }
  $pbStalePass = $false
  # 把 “==== PostBind start 2026/10/02 周五  9:01:10.83 ====” 里的时间抠出来（本地化格式，宽匹配；抠不到返回 $null）
  $ParseStartStamp = {
    param([string]$Line)
    if (-not $Line) { return $null }
    # 兼容两种本地化日期顺序：中文/欧洲 年/月/日；en-US 月/日/年（哪一段是 4 位就当“年”）
    # 日期与时间之间可能夹着星期/“上午·下午”（12 小时制），所以放宽到 12 个非数字字符
    $m = [regex]::Match($Line, '(\d{1,4})[/\-](\d{1,2})[/\-](\d{1,4})[^\d]{0,12}(\d{1,2}):(\d{2}):(\d{2})')
    if (-not $m.Success) { return $null }
    $a = $m.Groups[1].Value; $b = [int]$m.Groups[2].Value; $c = $m.Groups[3].Value
    if ($a.Length -eq 4) { $Y = [int]$a; $Mo = $b; $D = [int]$c }
    elseif ($c.Length -eq 4) { $Y = [int]$c; $Mo = [int]$a; $D = $b }
    else { return $null }
    try { return (Get-Date -Year $Y -Month $Mo -Day $D -Hour ([int]$m.Groups[4].Value) -Minute ([int]$m.Groups[5].Value) -Second ([int]$m.Groups[6].Value)) } catch { return $null }
  }
  if (Test-Path $pbLog2) {
    $pbAll = @(Get-Content -LiteralPath $pbLog2)
    # 2026-10-02（第三方审查 H + 第 2 轮复审 A）：postbind.log 是**跨开机累积**的，而且主任务与“登录后 60 秒补跑”任务
    #   共用同一个日志文件 —— 只认“最后一次 start 之后的 PASS”会把「主任务成功 + 补跑那轮失败」的**好机器**判成 FAIL。
    #   正确做法：给每条 PASS 找它所属那一段的 start 时间，只要**有一条 PASS 属于本次开机**就算落地。
    # 2026-10-02（第 3 轮复审建议）：这里用 ArrayList.Add 显式占位，让 $segIdx 与 $segTime **下标永远一一对应**。
    #   备注（本机实测，别写错）：PS 5.1 里 `$a=@(); $a += $null; $a.Count` → 1（不是 0），
    #   所以原写法本来也不会错位；`@($null).Count` → 0 才是那个常见坑。改这里只是让语义更直白。
    $segIdx = New-Object System.Collections.ArrayList
    $segTime = New-Object System.Collections.ArrayList
    for ($bi = 0; $bi -lt $pbAll.Count; $bi++) {
      if ($pbAll[$bi] -match '={2,}\s*PostBind start') {
        $t0 = & $ParseStartStamp $pbAll[$bi]
        [void]$segIdx.Add($bi)
        [void]$segTime.Add($t0)
      }
    }
    $passHits = @($pbAll | Select-String -Pattern 'PASS:\s*Gen2 reached on the new path')
    if ($passHits.Count -gt 0) {
      $anyParsed = @($segTime | Where-Object { $_ }).Count -gt 0
      for ($pi = $passHits.Count - 1; $pi -ge 0; $pi--) {
        $pIdx = $passHits[$pi].LineNumber - 1
        $segT = $null
        for ($si = $segIdx.Count - 1; $si -ge 0; $si--) { if ($segIdx[$si] -lt $pIdx) { $segT = $segTime[$si]; break } }
        if ($segT -and $freshCut -and ($segT -ge $freshCut)) { $newPass = $passHits[$pi]; break }
      }
      if (-not $newPass) {
        $pbStalePass = $true
        # 一段时间都抠不出来 = 日志格式/区域设置异常 → 明确说出来（宁严：按未落地处理，绝不靠文件时间猜）
        if (-not $anyParsed) { Warn 'postbind.log 里连一条 “PostBind start 时间” 都解析不出来（区域格式异常？）→ 按“本次未落地”处理；请把 postbind.log 发回来核对' }
      }
    }
    ($pbAll | Select-String -Pattern '==== PostBind start|NewPath EXIT=|PASS:|FAIL:|falling back' | Select-Object -Last 3) | ForEach-Object { Info ('postbind: ' + $_.Line.Trim()) }
    if ($pbAll | Select-String -Pattern 'falling back to the legacy ACE path' | Select-Object -Last 1) { Info 'postbind 里出现过“回落到旧路径”：新路径那次没成功（看上面的 NewPath EXIT 码：11 基线不认识 / 12 GPU 未就绪 / 13 inpoutx64 没起来 / 10 链路没到 Gen2 / 3 WinRing0 不可用）' }
  } else { Bad 'postbind.log 不存在（开机任务没跑过）' }
  if ($pbStalePass) {
    if ($anyParsed) { Bad ('postbind.log 里所有“新路径 PASS”都不是**本次开机**写的（上一次开机的记录）→ 本次 Gen2 没有落地，别按 PASS 处理') }
    else { Bad 'postbind.log 里的时间戳解析不出来，无法确认哪条 PASS 属于本次开机 → 按“本次未落地”处理（宁严），别按 PASS 处理' }
  }
  if ($newPass) {
    $gen2 = 'PASS'
    Ok 'postbind: 新路径 PASS —— inpoutx64 直写 MMIO，ACE-BOOT 全程没被停'
    if (Test-Path $rtLog) {
      (Get-Content -LiteralPath $rtLog | Select-String -Pattern 'pre   :|writeOk=|GPU final|ROOT final' | Select-Object -Last 6) | ForEach-Object { Info ('retrain: ' + $_.Line.Trim()) }
      Info ('retrain 完整读数日志时间: ' + (Get-Item $rtLog).LastWriteTime + '（' + (Split-Path -Leaf $rtLog) + '）')
    } else { Warn 'retrain-last.log 不存在（新路径 PASS 就一定会写它，建议重跑一次任务核对）' }
  }
  $lastLog = Join-Path $script:ProgDataWin 'logs\last.log'
  if ($newPass) { Info '旧路径的 last.log 本次不用看（新路径已 PASS）；下面 SC 任务时间戳与 nvidia-smi 仅作参考' }
  elseif (Test-Path $lastLog) {
    $c = Get-Content -LiteralPath $lastLog
    $c | Select-String -Pattern 'GUARD=|SS0=|TLS |GPU final|ROOT final|PASS:|ERROR|EXIT=' | ForEach-Object { Info ($_.Line.Trim()) }
    # 幂等路径会输出 'PASS: already physical Gen2 x16; no writes needed.'，只认 'PASS: physical Gen2 x16' 会误判为失败
    $passLine = ($c | Select-String -Pattern 'PASS:\s*(already\s+)?physical Gen2 x16' | Select-Object -Last 1)
    $exitLine = ($c | Select-String -Pattern 'EXIT=\d+' | Select-Object -Last 1)
    # 2026-10-02（第三方审查 H 的同一族）：last.log 是**旧路径**的日志，新路径生效后它就不再更新 ——
    #   本机实测它停在 2026-09-29 的那次 PASS，于是"新路径失败的那次开机"会被它顶成 PASS（假成功）。
    #   所以这里也要时间门槛：只有本来就是**本次开机**写的才算数。
    $lastFresh = $false
    if ($freshCut -and ((Get-Item $lastLog).LastWriteTime -ge $freshCut)) { $lastFresh = $true }
    if ($passLine -and $lastFresh) { $gen2 = 'PASS'; Ok ('helper: ' + $passLine.Line.Trim()) }
    elseif ($passLine -and -not $freshCut) { Bad '读不到本次开机时间，无法确认 last.log 里的 PASS 是不是本次开机 → 按不通过处理（宁严不松）' }
    elseif ($passLine) { Bad ('last.log 里的 PASS 是**之前开机**的记录（文件时间 ' + (Get-Item $lastLog).LastWriteTime + '）→ 本次没有落地，别按 PASS 处理') }
    elseif ($exitLine -and $exitLine.Line -match 'EXIT=0') { Warn ('helper 进程退出码 0 但没打印 PASS 行，请人工核对: ' + $exitLine.Line.Trim()) }
    else { Bad 'helper 没到 PASS（见上面 last.log 行）' }
  } else { Bad 'last.log 不存在（开机任务没跑过 Gen2 落地）' }
  $pb = Join-Path $script:ProgDataWin 'logs\postbind.log'
  if (Test-Path $pb) {
    $tail = Get-Content -LiteralPath $pb | Select-Object -Last 6
    $tail | ForEach-Object { Info ('postbind: ' + $_) }
  }
  $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($t) {
    $ti = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Info ('开机任务上次运行: ' + $ti.LastRunTime + '  rc=0x' + ('{0:X}' -f $ti.LastTaskResult))
  }
  $t2 = Get-ScheduledTask -TaskName $script:TaskNameLogon -ErrorAction SilentlyContinue
  if ($t2) {
    $ti2 = Get-ScheduledTaskInfo -TaskName $script:TaskNameLogon -ErrorAction SilentlyContinue
    Info ('登录后补跑任务上次运行: ' + $ti2.LastRunTime + '  rc=0x' + ('{0:X}' -f $ti2.LastTaskResult))
  } else { Info ('登录后补跑任务 ' + $script:TaskNameLogon + ' 未注册') }
  $smi = Get-NvidiaSmi
  if ($smi) {
    $csv = (Invoke-Native { & $smi --query-gpu=name,vbios_version,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current --format=csv,noheader 2>&1 } | Out-String).Trim()
    Info ('nvidia-smi: ' + $csv + '  (注意: link.gen.current 会动态降速，不代表没解锁)')
  }
  Head '结论'
  if ($compute -eq 'PASS') { Say '  算力解锁 : PASS (SS0=0x88888888 SS1=0x8)' 'Green' } else { Say '  算力解锁 : FAIL' 'Red' }
  if ($gen2 -eq 'PASS') { Say '  PCIe Gen2: PASS (physical Gen2 x16)' 'Green' } else { Say '  PCIe Gen2: FAIL' 'Red' }
  # 2026-09-30：GSP 必须一起复核 —— 没开的话客户的卡就是"代码 43"，前面两项再好也没用
  $gspV = Get-GspState
  if ($gspV.State -eq 'on') { Say ('  GSP 固件 : PASS (' + $gspV.Value + ')') 'Green' }
  elseif ($gspV.State -eq 'off') { Say ('  GSP 固件 : FAIL —— 未启用（' + $gspV.Line + '）→ 设备管理器里 40HX 会是代码 43；跑 -Mode Repair 写开关，然后【完全关机】再开机') 'Red' }
  else { Say ('  GSP 固件 : 未知（' + $gspV.Line + '）') 'Yellow' }
  try {
    $hb = [string](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($hb -eq '1') { Say '  快速启动 : 开着（HiberbootEnabled=1）—— "关机"是混合关机、驱动不重载 → 跑 -Mode Repair 关掉' 'Red' } else { Say ('  快速启动 : 已关闭（HiberbootEnabled=' + $(if ($hb -eq '') { '未设置' } else { $hb }) + '）') 'Green' }
  } catch { }
  $gpuErr = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'DEV_1F0B' -and $_.Status -ne 'OK' })
  if ($gpuErr.Count -gt 0) {
    $pr = ''
    try { $pr = [string](Get-PnpDeviceProperty -InstanceId $gpuErr[0].InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data } catch { }
    Say ('  40HX 设备 : 异常 [' + $gpuErr[0].Status + '] Problem=' + $pr + $(if ($pr -eq '43') { '   ← 这就是客户说的"设备管理器 43"' } else { '' })) 'Red'
    if ($pr -eq '43') { Say '    处理顺序：① 确认 GSP 已启用 ② 完全关机（不是重启）再开机 ③ 仍 43 跑 -Mode Repair 后重复 ①②' 'Yellow' }
  } else { Say '  40HX 设备 : OK（没有代码 43）' 'Green' }
  # 2026-10-02（第 2 轮复审 B）：结论行必须与 $allGood/$liveOk（也就是退出码）同源，
  #   否则会出现同一屏“绿色 两全达成 + 退出码 1”这种自相矛盾。
  $allGood = ($compute -eq 'PASS' -and $gen2 -eq 'PASS' -and $gspV.State -eq 'on' -and $gpuErr.Count -eq 0)
  $liveOk = $false
  try { $liveOk = Test-LiveAllGood } catch { $liveOk = $false }
  if ($allGood -and $liveOk) { Say '  结论: 两全达成（算力满血 + Gen2 x16 + GSP 正常）' 'Green' }
  elseif ($allGood -and -not $liveOk) { Say '  结论: 判据显示两全，但“本次开机”的证据不齐（ESP 时间戳 / 开机任务 rc / GSP / 代码 43）→ 按未验证处理（退出码非 0，指引保留）' 'Yellow' }
  elseif ($compute -eq 'PASS' -and $gen2 -eq 'PASS') { Say '  结论: 算力+Gen2 已达成，但 GSP 这项要处理（否则设备管理器会显示代码 43）' 'Yellow' }
  # 2026-10-02（用户要求）：状态正常了就别再跳“下一步”指引 —— 顺手清掉上次留下的那个文件。
  #   2026-10-02（第三方审查 H）：删之前再用 Test-LiveAllGood 复核一遍“就是本次开机”的证据，
  #   避免历史日志被当成现状而把该留的指引删掉。
  $guidePath = Join-Path $script:PkgRoot '下一步-重启后看这里.txt'
  if ($allGood -and $liveOk) {
    if (Test-Path $guidePath) {
      try { Remove-Item -LiteralPath $guidePath -Force -ErrorAction Stop; Ok '状态正常 → 已移除旧的“下一步-重启后看这里.txt”（正常状态不需要它）' }
      catch { Warn ('清理“下一步”提示文件失败: ' + $_.Exception.Message) }
    } else { Info '没有遗留的“下一步”提示文件（状态正常，不需要它）' }
  } elseif ($allGood -and -not $liveOk) {
    Info '判据显示两全，但“本次开机”证据不齐（Test-LiveAllGood 未通过）→ 保留“下一步”提示文件不动'
  }
  # 供主流程决定退出码（-Mode Verify 不再无条件返回 0）
  $script:VerifyResult = @{ Compute = $compute; Gen2 = $gen2; Gsp = $gspV.State; GpuOk = ($gpuErr.Count -eq 0); AllPass = ($allGood -and $liveOk) }
}

# ================================================================ 卸载
function Invoke-Uninstall {
  param($BackupDir)
  Head '卸载'
  $espRoot = Mount-Esp
  if ($espRoot) {
    $bak = Join-Path $espRoot 'EFI\Boot\bootx64.efi.40hx.bak'
    if (Test-Path $bak) {
      Copy-Item -LiteralPath $bak -Destination (Join-Path $espRoot 'EFI\Boot\bootx64.efi') -Force
      Ok '已还原 \EFI\Boot\bootx64.efi（Windows 原始引导文件）'
    } else { Info '\EFI\Boot\bootx64.efi.40hx.bak 不存在，未还原' }
    $d1 = Join-Path $espRoot 'EFI\40HX'
    if (Test-Path $d1) { Remove-Item -LiteralPath $d1 -Recurse -Force; Ok '已删除 \EFI\40HX（解锁固件 + 驱动兜底源）' }
    Dismount-Esp
  }
  if (Initialize-FwAccess) {
    $entries = Get-AllBootEntries
    $unlock = Get-UnlockBootEntry $entries
    if ($unlock) {
      $index = $unlock.Index
      $name = $unlock.Name
      $order = @(Get-BootOrderIndices | Where-Object { $_ -ne $index })
      # 2026-10-01b（第三方审查 N4）：读不到 BootOrder 时也要如实说；写失败不能照样报"已移除"
      if (@(Get-BootOrderIndices).Count -eq 0) {
        Warn '读不到 BootOrder → 只删启动项、不动 BootOrder（重启后再跑一次卸载，把它从启动顺序里去掉）'
      } elseif ($order.Count -gt 0) {
        if (Write-BootOrderIndices -Indices $order -BackupDir $BackupDir) {
          Ok ('BootOrder 已移除 ' + ('{0:X4}' -f $index) + '（原顺序已备份）')
        } else {
          Warn ('BootOrder 没改成功 —— 顺序里可能还留着 ' + ('{0:X4}' -f $index) + '（重启后再跑一次卸载，或进 BIOS 删掉它）')
        }
      }
      Remove-FwVar $name | Out-Null
      if (-not (Read-FwVar $name)) { Ok ('已删除固件启动项 ' + $name) } else { Warn ('固件启动项 ' + $name + ' 删不掉') }
    } else { Info '没有找到解锁启动项' }
    if (Read-FwVar 'BootNext') { Remove-FwVar 'BootNext' | Out-Null; Ok '已清掉 BootNext' }
  }
  foreach ($tn in @($script:TaskName, $script:TaskNameLogon)) {
    if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
      Invoke-Native { schtasks /delete /tn $tn /f 2>&1 | Out-Null }
    }
    if (-not (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue)) { Ok ('已删除任务 ' + $tn) }
  }
  foreach ($d in $script:Drivers) {
    Invoke-Native { sc.exe stop $d.Service 2>&1 | Out-Null }
    Invoke-Native { sc.exe delete $d.Service 2>&1 | Out-Null }
    foreach ($p in @((Join-Path $script:SysDrv $d.Name), (Join-Path $script:ProgDataDrv $d.Name), (Join-Path $script:VendorDrvDir $d.Name))) {
      if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
    Ok ("已删除服务与驱动: " + $d.Service)
  }
  foreach ($f in $script:InpoutFiles) {
    foreach ($p in @((Join-Path $script:SysDrv $f.Name), (Join-Path $script:ProgDataDrv $f.Name), (Join-Path $script:VendorDrvDir $f.Name))) {
      if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
    Ok ("已删除新路径驱动文件: " + $f.Name + "（新路径工具 40hx-retrain-inpout.ps1 在 " + $script:ProgDataWin + "，要一并删就加 -Purge）")
  }
  Invoke-Native { sc.exe stop inpoutx64T 2>&1 | Out-Null }
  Invoke-Native { sc.exe delete inpoutx64T 2>&1 | Out-Null }
  if ($Purge) {
    if (Test-Path $script:ProgDataRoot) { Remove-Item -LiteralPath $script:ProgDataRoot -Recurse -Force -ErrorAction SilentlyContinue; Ok ('已删除 ' + $script:ProgDataRoot) }
  } else { Info ('保留 ' + $script:ProgDataRoot + '（要一起删就加 -Purge）') }
  # 2026-10-01b（审查 H10）：把安装时加的 Defender 排除项一并撤掉
  try {
    Remove-MpPreference -ExclusionPath $script:ProgDataRoot -ErrorAction SilentlyContinue
    Remove-MpPreference -ExclusionProcess 'CMP40HXGen2.exe' -ErrorAction SilentlyContinue
    Ok '已撤销 Defender 排除项（CMP40HXGen2）'
  } catch { Info '撤 Defender 排除项跳过（未启用或无权限）' }
  if (Test-Path $script:StateFile) { Remove-Item -LiteralPath $script:StateFile -Force }
  Say ''
  # 2026-10-01b（第三方审查 H10）：如实说明哪些没还原（原来文档/输出都说"全部撤销"，是过度承诺）
  Say '注：下面这些**不会**自动还原（都不影响使用，想要回到改之前请手工改）：' 'Yellow'
  Say '  · 显示类子键 EnableGpuFirmware=1（GSP 开关；留着无害，想关就删掉该值）' 'Gray'
  Say '  · HiberbootEnabled=0（快速启动关着；控制面板→电源选项→选择电源按钮功能→启用快速启动 可开回）' 'Gray'
  Say '  · HKLM\SOFTWARE\40HXUnlock 的策略键（本包写 0 = 永不复位显卡，无害）' 'Gray'
  Say '  · HKCU\...\Run 里被改名的 40HXGen2_parked（改回 40HXGen2 即恢复厂商登录自启）' 'Gray'
  Say '  · 被本包禁用的厂商计划任务（任务计划程序里手动启用）' 'Gray'
  Say '  · ProgramData\CMP40HXGen2 下我们加过的目录权限（要恢复继承：icacls "<目录>" /inheritance:e /T /C）' 'Gray'
  Say ''
  $gp = Join-Path $script:PkgRoot '下一步-重启后看这里.txt'
  if (Test-Path $gp) {
    Remove-Item -LiteralPath $gp -Force -ErrorAction SilentlyContinue
    # 2026-10-02（第三方审查）：删不掉就别报“已移除”（例如被记事本占着）
    if (Test-Path $gp) { Warn '“下一步-重启后看这里.txt”没删掉（可能正被记事本打开）—— 关掉它再删即可' }
    else { Ok '已移除“下一步-重启后看这里.txt”（卸载后不再需要）' }
  }
  Say '卸载完成：重启后就是原生（未解锁）状态。' 'Yellow'
}

# ================================================================ 主流程
$isAdmin = Test-Admin
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
$script:LogPath = Join-Path $script:LogDir ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $Mode + '.log')
# 2026-10-02（第三方审查）：瘦身要在**所有模式**都做（技师最常跑的就是 Check/Verify，它们也会各写一份日志）
Info '日志/备份瘦身：只保留最近 10 份运行日志与空备份目录的清理'
Invoke-Retention

Say ''
Say '################################################################'
Say ('#  CMP 40HX 算力解锁 + PCIe Gen2  一键脚本   Mode=' + $Mode) 'Cyan'
Say ('#  包目录: ' + $script:PkgRoot) 'Cyan'
Say ('#  时间  : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   管理员: ' + $isAdmin) 'Cyan'
Say '################################################################'

if (-not $isAdmin -and $Mode -ne 'Check' -and $Mode -ne 'StorageDiag') {
  Fail '这个模式需要管理员权限：请右键“以管理员身份运行”一键安装.cmd（或 Start-Process powershell -Verb RunAs）' $script:ExitPrereq '双击 一键安装.cmd 会自动提权；直接右键 Install-40HXUnlock.ps1 →「使用 PowerShell 运行」不会提权'
}

if ($Mode -eq 'Check') {
  $rep = Get-CheckReport
  Show-Check $rep
  Say ''
  if ($script:FailCount -eq 0 -and $script:WarnCount -eq 0) { Say '体检完成：没有发现问题，可以跑 Install。' 'Green' }
  else { Say ('体检完成：' + $script:FailCount + ' 项失败、' + $script:WarnCount + ' 条提示（见上面 [失败]/[提示]）。') $(if ($script:FailCount -eq 0) { 'Yellow' } else { 'Red' }) }
  Say ('日志: ' + $script:LogPath)
  # 2026-10-02（第三方审查）：Check 有失败项时不再返回 0（脚本化调用也能判失败）
  if ($script:FailCount -gt 0) { Exit-With $script:ExitFail } else { Exit-With $script:ExitOk }
}

if ($Mode -eq 'StorageDiag') {
  Invoke-StorageDiag
  Say ('日志: ' + $script:LogPath)
  if ($script:FailCount -gt 0) { Exit-With $script:ExitFail } else { Exit-With $script:ExitOk }
}

if ($Mode -eq 'SelfTest') {
  $bk = New-BackupFolder
  Invoke-SelfTest -BackupDir $bk
  Say ('备份/存证目录: ' + $bk)
  Say ('日志: ' + $script:LogPath)
  if ($script:SelfTestProblems -eq 0) { Exit-With $script:ExitOk } else { Exit-With $script:ExitFail }
}

if ($Mode -eq 'Verify') {
  Invoke-Verify
  Say ('日志: ' + $script:LogPath)
  # 2026-10-02（第三方审查）：Verify 不再无条件返回 0 —— 没到“两全”就返回失败码
  if ($script:VerifyResult -and $script:VerifyResult.AllPass) { Exit-With $script:ExitOk } else { Exit-With $script:ExitFail }
}

if ($Mode -eq 'Uninstall') {
  if (-not $Yes) { Fail '卸载会删启动项/任务/服务/驱动，确认请加 -Yes' $script:ExitPrereq '加 -Yes 即可；卸载后要重启才回到原生状态（解锁是开机时由 EFI 写寄存器实现的）' }
  $bk = New-BackupFolder
  Invoke-Uninstall -BackupDir $bk
  Say ('日志: ' + $script:LogPath)
  Exit-With $script:ExitOk
}

if ($Mode -eq 'MakeDefault') {
  if (-not (Initialize-FwAccess)) { Fail '固件变量权限失败' $script:ExitNvram '必须管理员；安全软件的启动项保护会拦固件变量写入' }
  $entries = Get-AllBootEntries
  $unlock = Get-UnlockBootEntry $entries
  if (-not $unlock) { Fail '没有找到 "40HX Unlock" 启动项，先跑 -Mode Install' $script:ExitNvram '这台机器本来就没装过（或已被卸载）→ 不需要卸载；想清理驱动/任务可以跑 -Mode Uninstall -Yes 或直接删 %ProgramData%\CMP40HXGen2' }
  $bk = New-BackupFolder
  # 2026-10-01b（第三方审查 D2 旁路 B）：先确认"这一次读到的是有效值"再组装 —— 否则第一次读失败（空）
  #   会让 $order 退化成只含解锁项 1 个元素，而 Write-BootOrderIndices 内部会**再读一次**（这次可能成功）
  #   → 校验通过 → 写成单元素 BootOrder，Windows Boot Manager 等全丢。
  $curOrder = @(Get-BootOrderIndices)
  if ($curOrder.Count -eq 0) {
    Fail '读不到 BootOrder（固件变量读取失败）→ 拒绝改写' $script:ExitNvram '重启后再跑一次；或进 BIOS 把 "40HX Unlock" 手动设为第一启动项（启动项已经建好了）'
  }
  $order = @($unlock.Index) + @($curOrder | Where-Object { $_ -ne $unlock.Index })
  if (Write-BootOrderIndices -Indices $order -BackupDir $bk) {
    Ok ('BootOrder = ' + (Format-BootOrderIndices (Get-BootOrderIndices)) + '（"40HX Unlock" 已排第一）')
  } else { Fail 'BootOrder 写入失败' $script:ExitNvram '先关安全软件的启动项保护；或进 BIOS 把「40HX Unlock」手工排到第一位（脚本已把启动项建好）' }
  Say ('日志: ' + $script:LogPath)
  Exit-With $script:ExitOk
}

# ---- Install / Repair -------------------------------------------------
$rep = Get-CheckReport
Show-Check $rep -FromInstall

Head '计划'
if ($Mode -eq 'Install') { Info '安装/修复：驱动+服务 → helper(含新路径工具) → 新路径驱动(inpoutx64) → 安全加固(目录权限 + 驱动源 base64) → GSP 开关 → 关快速启动 → ESP 固件 → 固件启动项 → 开机任务 → 厂商自启收尾' } else { Info 'Repair：只补驱动/服务/helper/新路径驱动/任务/安全加固，不动 ESP 与固件启动项' }

$blockers = 0
if ($rep.Firmware -ne 'Uefi') { Bad '固件不是 UEFI 模式'; $blockers++ }
# 2026-10-08：只有「真读出 MBR」才算硬门槛；读不到（未知）降级为提示 —— 客户机实测 diskpart 里全是 GPT，
#   只是 Storage 接口坏了，旧版会把这种机器直接挡在门外。但**挂不上 ESP 的机器**（真 MBR / 非 UEFI 引导）
#   仍然必须在动手改任何东西之前停住（DSH 审查 Q4：否则会先落 6 步改动、到 ESP 那步才失败，留半成品）。
if ($rep.DiskStyle -eq 'MBR' -and $rep.DiskStyleConfirmed) { Bad '系统盘不是 GPT（MBR）'; $blockers++ }
elseif ($rep.DiskStyle -ne 'GPT') {
  Warn ('系统盘分区样式读不到（' + $rep.DiskStyle + '）—— 不等于 MBR 盘；本次先继续（后面的 ESP/固件启动项会再核一遍）')
  Info ('判定来源: ' + $(if ($rep.DiskStyleSource) { $rep.DiskStyleSource } else { '所有后端都失败（逐条见下）' }))
  Show-StorageDiag
  Add-Action '系统盘分区样式读不到：把上面的「存储信息诊断」和本次 run-*.log 发给作者（原因就在里面）'
  if (Test-EspPrecheckBlocked $rep) {
    # 2026-10-08（DSH 第二轮审查）：措辞收敛 —— 只读预检能证明"挂不上 ESP"，但挂不上的原因可能是
    #   ① 真 MBR/BIOS 引导，也可能是 ② ESP 被安全软件/已有挂载点挡着。不要断言成 ①。
    Bad '取不到 EFI 系统分区（ESP）—— 引导模式或 ESP 挂载有问题，本次**还没有做任何改动**'
    $blockers++
    Add-Action '先分两条查：① 这台机器是不是 UEFI+GPT 引导（真 MBR 盘用 mbr2gpt /convert /allowFullOS 转换，并在 BIOS 关 CSM；盘里没数据的话直接重装成 GPT 更快）；② ESP 是不是被安全软件/别的东西占着挂不上（管理员下手动 mountvol Y: /S 试，或双击 工具-测试与修复\存储体检.cmd 取证）'
  }
}
if ($rep.SecureBoot -eq $true) { Bad 'Secure Boot 开着'; $blockers++ }
if ($rep.BitLocker -match 'On|1') { Bad 'BitLocker 开着（会索要恢复密钥）'; $blockers++ }
if ($rep.Target.Count -eq 0) { Bad '没找到 CMP 40HX (DEV_1F0B)'; $blockers++ }
if ($blockers -gt 0) {
  if ($Force) { Warn ('有 ' + $blockers + ' 项前提不满足，但 -Force 已指定 → 继续') }
  else { Fail ('有 ' + $blockers + ' 项前提不满足，先处理后重跑；确认要继续就加 -Force') $script:ExitPrereq '按上面 [失败] 行逐条处理：Secure Boot→BIOS 关；BitLocker→暂停/解密；MBR 盘→mbr2gpt；显卡没识别→插紧/装 NVIDIA 驱动；不是 UEFI→BIOS 关 CSM' }
}

Head '改动清单与风险（出事怎么办，都写在下面）'
Info '这次会改的东西（每项都有备份或回滚办法）：'
Info '  1. 驱动/服务      ：写 System32\drivers 下 3 个驱动 + 建/纠正对应服务（只动文件与服务，不改系统安全策略）'
Info '  2. 开机任务      ：注册 CMP40HX Gen2 PostBind（开机）与 CMP40HX Gen2 PostBind Logon（登录后 60 秒补跑）'
Info '  3. 注册表        ：显示类子键 EnableGpuFirmware=1（GSP）、关快速启动、HKLM\SOFTWARE\40HXUnlock 两个策略键'
Info '  4. 目录权限      ：把 CMP40HXGen2 与 40HXUnlock 收紧到只剩 SYSTEM/Administrators 可写（有 ACL 备份）'
Info '  5. 驱动源形态    ：ProgramData 两处的裸 .sys/.dll 转成 base64 文本（先逐字节校验，通过才删裸文件）'
Info '  6. Install 还有  ：把解锁固件写进 ESP（\EFI\40HX\40HXUNLK.EFI）+ 写固件启动项 Boot####/BootOrder（默认**不改** Windows 的 \EFI\Boot\bootx64.efi）'
Info '已知风险与恢复：'
Info '  · 改引导（只有 Install 会） 最坏=写坏启动顺序 → 进 BIOS 把启动项切回 Windows Boot Manager（本包默认不碰 Windows 的 bootx64.efi，所以进系统这条路一直在）'
Info '  · ACE-BOOT（腾讯反作弊）  只在必要时停、结束就恢复；若客户点过"退出预启动模式"，恢复可能让桌面起不来 → 跑 工具-测试与修复\桌面恢复.cmd（没桌面也能跑）'
Info '  · 驱动被杀软隔离（火绒/360）  症状=Gen2 落不了地、算力不受影响 → 把 README 1.1 的路径加信任区后跑 -Mode Repair'
Info '  · 显卡被复位  本包 Gen2AutoHard=0 / Gen2PnpFallback=0，绝不复位显卡；万一出现代码 43 → 完全关机（不是重启）再开机'
Info '  · 目录权限/驱动源改动  零功能影响；要退回双击 工具-测试与修复\回滚-安全加固.cmd'
Info '  · 主要撤销项  powershell -ExecutionPolicy Bypass -File 本目录\Install-40HXUnlock.ps1 -Mode Uninstall -Yes（卸载后仍会留几项不影响使用的东西，见上面"不会自动还原"清单）'
Info '详见包内 排查指引.md 与 文档\风险与恢复.md；本次日志：'
Info ('  ' + $script:LogPath)
Info ''
$bk = New-BackupFolder
Install-DriverFiles -BackupDir $bk
Install-WindowsFiles
Install-InpoutFiles -BackupDir $bk
Install-Hardening
Install-Gsp
Install-Power
if ($Mode -eq 'Install') {
  Install-Efi -BackupDir $bk
  Install-BootEntry -BackupDir $bk -BootMode $BootMode
} else { Info 'Repair 模式：跳过 ESP 固件与固件启动项' }
Install-Task
# 2026-10-04（用户要求：**按需触发**）：只有在 GSP 没启用（off / unknown）时才跑体检 ——
#   状态正常（已启用）就保持安静，不多花时间、不刷屏；判断用安装器自己的 Get-GspState（与 Install-Gsp 同一判据）。
if ($Mode -eq 'Install' -or $Mode -eq 'Repair') {
  # 2026-10-04（审查 L5）：复用 Install-Gsp 刚取到的状态，避免同一次安装里把 nvidia-smi -q 跑第三遍
  $gspNow = if ($script:GspStateBeforeInstall) { $script:GspStateBeforeInstall } else { Get-GspState }
  if ($gspNow.State -ne 'on') {
    Info ('GSP 当前状态 = ' + $gspNow.State + $(if ($gspNow.Line) { '（' + $gspNow.Line + '）' } else { '' }) + ' → 跑一次只读体检帮助定位')
    # 2026-10-04（审查 M1）：先说清预期 —— 本次刚写入开关时，冷启动前这里必然显示未启用，属正常
    Info '（若本次刚写入开关：冷启动前体检必然显示"未启用" —— 这是正常的；先完全关机再开机，开机后跑 -Mode Verify 复核即可）'
    Invoke-GspHealthCheck
  } else {
    Info ('GSP 已启用（' + $gspNow.Value + '）→ 跳过 GSP 体检（保持安静）')
  }
}

if ($RunNow) {
  Head '立刻跑一次开机任务（验证端到端）'
  Invoke-Native { schtasks /run /tn $script:TaskName 2>&1 | Out-Null }
  for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Seconds 5
    $ti = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($ti -and $ti.LastTaskResult -ne 267009) { break }
  }
  $ti = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction SilentlyContinue
  Info ('任务结果 rc=0x' + ('{0:X}' -f $ti.LastTaskResult) + '  上次运行 ' + $ti.LastRunTime)
  $lastLog = Join-Path $script:ProgDataWin 'logs\last.log'
  if (Test-Path $lastLog) {
    (Get-Content -LiteralPath $lastLog | Select-String -Pattern 'GUARD=|PASS:|ERROR|EXIT=') | ForEach-Object { Info ('helper: ' + $_.Line.Trim()) }
  }
  $pb = Join-Path $script:ProgDataWin 'logs\postbind.log'
  if (Test-Path $pb) {
    (Get-Content -LiteralPath $pb | Select-Object -Last 6) | ForEach-Object { Info ('postbind: ' + $_) }
    $np = (Get-Content -LiteralPath $pb | Select-String -Pattern 'PASS:\s*Gen2 reached on the new path' | Select-Object -Last 1)
    if ($np) { Ok '开机任务本次走的是新路径并且 PASS（ACE-BOOT 全程没被停）' }
  }
  if ($ti.LastTaskResult -eq 0) { Ok '开机任务端到端 PASS' }
  else {
    Warn ('开机任务退出码非 0（如果本次开机还没解锁算力，属正常：解锁要等重启后 EFI 生效）')
    Add-Action '开机任务这次没成功（rc≠0）：看 postbind.log；若是 ACE 相关看 排查指引.md 第 2.3 节，驱动/服务相关看第 6 节'
  }
  if (Test-Path $pb) {
    if ((Get-Content -LiteralPath $pb | Select-String 'ACE WARN') ) { Add-Action '日志里有 ACE WARN：ACE 这次没被停干净（或机器上有其它反作弊）。重启后若 Gen2 没落地，先看 排查指引.md 第 2.3 节' }
  }
}

Head '完成 / 下一步'
Say ('  备份目录: ' + $bk) 'Cyan'
Say ('  日志    : ' + $script:LogPath) 'Cyan'
Say ''
if ($script:FailCount -eq 0) { Say ('安装步骤全部成功（' + $script:WarnCount + ' 条提示不影响功能）。') 'Green' }
else { Say ('安装结束：' + $script:FailCount + ' 项失败、' + $script:WarnCount + ' 条提示，请往上翻看。') 'Red' }
Say ''
Say '  ============================================================' 'Yellow'
Say '   ★  现 在 请 完 全 关 机 再 开 机 （必须，不是"重启"）' 'Yellow'
Say '  ============================================================' 'Yellow'
Say '   为什么必须关机再开：算力解锁是"每次开机由 ESP 上的解锁固件写 GPU 寄存器"实现的。' 'Yellow'
Say '   ★ 必须是【完全关机】（开始菜单→关机，最好拔电 10 秒再开）——"重启"清不掉显卡残留状态，' 'Yellow'
Say '     而残留+GSP/链路状态不对就会表现成"开机黑屏一段时间 + 设备管理器代码 43"。' 'Yellow'
Say '   （本次已经跑过一遍开机任务，所以 Gen2 可能已经生效；但算力一定得等关机再开。）' 'Yellow'
Say '   开机后第一次进系统可能比平时慢几秒：先跑解锁固件，再 chainload 回 Windows，属正常。' 'Yellow'
Say ''
Say '   开机后怎么确认（三选一，另外务必看一眼设备管理器里 40HX 有没有代码 43）：' 'Yellow'
Say '     a) 双击本包目录里的 状态自检.bat          → 看到"全绿 -- WDDM + PCIe Gen2 + 算力满血"即成功' 'Yellow'
Say ('     b) powershell -ExecutionPolicy Bypass -File "' + (Join-Path $script:PkgRoot 'Install-40HXUnlock.ps1') + '" -Mode Verify') 'Yellow'
Say '     c) 看 ESP 里的 40hx_log.txt 时间戳是不是本次开机（有 *** UNLOCKED *** 行）' 'Yellow'
if ($script:PendingDriverRetry) {
  Warn '有驱动文件因为“正被占用”被跳过写入（驱动还在跑 / 停在 STOP_PENDING 时必然如此）——不致命'
  Add-Action '驱动文件被占用跳过了：完全关机再开机一次（开机任务会自动从 ESP 兜底源补齐），然后再跑一次 -Mode Verify 确认'
}
Say ''
if ($script:ActionItems.Count -gt 0) {
  Say '   重启前请先处理这几项（本次跑出来的待办）：' 'Red'
  foreach ($item in $script:ActionItems) { Say ('     - ' + $item) 'Red' }
} else {
  Say '   没有需要你额外处理的事项（杀软、GSP、驱动、任务都正常）。' 'Green'
}
Say ''
Say '   若开机后没效果：别乱试，打开 排查指引.md 按日志原话搜；黑屏/代码 43 见第 5 节与第 5.1 节（GSP）。' 'Yellow'
Say '   若开机没进 "40HX Unlock"（看 40hx_log.txt 时间不是本次开机）：进 BIOS 启动项手动选它一次；' 'Yellow'
Say '   解锁固件在 \EFI\40HX\40HXUNLK.EFI，用一个自建的固件启动项（Boot####）指向它；默认不动 Windows 自己的 \EFI\Boot\bootx64.efi。' 'Yellow'
Say ''
Say ('  回滚：powershell -ExecutionPolicy Bypass -File "' + (Join-Path $script:PkgRoot 'Install-40HXUnlock.ps1') + '" -Mode Uninstall -Yes') 'Gray'

# 控制台关掉后还能看：把“下一步”写成文件放包目录 —— 但只在“真的需要你动手”时写。
# 2026-10-02（用户要求：状态正常就别再跳指引）：只在“真的需要你动手”时写这个文件：
#   ① 有失败项（FailCount>0），或 ② 本次开机还没验证过两全（首装/刚改过 EFI，必须冷启动才算数）。
#   只有“提示类待办”（比如杀软信任区提醒）且现场已经验证两全时 → 不再写文件，
#   那些提示照样打在控制台并记进本次 run-*.log，不丢信息（别把“安静”做成“哑巴”）。
$guidePath = Join-Path $script:PkgRoot '下一步-重启后看这里.txt'
$liveOk = Test-LiveAllGood
if ($script:FailCount -eq 0 -and $liveOk) {
  if (Test-Path $guidePath) {
    try { Remove-Item -LiteralPath $guidePath -Force -ErrorAction Stop; Say '  状态正常（本次开机已解锁 + Gen2 已到位 + GSP 正常）→ 已移除“下一步-重启后看这里.txt”，不留指引。' 'Green' }
    catch { Warn ('清理“下一步”提示文件失败: ' + $_.Exception.Message) }
  } else { Say '  状态正常 → 不需要“下一步”指引（不会生成该文件）。' 'Green' }
  if ($script:ActionItems.Count -gt 0) { Say ('  （下面这些只是提示，不影响功能，也已记进本次日志）: ' + ($script:ActionItems -join ' / ')) 'Gray' }
} else {
try {
  $nl = New-Object System.Collections.ArrayList
  [void]$nl.Add('CMP 40HX 安装完成 —— 下一步（' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '，模式 ' + $Mode + '）')
  [void]$nl.Add('')
  [void]$nl.Add('★ 必须【完全关机】再开机（不是"重启"）：算力解锁靠每次开机的解锁固件生效；')
  [void]$nl.Add('  "重启"清不掉显卡残留状态，残留状态不对 = 开机黑屏一段时间 + 设备管理器代码 43。')
  [void]$nl.Add('  做法：开始菜单→关机，最好拔电 10 秒再开机。')
  [void]$nl.Add('')
  [void]$nl.Add('开机后确认（三选一，另看一眼设备管理器 40HX 有没有代码 43）：')
  [void]$nl.Add('  a) 双击本目录的 状态自检.bat   → 看到"全绿 -- WDDM + PCIe Gen2 + 算力满血"即成功')
  [void]$nl.Add('  b) powershell -ExecutionPolicy Bypass -File "' + (Join-Path $script:PkgRoot 'Install-40HXUnlock.ps1') + '" -Mode Verify   （会一并复核 GSP / 代码 43）')
  [void]$nl.Add('  c) 看 ESP 里 40hx_log.txt 的时间戳是不是本次开机（应有 *** UNLOCKED (SS0=0x88888888 SS1=0x8) ***）')
  [void]$nl.Add('')
  if ($script:ActionItems.Count -gt 0) {
    [void]$nl.Add('重启前请先处理：')
    foreach ($item in $script:ActionItems) { [void]$nl.Add('  - ' + $item) }
  } else { [void]$nl.Add('没有需要额外处理的事项。') }
  [void]$nl.Add('')
  # 2026-09-30 修 BUG：int + '字符串' 在 PS 里会尝试把右边转成 int → 抛「无法将值"项失败"转换为类型"System.Int32"」，
  # 结果只有"安装有失败项"时才会踩到（本机一直 0 失败所以从没暴露）→ 必须先 [string] 转换
  $res = if ($script:FailCount -eq 0) { '步骤全部成功' } else { ([string]$script:FailCount + ' 项失败') }
  [void]$nl.Add('本次结果：' + $res + '；' + $script:WarnCount + ' 条提示')
  [void]$nl.Add('本次日志：' + $script:LogPath)
  [void]$nl.Add('出问题看：' + (Join-Path $script:PkgRoot '排查指引.md'))
  [void]$nl.Add('回滚命令：powershell -ExecutionPolicy Bypass -File "' + (Join-Path $script:PkgRoot 'Install-40HXUnlock.ps1') + '" -Mode Uninstall -Yes')
  [IO.File]::WriteAllLines((Join-Path $script:PkgRoot '下一步-重启后看这里.txt'), $nl, (New-Object System.Text.UTF8Encoding($true)))
  Say ('  已写出下一步提示（控制台关了也能看）: ' + $guidePath) 'Cyan'
} catch { Warn ('写“下一步”提示文件失败: ' + $_.Exception.Message) }
}
if ($script:FailCount -eq 0) { Exit-With $script:ExitOk } else { Exit-With $script:ExitFail }
