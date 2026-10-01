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
             → \EFI\40HX\40HXUNLK.EFI 与 \EFI\Boot\bootx64.efi（原文件备份 .40hx.bak）
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

  模式（-Mode）：
    Check       只体检，不写任何东西（可非管理员运行，仅少 ESP/NVRAM 部分）
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
  [ValidateSet('Check','Install','Repair','Verify','SelfTest','MakeDefault','Uninstall')]
  [string]$Mode = 'Check',

  # 固件启动项怎么处理：default=放进 BootOrder 第一位（推荐，配合 chainload 安全）
  #                     next=只设 BootNext 一次性试跑  none=只写变量不动顺序
  [ValidateSet('default','next','none')]
  [string]$BootMode = 'default',

  [switch]$Force,        # 忽略前提硬门槛（Secure Boot / MBR / BitLocker）
  [switch]$RunNow,       # Install/Repair 结束后立刻跑一次开机任务（要求本次开机已解锁）
  [switch]$Yes,          # Uninstall 确认
  [switch]$KeepBootx64,  # 不覆盖 ESP 的 \EFI\Boot\bootx64.efi（只写 \EFI\40HX\40HXUNLK.EFI）
  [switch]$Purge         # Uninstall 时连 %ProgramData%\CMP40HXGen2 一起删
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

# 2026-09-30（客户机实测）：驱动文件“正由另一进程使用”时 [IO.File]::WriteAllBytes 抛异常，
# 而全局 $ErrorActionPreference='Stop' 会把整个安装/修复**直接打断**（客户机 21:48 那次就是死在这里）。
# 策略：① 目标文件哈希已相同 → 直接跳过写入（最常见：内容本来就一样）② 写失败先 sc stop 再重试一次
#       ③ 仍失败 → 记一条提示 + 标记待补齐，**不致命**；完全关机再开机后由开机任务从 ESP 兜底源补齐。
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
  if ($script:EspRoot) { Invoke-Native { mountvol $script:EspRoot /D 2>&1 | Out-Null }; $script:EspRoot = $null }
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
  if ($cands.Count -eq 0) { return $null }
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
  if ($BackupDir) {
    $cur = Read-FwVar 'BootOrder'
    if ($cur) { [IO.File]::WriteAllBytes((Join-Path $BackupDir 'BootOrder.before.bin'), $cur) }
  }
  $bytes = New-Object System.Collections.Generic.List[byte]
  foreach ($idx in $Indices) { $bytes.AddRange([BitConverter]::GetBytes([uint16]$idx)) }
  return (Write-FwVar 'BootOrder' $bytes.ToArray())
}

function Format-BootOrderIndices { param([int[]]$Indices) return (($Indices | ForEach-Object { '{0:X4}' -f $_ }) -join ',') }

# ================================================================ 体检
function Get-CheckReport {
  $r = [ordered]@{}
  $r.Admin = Test-Admin
  try { $r.Firmware = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType } catch { $r.Firmware = '未知' }
  try { $r.SecureBoot = (Confirm-SecureBootUEFI) } catch { $r.SecureBoot = '未知' }
  try {
    $sysPart = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
    $disk = Get-Disk -Number $sysPart.DiskNumber -ErrorAction Stop
    $r.DiskStyle = $disk.PartitionStyle
  } catch { $r.DiskStyle = '未知' }
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
  if ($Report.DiskStyle -eq 'GPT') { Ok ("系统盘分区 : GPT") } else { Bad ("系统盘分区 : " + $Report.DiskStyle + " —— 必须是 GPT") }
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
      if ($txt -match 'UNLOCKED \(SS0=0x88888888 SS1=0x8\)') { Ok ("40hx_log.txt: 本次开机解锁成功 *** UNLOCKED (SS0=0x88888888 SS1=0x8) ***  (" + (Get-Item $log).LastWriteTime + ")") }
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
    if ($pass) { Ok ("helper: " + $pass.Line.Trim()) } elseif ($exit) { Warn ("helper: " + $exit.Line.Trim()) }
    Info ("last.log 时间: " + (Get-Item $lastLog).LastWriteTime)
  } else { Info 'last.log 不存在（旧路径没跑过；新路径只写 postbind.log + retrain-inpout.log，属正常）' }
  $pbLog = Join-Path $script:ProgDataWin 'logs\postbind.log'
  if (Test-Path $pbLog) {
    (Get-Content -LiteralPath $pbLog | Select-Object -Last 4) | ForEach-Object { Info ('postbind: ' + $_) }
  } else { Info 'postbind.log 不存在（开机任务还没跑过）' }
  $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($t) {
    $ti = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($ti.LastTaskResult -eq 267011) { Ok ("开机任务 " + $script:TaskName + " 已注册（还没跑过 —— 刚注册或被重装过，重启/运行一次就有了）") }
    else { Ok ("开机任务 " + $script:TaskName + " 已注册, 上次 " + $ti.LastRunTime + " rc=0x" + ('{0:X}' -f $ti.LastTaskResult)) }
  } else { Info ("开机任务 " + $script:TaskName + " 未注册") }
}

# ================================================================ 安装各部件
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
  foreach ($f in @('CMP40HXGen2.exe', 'AutoRetrain.cmd', 'Status.cmd', 'Uninstall_Auto.cmd', 'ACE-Toggle.ps1', '40hx-retrain-inpout.ps1')) {
    $s = Join-Path $src $f
    if (-not (Test-Path $s)) { Fail ("载荷缺失: " + $s) $script:ExitHash '包不完整 → 重新解压一份完整包（payload 目录必须跟脚本在一起）' }
    Copy-WithVerify $s (Join-Path $script:ProgDataWin $f) | Out-Null
    Ok ($f + " → " + $script:ProgDataWin)
  }
  foreach ($sub in @('logs', 'state')) {
    $p = Join-Path $script:ProgDataWin $sub
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  }
  # RunPostBind.cmd：沿用已验证的逻辑，只把“驱动自愈源列表”换成这台机器的实际路径
  # （原编码原样写回：上游这份是 UTF-8，被当 GBK 读回写会把中文注释改坏）
  $tplPath = Join-Path $src 'RunPostBind.cmd'
  $read = Read-TextAutoDetect $tplPath
  $text = $read.Text
  Info ('RunPostBind.cmd 模板编码: ' + $read.Encoding.WebName)
  $sourceList = '"' + $script:ProgDataDrv + '" "' + $script:VendorDrvDir + '"'
  $newLine = 'for %%S in (' + $sourceList + ') do ('
  # 注意 CRLF：用 lookahead 匹配行尾，避免把 \r 吃掉（.NET 的 (?m)$ 匹配在 \n 之前）
  $replaced = $text -replace '(?m)^for %%S in \(.*\) do \((?=\r?$)', $newLine
  if ($replaced -eq $text) {
    # 幂等：包里的模板本来就写着本机路径 → 内容没变是正常的。
    # 只有连“本机路径那一行”都找不到，才算真的没替换成功（旧版在这里一律报失败，会让 -Mode Repair 的退出码变成 1）
    $alreadyLocal = $text -match ('(?m)^for %%S in \(' + [regex]::Escape($sourceList) + '\) do \(')
    if ($alreadyLocal) { Ok 'RunPostBind.cmd 驱动自愈源本来就是这个本机路径（无需改动）' }
    else { Bad 'RunPostBind.cmd 的驱动源行没替换成功（保持原样），请检查载荷是否被改动'; Add-Action 'RunPostBind.cmd 的驱动自愈源没按本机路径重写：把包内 payload\windows\RunPostBind.cmd 手工拷到 C:\ProgramData\CMP40HXGen2\windows\ 并改那行 for %%S' }
  }
  else {
    $chk = ([regex]::Matches($replaced, [regex]::Escape($script:ProgDataDrv))).Count
    if ($chk -ge 1) { Ok ('RunPostBind.cmd 驱动自愈源已按本机路径重写（含 ' + $script:ProgDataDrv + '）') } else { Bad 'RunPostBind.cmd 重写后没找到本机自愈源路径' }
  }
  [IO.File]::WriteAllText((Join-Path $script:ProgDataWin 'RunPostBind.cmd'), $replaced, $read.Encoding)
  Ok ('RunPostBind.cmd → ' + $script:ProgDataWin + '（首选新路径 + 旧 ACE 路径 fallback + 多源自愈 + 3 次重试）')
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

  $targets = @((Join-Path $espRoot 'EFI\40HX\40HXUNLK.EFI'))
  if (-not $KeepBootx64) { $targets += (Join-Path $espRoot 'EFI\Boot\bootx64.efi') }
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
    if (-not $readback) { Fail ('回读 ' + $name + ' 失败') $script:ExitNvram '有的主板对某些 Boot 槽位行为异常 → 重跑一次，或直接进 BIOS 手动选启动项（\EFI\Boot\bootx64.efi 已兜底）' }
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
    } else {
      $newOrder = @($index) + @($order | Where-Object { $_ -ne $index })
      if (Write-BootOrderIndices -Indices $newOrder -BackupDir $BackupDir) {
        $rb = Get-BootOrderIndices
        if ((Format-BootOrderIndices $rb) -eq (Format-BootOrderIndices $newOrder)) {
          Ok ("BootOrder 现在 = " + (Format-BootOrderIndices $rb) + "（原顺序已备份）")
        } else { Warn ("BootOrder 回读不符: " + (Format-BootOrderIndices $rb)) }
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
  # 厂商自启（会在本机把算力清掉/覆盖 EFI）一律停掉
  # 2026-09-30 修：不再只认两个固定任务名（厂商换名就漏），改成按"名字或动作命令行里含 40HX"全扫
  $dis = 0
  foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    if ([string]$t.TaskName -eq $script:TaskName) { continue }
    $acts = ((@($t.Actions) | ForEach-Object { ([string]$_.Execute + ' ' + [string]$_.Arguments) }) -join ' ')
    if (([string]$t.TaskName -match '40HX|CMP40HX') -or ($acts -match '40HX|CMP40HX')) {
      if ($t.State -ne 'Disabled') {
        Disable-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue | Out-Null
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
    Info '本脚本已把快速启动关掉（见上面的"快速启动"行）；请【完全关机】再开机后复核；若仍是 N/A，请跑 诊断包-20260930\一键诊断.cmd 把报告发回来'
    Add-Action 'GSP 开关本来就是 1 但状态仍是 N/A：完全关机（不是重启）再开机 → 跑 -Mode Verify 复核；仍 N/A 就跑 诊断包-20260930\一键诊断.cmd 把报告发回来'
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
  if ($raw) { [IO.File]::WriteAllBytes((Join-Path $BackupDir 'BootOrder.selftest.bin'), $raw) }
  if (Write-FwVar 'BootOrder' $raw) {
    $rb = Read-FwVar 'BootOrder'
    if ($rb -and ([Convert]::ToBase64String($rb) -eq [Convert]::ToBase64String($raw))) { Ok ('BootOrder 写回 + 回读一致 (' + $raw.Length + " 字节，值未变)") }
    else { Bad 'BootOrder 回读不一致'; $problems++ }
  } else { Bad 'BootOrder 写入失败'; $problems++ }
  $after = Get-BootOrderIndices
  if ((Format-BootOrderIndices $after) -eq (Format-BootOrderIndices $order)) { Ok ('BootOrder 未被改动: ' + (Format-BootOrderIndices $after)) } else { Bad 'BootOrder 变了！'; $problems++ }
  if (-not (Read-FwVar 'BootNext')) { Ok 'BootNext 为空（没留一次性启动项）' } else { Warn 'BootNext 有值（注意下次开机走一次性项）' }

  Say ''
  if ($problems -eq 0) { Say '自检结论: 全部通过（ESP 读写、NVRAM 写入/回读/删除、BootOrder 写回 均正常）' 'Green' }
  else { Say ('自检结论: ' + $problems + ' 项失败，见上') 'Red' }
  $script:SelfTestProblems = $problems
  return
}

# ================================================================ 取证
function Invoke-Verify {
  Head '取证：算力（EFI 侧）'
  $compute = 'FAIL'; $gen2 = 'FAIL'
  $espRoot = Mount-Esp
  if ($espRoot) {
    $log = Join-Path $espRoot '40hx_log.txt'
    if (Test-Path $log) {
      $txt = Get-Content -LiteralPath $log
      $hit = $txt | Select-String 'UNLOCKED \(SS0=0x88888888 SS1=0x8\)' | Select-Object -Last 1
      if ($hit) { $compute = 'PASS'; Ok ("*** UNLOCKED (SS0=0x88888888 SS1=0x8) ***  文件时间 " + (Get-Item $log).LastWriteTime) }
      else { Bad '40hx_log.txt 里没有本次开机的 UNLOCKED 行' }
      $txt | Select-String -Pattern 'NO-RETRAIN|Root TLS=Gen2|chainload' | Select-Object -Last 4 | ForEach-Object { Info ($_.Line) }
    } else { Bad '40hx_log.txt 不存在 → 解锁固件这次开机没跑（算力一定没解锁）' }
    Dismount-Esp
  } else { Bad 'ESP 挂载失败' }

  Head '取证：PCIe Gen2（Windows 侧）'
  # 首选路径证据（2026-09-29 起）：postbind.log 的 "PASS: Gen2 reached on the new path"
  # + retrain-inpout.log 的逐条硬件读数。判 Gen2 看 LNKSTA（0x1102/0xF102），别看 nvidia-smi 的 link.gen.current（空闲会降速）
  $newPass = $null
  $pbLog2 = Join-Path $script:ProgDataWin 'logs\postbind.log'
  $rtLog = Join-Path $script:ProgDataWin 'logs\retrain-inpout.log'
  if (Test-Path $pbLog2) {
    $pbAll = Get-Content -LiteralPath $pbLog2
    $newPass = ($pbAll | Select-String -Pattern 'PASS:\s*Gen2 reached on the new path' | Select-Object -Last 1)
    ($pbAll | Select-String -Pattern '==== PostBind start|NewPath EXIT=|PASS:|FAIL:|falling back' | Select-Object -Last 3) | ForEach-Object { Info ('postbind: ' + $_.Line.Trim()) }
    if ($pbAll | Select-String -Pattern 'falling back to the legacy ACE path' | Select-Object -Last 1) { Info 'postbind 里出现过“回落到旧路径”：新路径那次没成功（看上面的 NewPath EXIT 码：11 基线不认识 / 12 GPU 未就绪 / 13 inpoutx64 没起来 / 10 链路没到 Gen2 / 3 WinRing0 不可用）' }
  } else { Bad 'postbind.log 不存在（开机任务没跑过）' }
  if ($newPass) {
    $gen2 = 'PASS'
    Ok 'postbind: 新路径 PASS —— inpoutx64 直写 MMIO，ACE-BOOT 全程没被停'
    if (Test-Path $rtLog) {
      (Get-Content -LiteralPath $rtLog | Select-String -Pattern 'pre   :|writeOk=|GPU final|ROOT final' | Select-Object -Last 6) | ForEach-Object { Info ('retrain: ' + $_.Line.Trim()) }
      Info ('retrain-inpout.log 时间: ' + (Get-Item $rtLog).LastWriteTime)
    } else { Warn 'retrain-inpout.log 不存在（新路径 PASS 就一定会写它，建议重跑一次任务核对）' }
  }
  $lastLog = Join-Path $script:ProgDataWin 'logs\last.log'
  if ($newPass) { Info '旧路径的 last.log 本次不用看（新路径已 PASS）；下面 SC 任务时间戳与 nvidia-smi 仅作参考' }
  elseif (Test-Path $lastLog) {
    $c = Get-Content -LiteralPath $lastLog
    $c | Select-String -Pattern 'GUARD=|SS0=|TLS |GPU final|ROOT final|PASS:|ERROR|EXIT=' | ForEach-Object { Info ($_.Line.Trim()) }
    # 幂等路径会输出 'PASS: already physical Gen2 x16; no writes needed.'，只认 'PASS: physical Gen2 x16' 会误判为失败
    $passLine = ($c | Select-String -Pattern 'PASS:\s*(already\s+)?physical Gen2 x16' | Select-Object -Last 1)
    $exitLine = ($c | Select-String -Pattern 'EXIT=\d+' | Select-Object -Last 1)
    if ($passLine) { $gen2 = 'PASS'; Ok ('helper: ' + $passLine.Line.Trim()) }
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
  if ($compute -eq 'PASS' -and $gen2 -eq 'PASS' -and $gspV.State -eq 'on') { Say '  结论: 两全达成（算力满血 + Gen2 x16 + GSP 正常）' 'Green' }
  elseif ($compute -eq 'PASS' -and $gen2 -eq 'PASS') { Say '  结论: 算力+Gen2 已达成，但 GSP 这项要处理（否则设备管理器会显示代码 43）' 'Yellow' }
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
      if ($order.Count -gt 0) { Write-BootOrderIndices -Indices $order -BackupDir $BackupDir | Out-Null; Ok ('BootOrder 已移除 ' + ('{0:X4}' -f $index) + ' → ' + (Format-BootOrderIndices (Get-BootOrderIndices))) }
      Remove-FwVar $name | Out-Null
      if (-not (Read-FwVar $name)) { Ok ('已删除固件启动项 ' + $name) } else { Warn ('固件启动项 ' + $name + ' 删不掉') }
    } else { Info '没有找到解锁启动项' }
    if (Read-FwVar 'BootNext') { Remove-FwVar 'BootNext' | Out-Null; Ok '已清掉 BootNext' }
  }
  if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
    Invoke-Native { schtasks /delete /tn $script:TaskName /f 2>&1 | Out-Null }
  }
  if (-not (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)) { Ok ('已删除开机任务 ' + $script:TaskName) }
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
  if (Test-Path $script:StateFile) { Remove-Item -LiteralPath $script:StateFile -Force }
  Say ''
  Say '卸载完成：重启后就是原生（未解锁）状态。' 'Yellow'
}

# ================================================================ 主流程
$isAdmin = Test-Admin
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
$script:LogPath = Join-Path $script:LogDir ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $Mode + '.log')

Say ''
Say '################################################################'
Say ('#  CMP 40HX 算力解锁 + PCIe Gen2  一键脚本   Mode=' + $Mode) 'Cyan'
Say ('#  包目录: ' + $script:PkgRoot) 'Cyan'
Say ('#  时间  : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   管理员: ' + $isAdmin) 'Cyan'
Say '################################################################'

if (-not $isAdmin -and $Mode -ne 'Check') {
  Fail '这个模式需要管理员权限：请右键“以管理员身份运行”一键安装.cmd（或 Start-Process powershell -Verb RunAs）' $script:ExitPrereq '双击 一键安装.cmd 会自动提权；直接右键 Install-40HXUnlock.ps1 →「使用 PowerShell 运行」不会提权'
}

if ($Mode -eq 'Check') {
  $rep = Get-CheckReport
  Show-Check $rep
  Say ''
  if ($script:FailCount -eq 0 -and $script:WarnCount -eq 0) { Say '体检完成：没有发现问题，可以跑 Install。' 'Green' }
  else { Say ('体检完成：' + $script:FailCount + ' 项失败、' + $script:WarnCount + ' 条提示（见上面 [失败]/[提示]）。') $(if ($script:FailCount -eq 0) { 'Yellow' } else { 'Red' }) }
  Say ('日志: ' + $script:LogPath)
  Exit-With $script:ExitOk
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
  Exit-With $script:ExitOk
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
  $order = @($unlock.Index) + @(Get-BootOrderIndices | Where-Object { $_ -ne $unlock.Index })
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
if ($Mode -eq 'Install') { Info '安装/修复：驱动+服务 → helper(含新路径工具) → 新路径驱动(inpoutx64) → GSP 开关 → 关快速启动 → ESP 固件 → 固件启动项 → 开机任务 → 厂商自启收尾' } else { Info 'Repair：只补驱动/服务/helper/新路径驱动/任务，不动 ESP 与固件启动项' }

$blockers = 0
if ($rep.Firmware -ne 'Uefi') { Bad '固件不是 UEFI 模式'; $blockers++ }
if ($rep.DiskStyle -ne 'GPT') { Bad ('系统盘不是 GPT（' + $rep.DiskStyle + '）'); $blockers++ }
if ($rep.SecureBoot -eq $true) { Bad 'Secure Boot 开着'; $blockers++ }
if ($rep.BitLocker -match 'On|1') { Bad 'BitLocker 开着（会索要恢复密钥）'; $blockers++ }
if ($rep.Target.Count -eq 0) { Bad '没找到 CMP 40HX (DEV_1F0B)'; $blockers++ }
if ($blockers -gt 0) {
  if ($Force) { Warn ('有 ' + $blockers + ' 项前提不满足，但 -Force 已指定 → 继续') }
  else { Fail ('有 ' + $blockers + ' 项前提不满足，先处理后重跑；确认要继续就加 -Force') $script:ExitPrereq '按上面 [失败] 行逐条处理：Secure Boot→BIOS 关；BitLocker→暂停/解密；MBR 盘→mbr2gpt；显卡没识别→插紧/装 NVIDIA 驱动；不是 UEFI→BIOS 关 CSM' }
}

$bk = New-BackupFolder
Install-DriverFiles -BackupDir $bk
Install-WindowsFiles
Install-InpoutFiles -BackupDir $bk
Install-Gsp
Install-Power
if ($Mode -eq 'Install') {
  Install-Efi -BackupDir $bk
  Install-BootEntry -BackupDir $bk -BootMode $BootMode
} else { Info 'Repair 模式：跳过 ESP 固件与固件启动项' }
Install-Task

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
Say '   脚本已把解锁固件写到 \EFI\Boot\bootx64.efi 兜底，多数主板不看 NVRAM 也能生效。' 'Yellow'
Say ''
Say ('  回滚：powershell -ExecutionPolicy Bypass -File "' + (Join-Path $script:PkgRoot 'Install-40HXUnlock.ps1') + '" -Mode Uninstall -Yes') 'Gray'

# 控制台关掉后还能看：把“下一步”写成文件放包目录
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
  Say ('  已写出下一步提示（控制台关了也能看）: ' + (Join-Path $script:PkgRoot '下一步-重启后看这里.txt')) 'Cyan'
} catch { Warn ('写“下一步”提示文件失败: ' + $_.Exception.Message) }
if ($script:FailCount -eq 0) { Exit-With $script:ExitOk } else { Exit-With $script:ExitFail }
