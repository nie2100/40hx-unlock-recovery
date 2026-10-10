#Requires -Version 5.1
# Copyright (c) 2026 nie2100 —— 本文件属本仓库自写部分，保留所有权利（未经许可不得再分发 / 二次打包 / 转卖）。
# ============================================================
#  MBR 系统盘一键转 GPT（mbr2gpt 官方工具的安全包装）
#  双击 工具-测试与修复\MBR转GPT.cmd 使用（会自动提权）
#  设计原则：先体检再确认再动手；validate 不过就什么都不改；
#           转完必须进 BIOS 把引导改成 UEFI（关 CSM），否则开不了机。
# ============================================================
$ErrorActionPreference = 'Continue'
$script:FailCount = 0
function Say { param([string]$T = '', [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }
function Ok   { param([string]$T) Say ("  [OK]   " + $T) 'Green' }
function Warn { param([string]$T) Say ("  [提示] " + $T) 'Yellow' }
function Bad  { param([string]$T) Say ("  [失败] " + $T) 'Red'; $script:FailCount++ }
function Info { param([string]$T) Say ("  - " + $T) }

Say ''
Say '============================================================' 'Cyan'
Say '  MBR → GPT 一键转换（为 40HX 解锁做准备：UEFI+GPT 是前提）' 'Cyan'
Say '============================================================' 'Cyan'
Say '  原理：微软官方 mbr2gpt 原地转换，不动你的数据和软件。' 'Gray'
Say '  但【转完必须进 BIOS 把引导模式改成 UEFI（关 CSM/Legacy）】，' 'Yellow'
Say '  否则机器开不了机（不是丢数据，是固件不认识新分区表的引导）。' 'Yellow'
Say ''

# ---- 0) 管理员 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Bad '需要管理员权限（用 MBR转GPT.cmd 双击会自动提权）'; exit 2 }

# ---- 1) 系统盘样式 ----
$disk = $null
try { $disk = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop | Get-Disk -ErrorAction Stop } catch { }
if (-not $disk) {
  try {
    $p = Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' -ClassName MSFT_Partition -ErrorAction Stop | Where-Object { $_.DriveLetter -eq $env:SystemDrive.TrimEnd(':') } | Select-Object -First 1
    if ($p) { $disk = Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' -ClassName MSFT_Disk -ErrorAction Stop | Where-Object { $_.Number -eq $p.DiskNumber } | Select-Object -First 1 }
  } catch { }
}
if (-not $disk) { Bad '读不到系统盘信息（Storage 接口坏了）—— 别转，先把系统盘情况搞清楚'; exit 1 }
$style = [string]$disk.PartitionStyle
$dn = $disk.Number
Info ('系统盘: 磁盘 ' + $dn + '（' + [string]$disk.FriendlyName + '）  当前样式: ' + $style)
if ($style -eq 'GPT') { Ok '系统盘已经是 GPT —— 不需要转换。直接去跑 一键安装.cmd 即可'; exit 0 }
if ($style -ne 'MBR') { Bad ('系统盘样式不是 MBR 也不是 GPT（' + $style + '）—— 不属本工具处理范围'); exit 1 }

# ---- 2) 预检 ----
Say ''
Say '---- 预检（逐项必须过）----' 'Cyan'
$m2g = Join-Path $env:SystemRoot 'System32\mbr2gpt.exe'
if (Test-Path $m2g) { Ok ('mbr2gpt 存在: ' + $m2g) } else { Bad '系统里没有 mbr2gpt.exe（Windows 10 1703 以下没有）—— 无法转换'; }

$build = 0
try { $build = [int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber } catch { }
if ($build -ge 15063) { Ok ('Windows build ' + $build + '（支持 /allowFullOS 在线转换）') } else { Bad ('Windows build ' + $build + ' 太老（< 15063），不支持在线转换') }

$bl = ''
try { $bl = [string](Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop).ProtectionStatus } catch { $bl = '读不到' }
if ($bl -match 'On|1') { Bad 'BitLocker 开着 —— 先暂停/解密再转换（否则改引导会索要恢复密钥）' } else { Ok ('BitLocker: ' + $bl) }

$parts = @()
try { $parts = @(Get-Partition -DiskNumber $dn -ErrorAction Stop) } catch { }
if ($parts.Count -eq 0) { Warn '分区列表读不到 —— 跳过分区数检查（validate 会兜底）' }
elseif ($parts.Count -le 3) { Ok ('分区数 ' + $parts.Count + '（≤3，能腾出 ESP 的位置）') }
else { Bad ('分区数 ' + $parts.Count + ' > 3 —— mbr2gpt 转不了（官方限制）。要转得先删掉/合并一个分区') }

$freeGB = 0
try { $freeGB = [math]::Round((Get-PSDrive ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop).Free / 1GB, 1) } catch { }
if ($freeGB -ge 0.5) { Ok ('C: 盘剩余 ' + $freeGB + ' GB（够划出 100MB 的 ESP）') } else { Bad ('C: 盘剩余 ' + $freeGB + ' GB —— 太少，划不出 ESP；先清理磁盘') }

# ---- 3) mbr2gpt 官方校验 ----
if ($script:FailCount -gt 0) { Say ''; Bad ('有 ' + $script:FailCount + ' 项预检没过 —— 先处理再跑。本次什么都没改。'); exit 2 }
Say ''
Info '跑 mbr2gpt 官方校验（只读，不改任何东西）...'
& $m2g /validate /disk:$dn /allowFullOS
$vrc = $LASTEXITCODE
if ($vrc -ne 0) {
  Bad ('mbr2gpt 官方校验没过（退出码 ' + $vrc + '）—— 什么都没改。常见原因：分区布局不符合要求/有 OEM 恢复分区挡着/磁盘有错误')
  Say '  把上面红字上面的英文输出发给技术即可定位。' 'Yellow'
  exit 2
}
Ok 'mbr2gpt 官方校验通过'

# ---- 4) 确认 ----
Say ''
Say '============================================================' 'Yellow'
Say '  最后再确认一遍风险：' 'Yellow'
Say '  ① 转完必须重启进 BIOS：引导模式 Legacy/CSM 改成 UEFI' 'Yellow'
Say '     （顺便确认 Above 4G Decoding 开、Secure Boot 关）' 'Yellow'
Say '  ② 2011 年以前的老主板可能没有 UEFI —— 那种机器不能转' 'Yellow'
Say '  ③ 有双系统/Linux 的话，那个系统会进不去' 'Yellow'
Say '  ④ 转换本身几秒钟完成，不动数据；但断电/强制关机别赶在这几秒' 'Yellow'
Say '============================================================' 'Yellow'
$ans = Read-Host '确定要转换？输入大写 YES 继续，其它任意键取消'
if ($ans -cne 'YES') { Say '已取消，什么都没改。' 'Gray'; exit 0 }

# ---- 5) 转换 ----
Say ''
Info '开始转换（通常几秒钟）...'
& $m2g /convert /disk:$dn /allowFullOS
$crc = $LASTEXITCODE
if ($crc -ne 0) { Bad ('转换失败（退出码 ' + $crc + '）—— 把上面的英文输出发给技术。磁盘一般还是 MBR 原样。'); exit 1 }

# ---- 6) 新 BCD 体检 + 自动修复（2026-10-10 客户现场实踩，勿删）----
#   这台链条里唯一写 BCD 的是 mbr2gpt 自己（安装器建固件启动项只写 NVRAM，不碰 BCD）。
#   已知坑：mbr2gpt 新建的 BCD 偶尔 device/osdevice 解析不出来（unknown），
#   客户一重启就 0xc000000e 蓝屏，只能进 PE 手工 bcdboot 救 —— 所以转完当场验证、
#   坏了当场重建，把 PE 那一步提前到这里自动做掉。
Say ''
Info '体检新 BCD（防重启蓝屏 0xc000000e）...'
function Test-BcdStore { param([string]$BcdPath)
  # $true=健康 / $false=坏或读不出。判据：{default} 的 osdevice 必须解析成 partition=...
  if (-not (Test-Path $BcdPath)) { return $false }
  $out = (& bcdedit.exe /store $BcdPath /enum '{default}' 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) { return $false }
  if ($out -notmatch 'osdevice\s+partition=') { return $false }
  return $true
}
$bcdBad = $false
try {
  $esp = @(Get-Partition -DiskNumber $dn -ErrorAction Stop | Where-Object { [string]$_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1)
  if ($esp.Count -eq 0) { Warn '没找到新 ESP 分区 —— 跳过 BCD 体检（重启后若 0xc000000e 蓝屏，进 PE 跑 bcdboot，见桌面说明）'; $bcdBad = $true }
  else {
    $esp = $esp[0]
    $L = $null
    foreach ($c in [char[]]'ZYXWVUTSRQPON') { if (-not (Get-PSDrive -Name ([string]$c) -ErrorAction SilentlyContinue)) { $L = [string]$c; break } }
    if (-not $L) { Warn '没有空闲盘符挂 ESP —— 跳过 BCD 体检'; $bcdBad = $true }
    else {
      $esp | Set-Partition -NewDriveLetter $L -ErrorAction Stop
      $bcdPath = $L + ':\EFI\Microsoft\Boot\BCD'
      if (Test-BcdStore $bcdPath) {
        Ok '新 BCD 体检通过（osdevice 可正常解析）'
      } else {
        Warn '新 BCD 是坏的（device/osdevice=unknown）—— 正在自动重建（bcdboot）...'
        & (Join-Path $env:SystemRoot 'System32\bcdboot.exe') ($env:SystemDrive + '\Windows') /s ($L + ':') /f UEFI | Out-Null
        if (Test-BcdStore $bcdPath) { Ok 'bcdboot 重建后体检通过 —— 蓝屏隐患已排除' }
        else {
          $bcdBad = $true
          Bad 'bcdboot 重建后 BCD 仍是坏的 —— 【先别重启】把本窗口截图发给技术'
        }
      }
      # 收尾：把 ESP 盘符撤掉（引导不依赖盘符）
      try { & mountvol.exe ($L + ':') /d | Out-Null } catch { }
    }
  }
} catch {
  Warn ('BCD 体检没跑成（' + $_.Exception.Message + '）—— 跳过，不影响转换结果本身')
  $bcdBad = $true
}

Say ''
Say '============================================================' 'Green'
Say '  [OK] 转换完成：系统盘已是 GPT。' 'Green'
Say '============================================================' 'Green'
Say '  接下来（缺一步都不行）：' 'Yellow'
Say '  1. 重启，开机猛按 Del/F2 进 BIOS' 'Yellow'
Say '  2. 引导模式改成 UEFI（关掉 CSM / Legacy）；Secure Boot 保持关闭' 'Yellow'
Say '  3. 保存退出。能正常进 Windows = 成功；进不去 = 第 2 步没改对，再进 BIOS 检查' 'Yellow'
Say '  4. 进了 Windows 之后，双击 一键安装.cmd 开始装 40HX 解锁' 'Yellow'
Say ''
# 写一份到桌面，重启后也能看
try {
  $desk = [Environment]::GetFolderPath('Desktop')
  if (-not $desk) { $desk = 'C:\Users\Public\Desktop' }
  $txt = @'
MBR→GPT 转换已完成（mbr2gpt 官方工具）。接下来：

1. 重启进 BIOS（开机按 Del/F2）
2. 引导模式：Legacy/CSM 改成 UEFI；Secure Boot 保持关；Above 4G Decoding 开
3. 保存退出，能进 Windows 就成功
4. 进 Windows 后双击 40HX 包里的 一键安装.cmd

进不去系统别慌：数据没丢，再进 BIOS 检查引导模式是不是 UEFI。
'@
  [IO.File]::WriteAllText((Join-Path $desk '40HX-转GPT后看这里.txt'), $txt, (New-Object System.Text.UTF8Encoding($true)))
  Ok ('说明已存桌面: ' + (Join-Path $desk '40HX-转GPT后看这里.txt'))
} catch { Warn ('写桌面说明失败（不影响转换）: ' + $_.Exception.Message) }
exit 0
