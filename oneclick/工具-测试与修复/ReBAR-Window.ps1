<#
ReBAR-Window.ps1  —  CMP 40HX ReBAR 8 GiB（X99 平台手工窗口版）

背景：r9c 版 40HXUNLK-REBAR.EFI 支持在启动项可选数据里给手工窗口：
        rebarwin=0x<hex>        （必须是 UCS-2 / UTF-16LE 写入）
本脚本做的事：
  1) Check   ：只读看现状（BAR1、4G 以上窗口、建议窗口、启动项/可选数据）
  2) Test    ：把 ReBAR EFI 写进 ESP + 建/改 Boot####（带 rebarwin）+ 置 BootNext 一次性试跑
  3) Persist ：试跑成功后做常驻（BootOrder 排第一 + SYSTEM 登录自愈任务）
  4) Rearm   ：给自愈任务用（重写启动项 + 重指 BootNext）
  5) Undo    ：清 BootNext、删自愈任务（彻底删启动项请用 一键解锁40HX.bat 选 u）

安全：改动前都先备份到 backup-EFI\<时间>\；每次写入都逐字节回读核对。
全程不动 BIOS、不刷 vBIOS、不碰显卡固件。
#>
param(
  [ValidateSet('Check','Test','Persist','Rearm','Undo')]
  [string]$Mode = 'Check',
  [string]$Window = '',
  [switch]$Force
)

$ErrorActionPreference = 'Continue'

# ---------------- 常量 ----------------
$script:Pkg      = Split-Path -Parent $PSScriptRoot
$script:Payload  = Join-Path $script:Pkg 'payload\EFI\40HXUNLK-REBAR.EFI'
$script:EfiMain  = Join-Path $script:Pkg 'payload\EFI\40HXUNLK.EFI'
$script:EfiSha   = 'DB28D8035B21DD6560201BDC2DF42FA44FADA2D8E590296C8A60D6639821F44F'
$script:EfiPath  = '\EFI\40HX\40HXUNLK-REBAR.EFI'
$script:MainPath = '\EFI\40HX\40HXUNLK.EFI'
$script:Desc     = '40HX Unlock + ReBAR'
$script:DescOld  = '40HX REBAR TEST'
$script:Need     = 0x202000000          # 8 GiB(BAR1) + 32 MiB(BAR3)
$script:BridgeGuard = 0x100000000       # 4 GiB：给看不到的桥窗口（如 00:02.0 的 4 GiB 预取窗口）留的安全区
$script:Align    = 0x200000000          # 8 GiB
$script:ApBase   = 0x380000000000       # 56T（MMIOHBase；本机实测窗口从这里起）
$script:BkRoot   = Join-Path $script:Pkg 'backup-EFI'
$script:TaskName = 'CMPRebarWindow'     # 不能含 40HX/ThrottleStop/40HXUnlock（会被 PostBind 每小时禁用）
$script:TaskDir  = 'C:\ProgramData\CMP40HXGen2\windows'
$script:FwGuid   = '{8be4df61-93ca-11d2-aa0d-00e098032b8c}'

function Say  { param([string]$T) Write-Host $T }
function Ok   { param([string]$T) Write-Host ('[OK]   ' + $T) -ForegroundColor Green }
function Warn { param([string]$T) Write-Host ('[注意] ' + $T) -ForegroundColor Yellow }
function Bad  { param([string]$T) Write-Host ('[失败] ' + $T) -ForegroundColor Red }
function Head { param([string]$T) Write-Host ''; Write-Host ('==== ' + $T + ' ====') -ForegroundColor Cyan }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pr = New-Object Security.Principal.WindowsPrincipal($id)
  return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Addr([uint64]$v) { return ('0x' + $v.ToString('X')) }

function Get-RebarwinFromText {
  param([string]$Text)
  if (-not $Text) { return [uint64]0 }
  $m = [regex]::Match($Text, 'rebarwin=0x([0-9A-Fa-f]+)')
  if (-not $m.Success) { return [uint64]0 }
  try { return [Convert]::ToUInt64($m.Groups[1].Value, 16) } catch { return [uint64]0 }
}

# ---------------- UEFI 变量（与包内同一套实现） ----------------
function Initialize-FwAccess {
  $signature = @"
using System;
using System.Runtime.InteropServices;
public class FwVarWin {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct TP { public uint Count; public LUID Luid; public uint Attributes; }
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP nw, uint len, IntPtr prev, IntPtr ret);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint GetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  public static string EnablePrivilege() {
    IntPtr tok;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) { return "OpenProcessToken err " + Marshal.GetLastWin32Error(); }
    LUID luid;
    if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) { return "LookupPrivilegeValue err " + Marshal.GetLastWin32Error(); }
    TP tp = new TP(); tp.Count = 1; tp.Luid = luid; tp.Attributes = 0x2;
    if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) { return "AdjustTokenPrivileges err " + Marshal.GetLastWin32Error(); }
    if (Marshal.GetLastWin32Error() == 1300) { return "not assigned (1300)"; }
    return "ok";
  }
}
"@
  try { Add-Type -TypeDefinition $signature -ErrorAction Stop | Out-Null } catch {
    Bad ('编译固件变量类型失败: ' + $_.Exception.Message); return $false
  }
  $r = [FwVarWin]::EnablePrivilege()
  if ($r -ne 'ok') { Bad ('启用 SeSystemEnvironmentPrivilege 失败: ' + $r); return $false }
  return $true
}

function Read-FwVar {
  param([string]$Name)
  $buf = New-Object byte[] 8192
  $len = [FwVarWin]::GetFirmwareEnvironmentVariableW($Name, $script:FwGuid, $buf, [uint32]$buf.Length)
  if ($len -le 0) { return $null }
  $out = New-Object byte[] ([int]$len)
  [Array]::Copy($buf, $out, $len)
  return $out
}

function Write-FwVar {
  param([string]$Name, [byte[]]$Data)
  $ok = [FwVarWin]::SetFirmwareEnvironmentVariableW($Name, $script:FwGuid, $Data, [uint32]$Data.Length)
  if (-not $ok) { Bad ('写固件变量 ' + $Name + ' 失败 err=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  return $ok
}

function Remove-FwVar {
  param([string]$Name)
  $empty = New-Object byte[] 0
  return [FwVarWin]::SetFirmwareEnvironmentVariableW($Name, $script:FwGuid, $empty, [uint32]0)
}

# ---------------- EFI_LOAD_OPTION 解析 / 构造 ----------------
function ConvertFrom-BootEntry {
  param([byte[]]$Bytes)
  if (-not $Bytes -or $Bytes.Length -lt 8) { return $null }
  $attrs = [BitConverter]::ToUInt32($Bytes, 0)
  $pathLen = [int][BitConverter]::ToUInt16($Bytes, 4)
  $idx = 6
  $chars = New-Object System.Collections.Generic.List[char]
  while (($idx + 1) -lt $Bytes.Length -and -not ($Bytes[$idx] -eq 0 -and $Bytes[$idx + 1] -eq 0)) {
    $chars.Add([char][BitConverter]::ToUInt16($Bytes, $idx)); $idx += 2
  }
  $idx += 2
  if (($idx + $pathLen) -gt $Bytes.Length) { return $null }
  $path = New-Object byte[] $pathLen
  [Array]::Copy($Bytes, $idx, $path, 0, $pathLen)
  $opt = @()
  if (($idx + $pathLen) -lt $Bytes.Length) {
    $opt = New-Object byte[] ($Bytes.Length - $idx - $pathLen)
    [Array]::Copy($Bytes, $idx + $pathLen, $opt, 0, $opt.Length)
  }
  $node = $null
  $filePath = ''
  if ($path.Length -ge 4 -and $path[0] -eq 0x04 -and $path[1] -eq 0x01) {
    $nodeLen = [int]$path[2] + 256 * [int]$path[3]
    if ($nodeLen -ge 4 -and $nodeLen -le $path.Length) {
      $node = New-Object byte[] $nodeLen
      [Array]::Copy($path, 0, $node, 0, $nodeLen)
    }
  }
  $j = 0
  if ($node) { $j = $node.Length }
  while ($j + 3 -lt $path.Length) {
    if ($path[$j] -eq 0x04 -and $path[$j + 1] -eq 0x04) {
      $fl = [int]$path[$j + 2] + 256 * [int]$path[$j + 3]
      $s = $j + 4
      $e = [Math]::Min($s + $fl - 2, $path.Length)
      if ($e -gt $s) {
        $filePath = [Text.Encoding]::Unicode.GetString($path[$s..($e - 1)])
        $nulPath = $filePath.IndexOf([char]0)
        if ($nulPath -ge 0) { $filePath = $filePath.Substring(0, $nulPath) }
      }
      break
    }
    $j += 4
  }
  $optText = ''
  if ($opt.Length -ge 2) {
    $optText = [Text.Encoding]::Unicode.GetString($opt)
    $nul = $optText.IndexOf([char]0)
    if ($nul -ge 0) { $optText = $optText.Substring(0, $nul) }
  }
  return [pscustomobject]@{
    Attributes = $attrs; Description = (-join $chars.ToArray()); FilePath = $filePath
    DeviceNode = $node; OptionalData = $opt; OptionalText = $optText
  }
}

function Get-AllBootEntries {
  $list = @()
  for ($i = 0; $i -le 255; $i++) {
    $name = 'Boot{0:X4}' -f $i
    $raw = Read-FwVar $name
    if ($raw -and $raw.Length -gt 6) {
      $p = ConvertFrom-BootEntry $raw
      if ($p) { $list += [pscustomobject]@{ Name = $name; Index = $i; Raw = $raw; Entry = $p } }
    }
  }
  return $list
}

function New-BootEntryBytes {
  param([byte[]]$DeviceNode, [string]$Description, [string]$EfiPath, [uint32]$Attributes = 1, [byte[]]$OptionalData = $null)
  $out = New-Object System.Collections.Generic.List[byte]
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

function Get-FreeBootSlot {
  param($Entries)
  $used = @($Entries | ForEach-Object { $_.Index })
  foreach ($range in @((4..255), (0..3))) {
    foreach ($i in $range) { if ($used -notcontains $i) { return $i } }
  }
  return -1
}

# ---------------- BootOrder / BootNext ----------------
function Get-BootOrderIndices {
  $raw = Read-FwVar 'BootOrder'
  if (-not $raw) { return @() }
  $list = @()
  for ($i = 0; ($i + 1) -lt $raw.Length; $i += 2) { $list += [int][BitConverter]::ToUInt16($raw, $i) }
  return $list
}

function Format-Order([int[]]$a) { return (($a | ForEach-Object { '{0:X4}' -f $_ }) -join ',') }

function Save-Order([int[]]$a) {
  $b = New-Object byte[] ($a.Count * 2)
  for ($i = 0; $i -lt $a.Count; $i++) { [Array]::Copy([BitConverter]::GetBytes([uint16]$a[$i]), 0, $b, $i * 2, 2) }
  return $b
}

function Set-BootOrderIndices {
  param([int[]]$Indices, [string]$BackupDir)
  $cur = Get-BootOrderIndices
  if ($BackupDir) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $BackupDir 'BootOrder.before.bin'), (Save-Order $cur))
  }
  $data = Save-Order $Indices
  if (-not (Write-FwVar 'BootOrder' $data)) { return $false }
  $back = Get-BootOrderIndices
  return ((Format-Order $back) -eq (Format-Order $Indices))
}

function Set-BootNext {
  param([int]$Index)
  $b = New-Object byte[] 2
  [Array]::Copy([BitConverter]::GetBytes([uint16]$Index), 0, $b, 0, 2)
  if (-not (Write-FwVar 'BootNext' $b)) { return $false }
  $rb = Read-FwVar 'BootNext'
  return ($rb -and $rb.Length -eq 2 -and [BitConverter]::ToUInt16($rb, 0) -eq $Index)
}

# ---------------- ESP ----------------
function Get-EspPartition {
  $espType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
  $cands = @()
  try { $cands = @(Get-Partition -ErrorAction Stop | Where-Object { ([string]$_.GptType).ToLower() -eq $espType }) } catch { $cands = @() }
  if ($cands.Count -eq 0) { return $null }
  $sysDisk = $null
  try { $sysDisk = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':'))).DiskNumber } catch { }
  $sameDisk = @($cands | Where-Object { $_.DiskNumber -eq $sysDisk })
  if ($sameDisk.Count -ge 1) { return ($sameDisk | Sort-Object PartitionNumber | Select-Object -First 1) }
  if ($cands.Count -eq 1) { return $cands[0] }
  return $null
}

function Get-EspNodeFromLive {
  param($Part)
  if (-not $Part) { return $null }
  $node = New-Object System.Collections.Generic.List[byte]
  $node.Add(0x04); $node.Add(0x01); $node.Add(0x2A); $node.Add(0x00)
  $node.AddRange([BitConverter]::GetBytes([uint32]$Part.PartitionNumber))
  $node.AddRange([BitConverter]::GetBytes([uint64]($Part.Offset / 512)))
  $node.AddRange([BitConverter]::GetBytes([uint64]($Part.Size / 512)))
  $node.AddRange(([Guid]$Part.Guid).ToByteArray())
  $node.Add(0x02); $node.Add(0x02)
  return $node.ToArray()
}

function Get-EspVolumeGuid {
  param([string]$Letter)
  $o = (mountvol $Letter /L 2>&1 | Out-String)
  $m = [regex]::Match($o, '(?i)Volume\{([0-9a-f-]{36})\}')
  if ($m.Success) { return $m.Groups[1].Value.ToLower() }
  return ''
}

function Mount-Esp {
  param($Part)
  $wantGuid = ''
  if ($Part) { $wantGuid = ([string]$Part.Guid).ToLower() }
  $letters = @('Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K')
  foreach ($dl in $letters) {
    if ((Test-Path ($dl + ':\EFI\Boot')) -or (Test-Path ($dl + ':\EFI\Microsoft'))) {
      if ($wantGuid) {
        $got = Get-EspVolumeGuid ($dl + ':')
        if ($got -and $got -ne $wantGuid) { continue }
      }
      return @{ Root = $dl + ':'; Mounted = $false }
    }
  }
  foreach ($dl in $letters) {
    if (Test-Path ($dl + ':\')) { continue }
    mountvol ($dl + ':') /S 2>&1 | Out-Null
    if ((Test-Path ($dl + ':\EFI\Boot')) -or (Test-Path ($dl + ':\EFI\Microsoft'))) { return @{ Root = $dl + ':'; Mounted = $true } }
    mountvol ($dl + ':') /D 2>&1 | Out-Null
  }
  return $null
}

# ---------------- 硬件读数 ----------------
function Get-Win4G {
  $out = @()
  $all = Get-CimInstance -ClassName CIM_MemoryMappedIO -ErrorAction SilentlyContinue
  foreach ($r in $all) {
    $s = [uint64]$r.StartingAddress; $e = [uint64]$r.EndingAddress
    if ($s -ge 0x100000000) { $out += [pscustomobject]@{ S = $s; E = $e } }
  }
  return $out
}

function Get-Bar1 {
  $smi = "$env:SystemRoot\System32\nvidia-smi.exe"
  if (-not (Test-Path $smi)) { return -1 }
  $q = (& $smi -q 2>&1 | Out-String)
  $m = [regex]::Match($q, '(?s)BAR1 Memory Usage.*?Total\s*:\s*(\d+)\s*MiB')
  if ($m.Success) { return [int]$m.Groups[1].Value }
  return -1
}

function Get-WindowPlan {
  param([uint64]$x)
  $w4 = Get-Win4G
  if ($w4.Count -eq 0) { return $null }
  $stackBase = [uint64](($w4 | Measure-Object -Property S -Minimum).Minimum)
  $maxEnd = [uint64](($w4 | Measure-Object -Property E -Maximum).Maximum)
  $top = $null
  for ($g = 0; $g -le 10; $g++) {
    $t = [uint64]$script:ApBase + ([uint64]1 -shl (30 + $g))
    if ($t -gt $maxEnd) { $top = $t; break }
  }
  $plan = [pscustomobject]@{
    StackBase = $stackBase; MaxEnd = $maxEnd; ApertureTop = $top
    ApertureGiB = $(if ($top) { [int](($top - $script:ApBase) / 1GB) } else { 0 })
    Window = [uint64]0; End = [uint64]0; Overlaps = @()
  }
  if ($x -eq 0) {
    if ($stackBase -le $script:ApBase) { return $plan }
    # 关键：EFI 的冲突扫描还看「桥窗口」（00:02.0 的 4 GiB 预取窗口比它的 BAR 低 1 GiB 起），
    # Windows 侧 CIM 只看得到设备 BAR，看不到桥窗口 —— 所以先让出 4 GiB 安全区再减去 need。
    # 本机实测：0x383F00000000 - 4G - 0x202000000 → 对齐后 = 0x383A00000000（正好躲开 0x383e00000000 那条桥窗口）
    $cand = [uint64]($stackBase - $script:BridgeGuard - $script:Need)
    if ($cand -lt [uint64]$script:ApBase) { $cand = [uint64]$script:ApBase }
    $cand = [uint64]($cand - ($cand % $script:Align))
    $plan.Window = $cand
  } else { $plan.Window = $x }
  $plan.End = $plan.Window + $script:Need - 1
  $plan.Overlaps = @($w4 | Where-Object { $plan.Window -le $_.E -and $plan.End -ge $_.S } | ForEach-Object { (Format-Addr $_.S) + '..' + (Format-Addr $_.E) })
  return $plan
}

function Assert-WindowValid {
  param([uint64]$x, [switch]$AllowOverlap)
  if ($x -eq 0) { Bad '窗口地址为空'; return $false }
  if (($x % $script:Align) -ne 0) { Bad ((Format-Addr $x) + ' 不是 8 GiB 对齐（要 0x???????000000000 这种）'); return $false }
  if ($x -lt $script:ApBase) { Bad ((Format-Addr $x) + ' 低于 56T 窗口起点 ' + (Format-Addr $script:ApBase)); return $false }
  $plan = Get-WindowPlan -x $x
  if ($plan.ApertureTop -and ($plan.End -ge $plan.ApertureTop)) {
    Bad ('需要的区间到 ' + (Format-Addr $plan.End) + '，超出 4G 以上窗口上界 ' + (Format-Addr $plan.ApertureTop)); return $false
  }
  if ($plan.Overlaps.Count -gt 0 -and -not $AllowOverlap) {
    Bad ('和现有窗口重叠: ' + ($plan.Overlaps -join ' ; ') + '（确要试加 -Force）'); return $false
  }
  return $true
}

# ---------------- 部署 ----------------
function Invoke-Deploy {
  param([uint64]$Win)

  if (-not (Test-Admin)) { Bad '需要管理员：请双击 ReBAR-Window.cmd'; return $false }
  if (-not (Test-Path $script:Payload)) { Bad ('缺 ReBAR EFI 载荷: ' + $script:Payload); return $false }
  $sha = (Get-FileHash $script:Payload -Algorithm SHA256).Hash
  if ($sha -ne $script:EfiSha) { Bad ('ReBAR EFI 哈希与冻结值不符: ' + $sha); return $false }

  Head '一次性试跑部署'
  Ok ('ReBAR EFI 载荷校验通过 ' + $sha.Substring(0,16) + '…')
  if (-not (Initialize-FwAccess)) { return $false }

  $espPart = Get-EspPartition
  $esp = Mount-Esp -Part $espPart
  if (-not $esp) { Bad 'ESP 挂载失败（需要 UEFI+GPT）'; return $false }
  Ok ('ESP 挂在 ' + $esp.Root)

  $dstDir = $esp.Root + '\EFI\40HX'
  if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
  $dst = Join-Path $dstDir '40HXUNLK-REBAR.EFI'
  $needCopy = $true
  if (Test-Path $dst) {
    $cur = (Get-FileHash $dst -Algorithm SHA256).Hash
    if ($cur -eq $sha) { Ok ('ESP 上已有同一份 ReBAR EFI: ' + $dst); $needCopy = $false }
  }
  if ($needCopy) {
    Copy-Item -LiteralPath $script:Payload -Destination $dst -Force
    $rd = (Get-FileHash $dst -Algorithm SHA256).Hash
    if ($rd -ne $sha) { Bad '写入 ESP 后回读哈希不一致'; if ($esp.Mounted) { mountvol $esp.Root /D | Out-Null }; return $false }
    Ok ('已写入 ' + $dst + '（回读一致）')
  }
  $mainDst = Join-Path $dstDir '40HXUNLK.EFI'
  if (Test-Path $mainDst) { Ok ('主线解锁固件在位: ' + $mainDst) } else { Warn ('ESP 上没有主线解锁固件 ' + $mainDst + '（建议先跑 一键解锁40HX.bat 选 1）') }

  $optStr = 'rebarwin=' + (Format-Addr $Win)
  $opt = [Text.Encoding]::Unicode.GetBytes($optStr) + [byte]0 + [byte]0
  Say ('  可选数据(UCS-2): ' + $optStr)

  $entries = Get-AllBootEntries
  $mine = @($entries | Where-Object { $_.Entry.Description -eq $script:Desc -or $_.Entry.Description -eq $script:DescOld -or $_.Entry.FilePath -eq $script:EfiPath }) | Select-Object -First 1
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bk = Join-Path $script:BkRoot $stamp
  New-Item -ItemType Directory -Force -Path $bk | Out-Null

  $node = Get-EspNodeFromLive $espPart
  if (-not $node) {
    $tplNode = @($entries | Where-Object { $_.Entry.DeviceNode } | Select-Object -First 1)
    if ($tplNode.Count -eq 0) { Bad '取不到 ESP 分区也没有可参考节点，无法构造启动项'; if ($esp.Mounted) { mountvol $esp.Root /D | Out-Null }; return $false }
    $node = $tplNode[0].Entry.DeviceNode
    Warn ('设备路径节点沿用 ' + $tplNode[0].Name)
  }

  if ($mine) {
    $name = $mine.Name; $index = $mine.Index
    [IO.File]::WriteAllBytes((Join-Path $bk ($name + '.before.bin')), $mine.Raw)
    $attrs = $mine.Entry.Attributes
    Ok ('已有 ReBAR 启动项 ' + $name + ' → 原槽位重写（旧字节已备份）')
  } else {
    $index = Get-FreeBootSlot $entries
    if ($index -lt 0) { Bad '没有空闲 Boot#### 槽位'; if ($esp.Mounted) { mountvol $esp.Root /D | Out-Null }; return $false }
    $name = 'Boot{0:X4}' -f $index
    $tpl = @($entries | Where-Object { $_.Entry.Description -match '^40HX' }) | Select-Object -First 1
    if (-not $tpl) { $tpl = @($entries | Where-Object { $_.Entry.Description -match 'Windows Boot Manager' }) | Select-Object -First 1 }
    $attrs = $(if ($tpl) { $tpl.Entry.Attributes } else { [uint32]1 })
    Ok ('将新建 ' + $name + " = '" + $script:Desc + "'（属性 0x" + ('{0:X}' -f $attrs) + '）')
  }

  $bytes = New-BootEntryBytes -DeviceNode $node -Description $script:Desc -EfiPath $script:EfiPath -Attributes $attrs -OptionalData $opt
  [IO.File]::WriteAllBytes((Join-Path $bk 'planned.bin'), $bytes)
  if (-not (Write-FwVar $name $bytes)) { if ($esp.Mounted) { mountvol $esp.Root /D | Out-Null }; return $false }
  $rb = Read-FwVar $name
  if (-not $rb -or [Convert]::ToBase64String($rb) -ne [Convert]::ToBase64String($bytes)) {
    Bad ('写 ' + $name + ' 后回读不一致'); if ($esp.Mounted) { mountvol $esp.Root /D | Out-Null }; return $false
  }
  $chk = ConvertFrom-BootEntry $rb
  Ok ('启动项已写好并逐字节回读一致: ' + $name + ' 可选数据=' + $chk.OptionalText)

  if ($esp.Mounted) { mountvol $esp.Root /D 2>&1 | Out-Null }

  # BootOrder 里补进去（不抢第一位）
  $order = Get-BootOrderIndices
  if ($order -notcontains $index) {
    $newOrder = @($order) + @($index)
    if (Set-BootOrderIndices -Indices $newOrder -BackupDir $bk) { Ok ('BootOrder 已追加 ' + ('{0:X4}' -f $index) + ' → ' + (Format-Order (Get-BootOrderIndices))) }
    else { Warn 'BootOrder 追加失败（不影响 BootNext 试跑）' }
  } else { Ok ('BootOrder 里已有 ' + ('{0:X4}' -f $index)) }

  if (-not (Set-BootNext -Index $index)) { Bad '设置 BootNext 失败'; return $false }
  Ok ('BootNext = ' + ('{0:X4}' -f $index) + '（只影响下一次开机）')
  Say ''
  Say '备份目录: ' + $bk
  return $true
}

# ---------------- 自愈任务 ----------------
function Invoke-Rearm {
  param([uint64]$Win)
  if (-not (Initialize-FwAccess)) { return $false }
  $entries = Get-AllBootEntries
  $mine = @($entries | Where-Object { $_.Entry.Description -eq $script:Desc -or $_.Entry.FilePath -eq $script:EfiPath }) | Select-Object -First 1
  $opt = [Text.Encoding]::Unicode.GetBytes('rebarwin=' + (Format-Addr $Win)) + [byte]0 + [byte]0
  $node = $null
  $espPart = Get-EspPartition
  if ($espPart) { $node = Get-EspNodeFromLive $espPart }
  if ($mine) {
    if (-not $node) { $node = $mine.Entry.DeviceNode }
    $index = $mine.Index; $name = $mine.Name; $attrs = $mine.Entry.Attributes
  }
  else {
    # 启动项不见了：只有在 ESP 上确实有 ReBAR EFI 时才重建 ——
    # 否则会造出"指向已删文件"的启动项，开机加载失败会直接跳过解锁固件（本机 13:24 踩过）。
    $esp = Mount-Esp -Part (Get-EspPartition)
    if (-not $esp) { return $false }
    $hasEfi = Test-Path ($esp.Root + '\EFI\40HX\40HXUNLK-REBAR.EFI')
    if ($esp.Mounted) { mountvol $esp.Root /D 2>&1 | Out-Null }
    if (-not $hasEfi) {
      try { Add-Content -Path (Join-Path $script:TaskDir 'rebar-rearm.log') -Value ((Get-Date -Format 's') + ' skip: ESP 上没有 40HXUNLK-REBAR.EFI，不重建启动项') } catch { }
      return $false
    }
    $index = Get-FreeBootSlot $entries
    if ($index -lt 0) { return $false }
    $name = 'Boot{0:X4}' -f $index
    $attrs = [uint32]1
  }
  if (-not $node) { return $false }
  $bytes = New-BootEntryBytes -DeviceNode $node -Description $script:Desc -EfiPath $script:EfiPath -Attributes $attrs -OptionalData $opt
  if (-not (Write-FwVar $name $bytes)) { return $false }
  $rb = Read-FwVar $name
  if (-not $rb -or [Convert]::ToBase64String($rb) -ne [Convert]::ToBase64String($bytes)) { return $false }
  $order = Get-BootOrderIndices
  if ($order -notcontains $index) { Set-BootOrderIndices -Indices (@($order) + @($index)) -BackupDir $null | Out-Null }
  return (Set-BootNext -Index $index)
}

function Invoke-Persist {
  param([uint64]$Win)
  if (-not (Test-Admin)) { Bad '需要管理员：请双击 ReBAR-Window.cmd'; return $false }
  if (-not (Initialize-FwAccess)) { return $false }
  $entries = Get-AllBootEntries
  $mine = @($entries | Where-Object { $_.Entry.Description -eq $script:Desc -or $_.Entry.FilePath -eq $script:EfiPath }) | Select-Object -First 1
  if (-not $mine) { Bad '还没部署 ReBAR 启动项 —— 先跑 -Mode Test'; return $false }
  $index = $mine.Index
  # 固化时**沿用已生效的窗口**（从现有启动项的可选数据读），不要重新推算：
  # 成功之后 stackBase 会变成新的 BAR3 地址，重新推算会得到更低的地址（本机 0x383800000000）。
  if ($Win -eq 0) { $Win = Get-RebarwinFromText $mine.Entry.OptionalText }
  if ($Win -eq 0) { $Win = (Get-WindowPlan -x 0).Window }
  if ($Win -eq 0) { Bad '拿不到窗口地址（启动项里没有 rebarwin，也没有可用建议）'; return $false }
  $bar1 = Get-Bar1
  if ($bar1 -ne 8192 -and -not $Force) {
    Bad ('当前 BAR1 = ' + $bar1 + ' MiB，ReBAR 还没生效 —— 先把 Test 试通再固化（确要强制加 -Force）')
    return $false
  }
  Ok ('固化使用窗口 ' + (Format-Addr $Win) + '（来自启动项可选数据）')
  Head '常驻（BootOrder 第一 + 登录自愈任务）'
  $bk = Join-Path $script:BkRoot ('persist-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $order = Get-BootOrderIndices
  if ($order[0] -ne $index) {
    $newOrder = @($index) + @($order | Where-Object { $_ -ne $index })
    if (Set-BootOrderIndices -Indices $newOrder -BackupDir $bk) { Ok ('BootOrder 现在 = ' + (Format-Order (Get-BootOrderIndices))) }
    else { Bad 'BootOrder 改写失败'; return $false }
  } else { Ok ('BootOrder 第一位已经是 ' + ('{0:X4}' -f $index)) }

  $stateDir = Join-Path $script:Pkg 'state'
  try {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    ('window=' + (Format-Addr $Win) + '  time=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) | Out-File -Encoding ascii -FilePath (Join-Path $stateDir 'rebarwin.txt')
    Ok ('已记录生效窗口到 ' + (Join-Path $stateDir 'rebarwin.txt'))
  } catch { Warn '记录 rebarwin.txt 失败（不影响功能）' }

  if (Test-Path $script:TaskDir) {
    $deploy = Join-Path $script:TaskDir 'ReBAR-Window.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $deploy -Force
    # 路径无空格，不加引号（PS 调 schtasks 时内嵌引号容易被拆坏）
    $act = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + $deploy + ' -Mode Rearm -Window ' + (Format-Addr $Win)
    schtasks /delete /tn $script:TaskName /f 2>&1 | Out-Null
    $o = (schtasks /create /tn $script:TaskName /sc onlogon /rl highest /ru SYSTEM /f /tr $act 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) { Ok ('已注册登录自愈任务「' + $script:TaskName + '」（SYSTEM，登录后重写启动项并重指 BootNext）') }
    else { Warn ('注册自愈任务失败: ' + $o) }
  } else { Warn ('没有 ' + $script:TaskDir + '，跳过自愈任务（先跑一次 一键解锁40HX.bat 选 1 建目录）') }
  return $true
}

function Invoke-Unplug {
  if (-not (Test-Admin)) { Bad '需要管理员：请双击 ReBAR-Window.cmd'; return $false }
  if (-not (Initialize-FwAccess)) { return $false }
  Head '撤销本次改动'
  $bn = Read-FwVar 'BootNext'
  if ($bn -and $bn.Length -eq 2) { Remove-FwVar 'BootNext' | Out-Null; Ok 'BootNext 已清' }
  schtasks /delete /tn $script:TaskName /f 2>&1 | Out-Null
  Ok '已删自愈任务（如存在）'
  Warn '启动项与 ESP 上的 ReBAR EFI 仍留着；要彻底删掉：双击 一键解锁40HX.bat → 输入 u'
  return $true
}

# ---------------- 主流程 ----------------
$winVal = [uint64]0
if ($Window) {
  try { $winVal = [Convert]::ToUInt64(($Window -replace '^(?i)0x', ''), 16) } catch { Bad ('-Window 解析失败: ' + $Window); exit 2 }
}

switch ($Mode) {
  'Check' {
    Head '现状'
    $bar1 = Get-Bar1
    Say ('  BAR1: ' + $(if ($bar1 -ge 0) { $bar1.ToString() + ' MiB' } else { '读不到' }) + $(if ($bar1 -eq 8192) { '   ← ReBAR 已生效' } elseif ($bar1 -gt 0) { '   ← 未生效（正常值 64 / 目标 8192）' } else { '' }))
    Say ('  管理员: ' + (Test-Admin))
    Head '4G 以上 MMIO 窗口'
    $plan = Get-WindowPlan -x $winVal
    $w4 = Get-Win4G
    foreach ($w in ($w4 | Sort-Object S -Unique)) { Say ('  ' + (Format-Addr $w.S) + '..' + (Format-Addr $w.E) + '  size=' + [math]::Round(($w.E - $w.S + 1) / 1MB, 1) + ' MB') }
    Say ('  已用最低地址: ' + (Format-Addr $plan.StackBase))
    Say ('  推断 4G 以上窗口: ' + (Format-Addr $script:ApBase) + '..' + (Format-Addr $plan.ApertureTop) + '  (' + $plan.ApertureGiB + ' GiB)')
    Say ('  建议手工窗口  : ' + (Format-Addr $plan.Window) + '（占用 ' + (Format-Addr $plan.Window) + '..' + (Format-Addr $plan.End) + '，已给桥窗口留 4 GiB 安全区）')
    if ($plan.Overlaps.Count -gt 0) { Warn ('建议窗口与现有窗口重叠: ' + ($plan.Overlaps -join ' ; ')) }
    if ($plan.ApertureGiB -le 256 -and $plan.Window -eq 0) { Warn '窗口太小/没有可用位置 —— 可能要先改 BIOS 的 MMIO High Size' }
    if (Test-Admin) {
      if (Initialize-FwAccess) {
        Head '启动项'
        $entries = Get-AllBootEntries
        foreach ($e in $entries) {
          $optShow = ''
          if ($e.Entry.OptionalData.Length -gt 0) {
            if ($e.Entry.OptionalText -match '^[ -~]+$') { $optShow = '   opt=' + $e.Entry.OptionalText }
            else { $optShow = '   opt=<binary ' + $e.Entry.OptionalData.Length + ' B>' }
          }
          Say ('  ' + $e.Name + "  '" + $e.Entry.Description + "'  " + $e.Entry.FilePath + $optShow)
        }
        Say ('  BootOrder = ' + (Format-Order (Get-BootOrderIndices)))
        $mineC = @($entries | Where-Object { $_.Entry.Description -eq $script:Desc -or $_.Entry.FilePath -eq $script:EfiPath }) | Select-Object -First 1
        if ($mineC) {
          $ew = Get-RebarwinFromText $mineC.Entry.OptionalText
          if ($ew -gt 0) {
            Say ('  ReBAR 手工窗口: ' + (Format-Addr $ew) + $(if ($bar1 -eq 8192) { '   ← 已生效；固化请跑 Persist（会沿用这个地址，别再按上面的"建议"重装）' } else { '   ← 未生效（下次开机由它生效）' }))
          }
        }
        $bn = Read-FwVar 'BootNext'
        if ($bn -and $bn.Length -eq 2) { Say ('  BootNext  = ' + ('{0:X4}' -f [BitConverter]::ToUInt16($bn, 0))) } else { Say '  BootNext  = (空)' }
      }
    } else { Say '  （非管理员：跳过固件启动项检查）' }
    Say ''
  }
  'Test' {
    if ($winVal -eq 0) { $winVal = (Get-WindowPlan -x 0).Window }
    if (-not (Assert-WindowValid -x $winVal -AllowOverlap:$Force)) { exit 2 }
    $p = Get-WindowPlan -x $winVal
    Say ('目标窗口: ' + (Format-Addr $winVal) + ' .. ' + (Format-Addr $p.End))
    if (-not (Invoke-Deploy -Win $winVal)) { exit 1 }
    Say ''
    Say '============================================================'
    Say ' ★ 现在【完全关机】（开始菜单→关机，最好拔电 10 秒）再开机'
    Say ' ★ 开机跑码界面应出现: [rebar] BAR1 8 GiB active @' + (Format-Addr $winVal)
    Say ' ★ 进系统后运行本工具 -Mode Check（或 nvidia-smi -q 看 BAR1 Total = 8192 MiB）'
    Say ' ★ 若仍回滚：读 ESP 的 40hx_log.txt（用 工具-测试与修复\ReBAR-Log.cmd）'
    Say '============================================================'
  }
  'Persist' {
    if (-not (Invoke-Persist -Win $winVal)) { exit 1 }
  }
  'Rearm' {
    $ok = $false
    if ($winVal -ne 0) { $ok = Invoke-Rearm -Win $winVal }
    try { Add-Content -Path (Join-Path $script:TaskDir 'rebar-rearm.log') -Value ((Get-Date -Format 's') + ' rearm=' + $ok) } catch { }
    if ($ok) { exit 0 } else { exit 1 }
  }
  'Undo' {
    if (-not (Invoke-Unplug)) { exit 1 }
  }
}
exit 0
