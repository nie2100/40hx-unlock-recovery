# =============================================================================
# 一键解锁40HX.ps1 —— 主入口菜单的实现（算力 + Gen2 + ReBAR；2026-10-14 起并进主线一键包）
#   配套入口：一键解锁40HX.bat（双击它；带 UAC 提权，参数 -Choice 1/2/3/check/undo）。
#   历史：2026-10-12 在支线（40hx-rebar-efi-test）写成，原名 安装-三选一.ps1（用户 2026-10-14 定：主入口叫 一键解锁40HX.bat）。
#   1) 解锁算力 + Gen2            （= 主线安装器 Install-40HXUnlock.ps1 -Mode Install 的完整流程）
#   2) 解锁算力 + Gen2 + ReBAR 8GiB（= 选项 1 + 把 ReBAR 版 EFI 设为第一启动项）
#   3) 只解锁 Gen2                （不动 ESP / 不动固件启动项 / 不解算力）
#   体检：先跑主线只读体检 + 本机 ReBAR 相关读数，再给推荐；选 2 体检不通过时会先警告，
#         客户执意要装就用 -Force（或交互里输入 FORCE）放行 —— 只告知风险，不拦。
# 位置：已并入主线一键包 —— 与本包的 Install-40HXUnlock.ps1 / 一键修复Gen2.ps1 / 工具-测试与修复\ 同目录。
#   调用方式沿用支线已验证过的方式（Invoke-MainTool：cmd 包裹子进程 + 超时兜底 + 输出落盘），
#   只把默认目录从"父目录下的 40hx-oneclick"改成"本脚本所在目录"—— 解压到哪就装哪，不再依赖目录名。
# 局限（务必如实告知，别当已交付件）：
#   · ReBAR 只能在 EFI 阶段开（Windows 侧热启用实测死路）；主板需 Above 4G Decoding 打开 +
#     有一块空闲的 64 位 MMIO 窗口放得下 8 GiB 对齐空间；不满足时 EFI 会整体回滚、系统照常启动。
#   · 目前只有作者本机（1 台 B560M + 1 张 40HX + 驱动 616.92）验证过；其它主板/驱动/多卡未验证。
#   · "BIOS 里的 Re-Size BAR Support 没开"不影响本方式（本方式直接配 XVE + 桥窗口），
#     但 Above 4G Decoding 必须开；装机前只能提示，第一次开机会自证（EFI 自己试，失败自动回滚）。
# =============================================================================
param(
  # menu = 体检 → 给推荐 → 问你要做哪个（默认；双击 一键解锁40HX.bat 走这条）
  # 1/2/3/r/check/u/undo = 直接执行对应动作（不给菜单，脚本化/带参调用用）
  # force = 强行解锁算力（= 选项 1 + 强制；锁死/未知批次也照装）
  [ValidateSet('1','2','3','menu','force','check','undo')][string]$Choice = 'menu',
  [string]$MainDir = '',
  [switch]$Force,      # 知情后继续：跳过本脚本的劝退；选项 1/2 会把 -ForceLockedBatch 传给安装器
  [switch]$DryRun,     # 只体检 + 打印将要执行的命令，不落任何写操作
  [switch]$Yes,        # 非交互（配合 -Force 自动放行）
  [int]$MainTimeoutSec = 1800
)
$ErrorActionPreference = 'Continue'

# ---- 以下基础函数抄自 试跑REBAR.ps1（ESP 挂载 / 固件变量 / 启动项构造），逻辑一字未改 ----
function Ln { param([string]$T, [string]$Color = 'Gray') Write-Host $T -ForegroundColor $Color }
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pr = New-Object Security.Principal.WindowsPrincipal($id)
  return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Initialize-FwAccess {
  if ($script:FwTypeLoaded) { return $true }
  $signature = @"
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
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  public static string EnablePrivilege() {
    IntPtr tok;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) { return "OpenProcessToken 失败 " + Marshal.GetLastWin32Error(); }
    LUID luid;
    if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) { return "LookupPrivilegeValue 失败 " + Marshal.GetLastWin32Error(); }
    TP tp = new TP(); tp.Count = 1; tp.Luid = luid; tp.Attributes = 0x2;
    if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) { return "AdjustTokenPrivileges 失败 " + Marshal.GetLastWin32Error(); }
    if (Marshal.GetLastWin32Error() == 1300) { return "AdjustTokenPrivileges 未授予 (1300)"; }
    return "ok";
  }
}
"@
  try { Add-Type -TypeDefinition $signature -ErrorAction Stop | Out-Null } catch { Bad ('编译 FwVar 类型失败: ' + $_.Exception.Message); return $false }
  $r = [FwVarDiag]::EnablePrivilege()
  if ($r -ne 'ok') { Bad ('启用 SeSystemEnvironmentPrivilege 失败: ' + $r + '（360/火绒/联想的「启动项保护/UEFI 保护」会拦，先临时关掉）'); return $false }
  $script:FwTypeLoaded = $true
  return $true
}
function Read-FwVar {
  param([string]$Name)
  $buf = New-Object byte[] 8192
  $len = [FwVarDiag]::GetFirmwareEnvironmentVariableW($Name, $script:FwGuid, $buf, [uint32]$buf.Length)
  if ($len -le 0) { return $null }
  if ($len -gt $buf.Length) {
    $buf = New-Object byte[] ([int]$len)
    $len = [FwVarDiag]::GetFirmwareEnvironmentVariableW($Name, $script:FwGuid, $buf, [uint32]$buf.Length)
    if ($len -le 0 -or $len -gt $buf.Length) { return $null }
  }
  $out = New-Object byte[] ([int]$len)
  [Array]::Copy($buf, $out, $len)
  return $out
}
function Write-FwVar {
  param([string]$Name, [byte[]]$Data)
  $ok = [FwVarDiag]::SetFirmwareEnvironmentVariableW($Name, $script:FwGuid, $Data, [uint32]$Data.Length)
  if (-not $ok) { Bad ('写固件变量 ' + $Name + ' 失败 err=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  return $ok
}
function Remove-FwVar {
  param([string]$Name)
  $empty = New-Object byte[] 0
  $ok = [FwVarDiag]::SetFirmwareEnvironmentVariableW($Name, $script:FwGuid, $empty, [uint32]0)
  return $ok
}
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
  $node = $null
  if ($pathList.Length -ge 4 -and $pathList[0] -eq 0x04 -and $pathList[1] -eq 0x01) {
    $nodeLen = [int]$pathList[2] + 256 * [int]$pathList[3]
    if ($nodeLen -ge 4 -and $nodeLen -le $pathList.Length) { $node = New-Object byte[] $nodeLen; [Array]::Copy($pathList, 0, $node, 0, $nodeLen) }
  }
  return [pscustomobject]@{ Attributes = $attrs; PathLength = $pathLen; Description = (-join $chars.ToArray()); PathList = $pathList; DeviceNode = $node }
}
function Get-AllBootEntries {
  $list = @()
  for ($i = 0; $i -le 255; $i++) {
    $name = 'Boot{0:X4}' -f $i
    $raw = Read-FwVar $name
    if ($raw -and $raw.Length -gt 6) {
      $parsed = ConvertFrom-BootEntry $raw
      if ($parsed) { $list += [pscustomobject]@{ Name = $name; Index = $i; Entry = $parsed } }
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
  # 必修①：与主线 Install-40HXUnlock.ps1 同款 —— 可选数据接在设备路径之后；为空则整段不写（=Boot#### 无可选数据）
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
  $pick = $Part
  if (-not $pick) { return $null }
  $node = New-Object System.Collections.Generic.List[byte]
  $node.Add(0x04); $node.Add(0x01); $node.Add(0x2A); $node.Add(0x00)
  $node.AddRange([BitConverter]::GetBytes([uint32]$pick.PartitionNumber))
  $node.AddRange([BitConverter]::GetBytes([uint64]($pick.Offset / 512)))
  $node.AddRange([BitConverter]::GetBytes([uint64]($pick.Size / 512)))
  $node.AddRange(([Guid]$pick.Guid).ToByteArray())
  $node.Add(0x02); $node.Add(0x02)   # MBRType=GPT, SignatureType=GUID（不是保留位，实测踩过）
  return $node.ToArray()
}
function Get-EspVolumeGuid {
  param([string]$Letter)
  $o = (mountvol $Letter /L 2>&1 | Out-String)
  $m = [regex]::Match($o, '(?i)Volume\{([0-9a-f-]{36})\}')
  if ($m.Success) { return $m.Groups[1].Value.ToLower() }
  return ''
}
# 必修⑤：卸载一个 ESP 盘符并核对结果（mountvol /D 退出码 + 盘符是否真的释放）；$true=已释放、无残留
function Remove-EspLetter {
  param([string]$Letter)
  if (-not $Letter) { return $true }
  $null = (mountvol ($Letter) /D 2>&1)
  $code = $LASTEXITCODE
  $still = Test-Path (($Letter.TrimEnd('\')) + '\')
  return ((-not $still) -and ($code -eq 0))
}
# 必修⑤：ESP 挂载 —— 任何可能写 ESP 的路径（Test-Health / Deploy-ReBar / Undo）都只经这里。
#   ① 挂载前先定出系统盘 ESP 分区（Get-EspPartition），拿它的卷 GUID 当唯一依据；
#   ② 复用的盘符与本次新挂的盘符都必须卷 GUID 一致才接受（GPT 下卷 GUID = 分区 GUID）；
#   ③ 本脚本自己挂上、但核对不通过的盘符必须卸掉；卸不掉就报错并计入失败（$script:EspLeak），绝不留盘符。
function Mount-EspDiag {
  if ($script:EspRoot -and (Test-Path ($script:EspRoot + '\EFI'))) { return $script:EspRoot }
  $script:EspRoot = $null; $script:EspPreMounted = $false   # 必修⑤：每次进入都复位，防上一轮状态串到新盘符
  if (-not $script:EspPart) { $script:EspPart = Get-EspPartition }
  if (-not $script:EspPart) { Wr '定位不到系统盘 ESP 分区（Get-Partition 拿不到）→ 拒绝挂载/写入（防写错卷）'; return $null }
  # 归一化：Get-Partition 的 .Guid 是带大括号的 '{3f0ea28b-...}'，而 mountvol /L 抓出来的是不带括号的
  #   → 两边都必须去括号+小写再比，否则永远不相等、ESP 永远挂不上（2026-10-13 本机实测踩到）
  $wantGuid = ([string]$script:EspPart.Guid).Trim('{', '}').ToLower()
  if (-not $wantGuid) { Wr '系统盘 ESP 分区 GUID 读不到 → 拒绝挂载/写入（防写错卷）'; return $null }
  $letters = @('Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K')
  # 第一轮：复用已挂着的盘符 —— 必须卷 GUID 一致才接受；核不上就跳过，绝不在它上面写
  foreach ($dl in $letters) {
    if ((Test-Path ($dl + ':\EFI\Boot')) -or (Test-Path ($dl + ':\EFI\Microsoft'))) {
      $gotGuid = Get-EspVolumeGuid ($dl + ':')
      if ($gotGuid -eq $wantGuid) { $script:EspRoot = $dl + ':'; $script:EspPreMounted = $true; return $script:EspRoot }
      Wr ('盘符 ' + $dl + ': 里挂着 EFI 目录但不是系统盘 ESP（卷 GUID ' + $(if ($gotGuid) { $gotGuid } else { '读不到' }) + ' ≠ ' + $wantGuid + '）→ 跳过，不动它')
    }
  }
  # 第二轮：新挂空闲盘符 —— 挂上后核对卷 GUID；不匹配/核不上必须卸载，绝不留盘符
  foreach ($dl in $letters) {
    if (Test-Path ($dl + ':\')) { continue }
    $null = (mountvol ($dl + ':') /S 2>&1)
    if (-not ((Test-Path ($dl + ':\EFI\Boot')) -or (Test-Path ($dl + ':\EFI\Microsoft')))) {
      if (Test-Path ($dl + ':\')) {
        if (Remove-EspLetter ($dl + ':')) { Wr ('盘符 ' + $dl + ': 挂上的卷里没有 EFI 目录 → 已卸载该盘符') }
        else { Bad ('盘符 ' + $dl + ': 挂错卷且卸载失败 → 残留盘符（请手动 mountvol ' + $dl + ': /D）'); $script:EspLeak = $true }
      }
      continue
    }
    $gotGuid = Get-EspVolumeGuid ($dl + ':')
    if ($gotGuid -ne $wantGuid) {
      if (Remove-EspLetter ($dl + ':')) { Wr ('盘符 ' + $dl + ': 里的 EFI 目录不是系统盘 ESP（卷 GUID ' + $(if ($gotGuid) { $gotGuid } else { '读不到' }) + ' ≠ ' + $wantGuid + '）→ 已卸载该盘符，继续试下一个') }
      else { Bad ('盘符 ' + $dl + ': 不是系统盘 ESP（卷 GUID 不符）且卸载失败 → 残留盘符（请手动 mountvol ' + $dl + ': /D）'); $script:EspLeak = $true }
      continue
    }
    $script:EspRoot = $dl + ':'; $script:EspPreMounted = $false
    return $script:EspRoot
  }
  return $null
}
# 必修⑤：卸载 ESP 盘符 —— 只卸本脚本自己挂的（别人的挂载不动），并核对 mountvol /D 的退出码与结果
function Dismount-EspDiag {
  if (-not $script:EspRoot) { return $true }
  $ok = $true
  if (-not $script:EspPreMounted) {
    if (-not (Remove-EspLetter $script:EspRoot)) { Bad ('卸载 ESP 盘符 ' + $script:EspRoot + ' 失败（可能残留盘符，请手动 mountvol ' + $script:EspRoot + ' /D）'); $ok = $false }
  }
  $script:EspRoot = $null; $script:EspPreMounted = $false
  return $ok
}
function Ok { param([string]$T) Write-Host ('[OK] ' + $T) -ForegroundColor Green }
function Wr { param([string]$T) Write-Host ('[注意] ' + $T) -ForegroundColor Yellow }
function Bad { param([string]$T) Write-Host ('[失败] ' + $T) -ForegroundColor Red }
# ---- 以上为抄来的基础函数 ----
$script:Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $MainDir) { $MainDir = $script:Here }   # 2026-10-14 并入主线：安装器与本脚本同目录（解压目录任意）
$script:MainDir       = $MainDir
$script:MainInstaller = Join-Path $MainDir 'Install-40HXUnlock.ps1'
$script:MainGen2      = Join-Path $MainDir '一键修复Gen2.ps1'
$script:MainPrime     = Join-Path $MainDir '工具-测试与修复\补写Gen2预埋.ps1'
$script:ReBarEfiSrc   = Join-Path $script:Here 'payload\EFI\40HXUNLK-REBAR.EFI'   # 2026-10-14 并入主线：ReBAR 版 EFI 随包放在 payload\EFI\
$script:LogDir        = Join-Path $script:Here 'logs'
$script:ReBarEfiName  = '40HXUNLK-REBAR.EFI'
$script:ReBarSha      = '9D18D135B5FD5E20EE5D5B5A7DBB7530103D0D2732E25177FA9FA525104684FC'
$script:ReBarDesc     = '40HX Unlock + ReBAR'
$script:ReBarOldDesc  = '40HX REBAR TEST'
$script:ReBarPath     = '\EFI\40HX\40HXUNLK-REBAR.EFI'
$script:MainDesc      = '40HX Unlock'
$script:RcFile        = Join-Path $script:Here '一键解锁40HX-上次退出码.txt'
$script:BkDir         = Join-Path $script:Here 'backup-EFI'
# 复用的固件访问/ESP/启动项函数的脚本级状态
$script:FwGuid        = '{8be4df61-93ca-11d2-aa0d-00e098032b8c}'
$script:FwTypeLoaded  = $false
$script:EspRoot       = $null
$script:EspPreMounted = $false
$script:EspPart       = $null
$script:EspLeak       = $false   # 必修⑤：挂错卷卸不掉时置位，供 Deploy/Undo 计入失败
$script:Ran           = New-Object System.Collections.ArrayList

function Set-Rc { param([int]$Code, [string]$Note = '')
  try { ('exit=' + $Code + $(if ($Note) { '  state=' + $Note } else { '' }) + '  time=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) | Out-File -Encoding ascii -FilePath $script:RcFile -ErrorAction Stop }
  catch { Write-Host ('[注意] 退出码文件写不进去: ' + $_.Exception.Message) -ForegroundColor Yellow }
}
function Info { param([string]$T) Write-Host ('  - ' + $T) }
# r1b（本机实测根因）：同进程里调用 Confirm-SecureBootUEFI 之后，固件变量读会全部失败
#   （探针实证：调用前 BootOrder=050003000200/启动项 4 个，调用后立刻 BootOrder=null/0 个）。
#   ⇒ ① Secure Boot 状态改从注册表读（无副作用）；② 每次动固件变量前重新 EnablePrivilege（不依赖缓存）。
function Re-EnableFwPriv {
  try { $script:FwTypeLoaded = $true; $null = [FwVarDiag]::EnablePrivilege() } catch { }
}
function Add-Ran { param([string]$T) [void]$script:Ran.Add($T) }
function Get-Stamp { return (Get-Date -Format 'yyyyMMdd-HHmmss') }
function Ensure-Dir { param([string]$P) if (-not (Test-Path $P)) { New-Item -ItemType Directory -Force -Path $P | Out-Null } }

# ---- 固件引导顺序（口径与主线 Install-40HXUnlock.ps1 的 Get/Write-BootOrderIndices 完全一致）----
# 设备路径节点式解析（type 4/sub 4 = FilePath），用来把 Boot#### 指向的 .efi 显示出来
function Get-EntryPath {
  param($Entry)
  if (-not $Entry -or -not $Entry.PathList) { return '' }
  $pl = $Entry.PathList; $i = 0
  if ($Entry.DeviceNode) { $i = $Entry.DeviceNode.Length }
  $parts = New-Object System.Collections.ArrayList
  while (($i + 3) -lt $pl.Length) {
    $tp = $pl[$i]; $st = $pl[$i + 1]; $ln = [int][BitConverter]::ToUInt16($pl, $i + 2)
    if ($ln -lt 4 -or ($i + $ln) -gt $pl.Length) { break }
    if ($tp -eq 4 -and $st -eq 4) {
      $sb = New-Object System.Text.StringBuilder
      for ($k = $i + 4; ($k + 1) -lt ($i + $ln); $k += 2) { [void]$sb.Append([char][BitConverter]::ToUInt16($pl, $k)) }
      $s = $sb.ToString().TrimEnd([char]0); if ($s) { [void]$parts.Add($s) }
    }
    $i += $ln
  }
  if ($parts.Count -eq 0) { return '' }
  return (($parts | ForEach-Object { $_.Trim('\') }) -join '\')
}

function Get-BootOrderIndices {
  $raw = Read-FwVar 'BootOrder'
  $list = @()
  if (-not $raw) { return $list }
  for ($i = 0; ($i + 1) -lt $raw.Length; $i += 2) { $list += [int][BitConverter]::ToUInt16($raw, $i) }
  return $list
}
function Format-BootOrderIndices { param([int[]]$Indices) return (($Indices | ForEach-Object { '{0:X4}' -f $_ }) -join ',') }
function Write-BootOrderIndices {
  param([int[]]$Indices, [string]$BackupDir)
  Re-EnableFwPriv
  # 读不到当前 BootOrder 就绝不改写（防止把引导顺序写成只有一项 → 开不了机）
  $cur = Read-FwVar 'BootOrder'
  if (-not $cur -or $cur.Length -lt 2) { Wr '读不到当前 BootOrder → 拒绝改写（防写坏引导顺序）'; return $false }
  if (@($Indices).Count -eq 0) { Wr '新 BootOrder 为空 → 拒绝写入'; return $false }
  if ($BackupDir) {
    try {
      Ensure-Dir $BackupDir
      [IO.File]::WriteAllBytes((Join-Path $BackupDir 'BootOrder.before.bin'), $cur)
      Write-Host ('  - BootOrder 原顺序已备份: ' + (Join-Path $BackupDir 'BootOrder.before.bin'))
    } catch { Wr ('BootOrder 备份失败（' + $_.Exception.Message + '）→ 拒绝改写'); return $false }
  }
  $bytes = New-Object System.Collections.Generic.List[byte]
  foreach ($idx in $Indices) { $bytes.AddRange([BitConverter]::GetBytes([uint16]$idx)) }
  return (Write-FwVar 'BootOrder' $bytes.ToArray())
}

# ---- 调用主线工具（异步 + 超时兜底 + 输出落盘）----
function Invoke-MainTool {
  param([string]$File, [string[]]$ToolArgs, [int]$TimeoutSec = 600, [string]$Tag = 'main')
  $res = @{ Code = -1; Out = ''; Log = '' }
  if (-not (Test-Path $File)) { Wr ('找不到主线工具: ' + $File); return $res }
  Ensure-Dir $script:LogDir
  $log = Join-Path $script:LogDir ($Tag + '-' + (Get-Stamp) + '.txt')
  $res.Log = $log
  Info ('调用: ' + $File + ' ' + ($ToolArgs -join ' '))
  if ($DryRun) { Info '[DryRun] 只打印，不执行'; return $res }
  $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  # r1a：Start-Process 拿不到子进程 ExitCode（本机实测为空）→ 用 cmd 包裹并在结尾打 ###RC=<code>，从日志里读回来
  $inner = 'chcp 936 >nul & "' + $ps + '" -NoProfile -ExecutionPolicy Bypass -File "' + $File + '" ' + ($ToolArgs -join ' ') + ' & echo ###RC=%ERRORLEVEL%'
  try {
    $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -NoNewWindow -PassThru -ErrorAction Stop `
         -ArgumentList @('/c', $inner) `
         -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
  } catch { Wr ('起进程失败: ' + $_.Exception.Message); return $res }
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    Wr ('超过 ' + $TimeoutSec + ' 秒未结束 → 终止'); try { taskkill /T /F /PID $p.Id 2>&1 | Out-Null } catch { }
    try { $p.Kill() } catch { }
    $res.Code = -2; return $res
  }
  if (Test-Path $log) { $res.Out = (Get-Content $log -Raw -ErrorAction SilentlyContinue) }
  $res.Code = -1
  if ($res.Out -match '###RC=(\d+)') { $res.Code = [int]$Matches[1] }
  else { try { $res.Code = $p.ExitCode } catch { } }
  return $res
}

# ---- 体检（只读）----
function Test-Health {
  $H = [ordered]@{}
  $H.Admin = (Test-Admin)
  $H.FwType = $env:firmware_type
  $H.Bar1 = -1; $H.Vbios = ''; $H.Batch = '读不到'; $H.Sb = '读不到'; $H.DevOk = $false; $H.DevCode = ''
  $H.Order = @(); $H.DefaultDesc = ''; $H.ReBarEntry = ''; $H.HasReBarEfi = $false; $H.Retrain = ''
  $H.Above4G = 'unknown'; $H.MmioWin = ''   # 2026-10-14：Above 4G Decoding 的免驱动只读探测结果
  $H.Blockers = New-Object System.Collections.ArrayList
  $H.Warnings = New-Object System.Collections.ArrayList
  $H.Notes    = New-Object System.Collections.ArrayList

  # 1) 主线只读体检（前提：UEFI/GPT/ESP/SecureBoot/BitLocker/卡在位…）
  $H.MainCheck = Invoke-MainTool -File $script:MainInstaller -ToolArgs @('-Mode','Check') -TimeoutSec 300 -Tag '前提体检'
  # 必修④：Code=-1 = 体检进程根本没起来（工具找不到 / Start-Process 失败）—— 不能再当"未执行"放行；
  #   非 DryRun 时必须进 Blockers（这样 -Yes 无 -Force 会在下面 L599 被拦住）。DryRun 是有意不执行，不算。
  if ($H.MainCheck.Code -eq -1) {
    if (-not $DryRun) { [void]$H.Blockers.Add('主线前提体检没能执行（Code=-1：工具找不到或进程起不来）—— 体检没跑过不能放行；详见 ' + $H.MainCheck.Log) }
  } elseif ($H.MainCheck.Code -ne 0) {
    [void]$H.Blockers.Add('主线前提体检返回 ' + $H.MainCheck.Code + '（前提不满足，详见 ' + $H.MainCheck.Log + '）')
  }

  # 2) 本机读数
  $smi = "$env:SystemRoot\System32\nvidia-smi.exe"
  if (Test-Path $smi) {
    $csv = (& $smi --query-gpu=name,vbios_version --format=csv,noheader 2>&1 | Out-String).Trim()
    if ($csv) { $H.Vbios = ($csv -split ',')[1].Trim() }
    $q = (& $smi -q 2>&1 | Out-String)
    $m = [regex]::Match($q, '(?s)BAR1 Memory Usage.*?Total\s*:\s*(\d+)\s*MiB')
    if ($m.Success) { $H.Bar1 = [int]$m.Groups[1].Value }
  }
  # 2026-10-15（用户定稿）：**不再按 VBIOS 版本判定能不能解** —— 2026-10-14 交叉换机实证（案例库 C11）已推翻：
  #   同两张 .06 AS03 卡换到精粤 B660I 全解锁、换到铭瑄 H610ITX 全失败；同镜像不同命运。版本号只当信息记录。
  # 2026-10-14（用户要求：先判断客户机配置与设置再推荐）：Above 4G Decoding 是 ReBAR 的前提 —— 这里做一次**免驱动只读**探测：
  #   取这块卡在系统里被分配的 MMIO 窗口（CIM：Win32_PnPEntity ⇄ CIM_MemoryMappedIO）。
  #   · 存在 ≥ 4 GiB 的窗口 ⇒ 固件已经在用 64 位窗口 ⇒ Above 4G Decoding 生效过的**强证据**（可以推荐带 ReBAR 的选项 2）
  #   · 只看到 < 4 GiB 的窗口 ⇒ 很可能没开（推荐先开它，再选 2）
  #   · 查不到设备/查询失败 ⇒ unknown（保守推荐，不写成“可以开”）
  #   ⚠ 它证明不了“存在一块 8 GiB 对齐的空闲窗口” —— 那一步只有开机那次 EFI 能自证（失败会整体回滚，系统照常启动）。
  try {
    $devp = Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.DeviceID -match 'DEV_1F0B' } | Select-Object -First 1
    if ($devp) {
      $ranges = @(Get-CimAssociatedInstance -InputObject $devp -ResultClassName CIM_MemoryMappedIO -ErrorAction SilentlyContinue)
      $uniq = @($ranges | ForEach-Object { [pscustomobject]@{ S = [uint64]$_.StartingAddress; E = [uint64]$_.EndingAddress } } | Sort-Object S -Unique)
      if ($uniq.Count -gt 0) {
        $H.MmioWin = (($uniq | ForEach-Object { '0x' + $_.S.ToString('X') + '(+' + [int](($_.E - $_.S + 1) / 1MB) + 'MB)' }) -join ' ')
        if (@($uniq | Where-Object { $_.S -ge 0x100000000 }).Count -gt 0) { $H.Above4G = 'yes' } else { $H.Above4G = 'no' }
      }
    }
  } catch { $H.Above4G = 'unknown' }
  if (-not $H.Above4G) { $H.Above4G = 'unknown' }
  # 2026-10-12 r1b：不用 Confirm-SecureBootUEFI —— 它会让本进程之后的固件变量读全部失败（探针实证）。
  #   改读注册表（只读、无副作用）：UEFISecureBootEnabled 1=开 / 0=关；读不到再说。
  try {
    $sbv = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop).UEFISecureBootEnabled
    $H.Sb = $(if ($sbv -eq 1) { 'True（开着）' } elseif ($sbv -eq 0) { 'False（关着）' } else { '(注册表值=' + $sbv + ')' })
  } catch { $H.Sb = '读不到（注册表项缺失）' }
  # 必修③：上面的实值是 'True（开着）'/'False（关着）'（L370），原判定 $H.Sb -eq 'True' 恒不等 → 改前缀匹配；
  #   并按主线口径（主线 $rep.SecureBoot -eq $true 即 Blocker）把它作为 Blocker，而不是只打一行提示。
  if ($H.Sb -match '^True') { [void]$H.Blockers.Add('Secure Boot 开着 —— 主线把它当硬门槛；选项 2 的解锁/ReBAR EFI 未签名，Secure Boot 会拒绝加载（先进 BIOS 关 Secure Boot 再装，或 -Force 知情强制）') }
  $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'DEV_1F0B' } | Select-Object -First 1
  if ($dev) {
    $H.DevOk = $true
    $pc = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
    $H.DevCode = $(if ($null -eq $pc) { '0' } else { [string]$pc })
    if ($H.DevCode -ne '0') { [void]$H.Warnings.Add('设备管理器状态码 = ' + $H.DevCode + '（43 = 驱动没起来，先按排查指引处理）') }
  } else { [void]$H.Blockers.Add('没找到 CMP 40HX（DEV_1F0B）—— 卡不在位或驱动没装') }
  if (-not $H.DevOk) { }

  # 3) 引导顺序 / 现有启动项（需要管理员 + 固件访问）
  if ($H.Admin -and (Initialize-FwAccess)) {
    Re-EnableFwPriv   # r1b：动固件变量前重新开特权（防上面的只读操作把特权状态带跑）
    $entries = Get-AllBootEntries
    $H.Order = Get-BootOrderIndices
    $rebar = @($entries | Where-Object { $_.Entry.Description -eq $script:ReBarDesc -or $_.Entry.Description -eq $script:ReBarOldDesc })
    if ($rebar.Count -gt 0) { $H.ReBarEntry = ($rebar | Select-Object -First 1).Name }
    if ($H.Order.Count -gt 0) {
      $first = @($entries | Where-Object { $_.Index -eq $H.Order[0] })
      if ($first.Count -gt 0) {
        $p = Get-EntryPath $first[0].Entry
        $H.DefaultDesc = [string]$first[0].Entry.Description + $(if ($p) { ' → ' + $p } else { '' })
      }
    }
  } else { [void]$H.Warnings.Add('非管理员：读不到固件启动项/BootOrder（体检不完整）') }
  $esp = Mount-EspDiag
  if ($esp) {
    if (Test-Path (Join-Path $esp ($script:ReBarPath.TrimStart('\')))) { $H.HasReBarEfi = $true }
    [void](Dismount-EspDiag)
  } else { [void]$H.Warnings.Add('ESP 挂不上：体检不完整（多盘机器可能需手动指定）') }

  # 4) Windows 侧 Gen2 现状
  $glog = Join-Path $env:ProgramData 'CMP40HXGen2\windows\logs\retrain-last.log'
  if (Test-Path $glog) {
    $g = Get-Content $glog -Raw
    $lines = ($g -split "`r?`n") | Where-Object { $_ -match 'PASS:|EXIT=|PRIMER_GAPS|GUARD' }
    $H.Retrain = (($lines | Select-Object -Last 2) -join ' | ')
  } else { $H.Retrain = '(还没有 retrain-last.log)' }

  # 5) ReBAR 可行性结论（只能"提示 + 首次开机自证"）
  [void]$H.Notes.Add('装前无法证明主板能不能开 ReBAR：需 Above 4G Decoding 打开 + 一块空闲的 64 位 MMIO 窗口。')
  [void]$H.Notes.Add('第 1 次开机会自证：EFI 里任一步失败会整体回滚，系统照常启动（只是 ReBAR 没开）。')
  if ($H.Bar1 -eq 64) { [void]$H.Notes.Add('当前 BAR1 = 64 MiB（nvidia-smi 口径）→ ReBAR 没开。能不能开看上面那条“Above 4G Decoding”的证据，最终由开机自证。') }
  elseif ($H.Bar1 -eq 8192) { [void]$H.Notes.Add('当前 BAR1 = 8192 MiB（nvidia-smi 口径）→ ReBAR 现在就开着。') }
  elseif ($H.Bar1 -gt 0) { [void]$H.Notes.Add('当前 BAR1 = ' + $H.Bar1 + ' MiB（非常见值：64/8192）—— 可能是 BIOS 侧 Re-Size BAR 部分生效。') }
  return $H
}

# 2026-10-14（用户要求）：把"必须先去改的设置项"讲到能照着做 —— 每条都点名 BIOS 里的关键词/常见路径，
#   并告诉客户还有一条出口：菜单选 x = 我先去改，改完重跑本入口（什么都不改）。
function Show-SetupHints {
  param($H)
  $must = New-Object System.Collections.ArrayList
  $nice = New-Object System.Collections.ArrayList
  if ($H.Sb -match '^True') { [void]$must.Add('Secure Boot = 开着 → 未签名的解锁固件不会被执行：BIOS 里 Security → Secure Boot = Disabled（老华硕选 Other OS）') }
  if ($H.FwType -and $H.FwType -ne 'UEFI') { [void]$must.Add('固件不是 UEFI 模式（' + $H.FwType + '）→ BIOS 里关 CSM；系统盘要是 GPT（MBR 盘先用 工具-测试与修复\MBR转GPT.cmd 转）') }
  if (-not $H.DevOk) { [void]$must.Add('没找到 CMP 40HX（DEV_1F0B）→ 插紧/换槽；NVIDIA 驱动没装也要先装') }
  if ($H.DevOk -and $H.DevCode -ne '0' -and $H.DevCode -ne '') { [void]$must.Add('40HX 设备状态码 = ' + $H.DevCode + '（43 = 驱动没起来）→ 先双击 GSP体检.cmd，然后【完全关机】再开机（不是重启）') }
  if ($H.Above4G -eq 'no') { [void]$nice.Add('Above 4G Decoding 无证据（只看到 4G 以下窗口）→ 想开 ReBAR 就先打开它。关键词搜 Above 4G / 4G Decoding / Above 4G memory；华硕 Advanced→System Agent(SA) Configuration、技嘉 Settings→IO Ports、微星 Settings→Advanced→PCI Subsystem Settings、华擎 Advanced→Chipset Configuration（BIOS 里的 Re-Size BAR Support 开关在这条路径上不是必需的）') }
  elseif ($H.Above4G -eq 'unknown') { [void]$nice.Add('Above 4G Decoding 读不到（这台机器上 CIM 查询失败）→ 不确定就先别选带 ReBAR 的选项；想试就选 2，第一次开机会自证（失败整体回滚，系统照常启动）') }
  if ($H.Retrain -and ($H.Retrain -match 'EXIT=1[01]|FAIL|not reached')) { [void]$nice.Add('上一次 Gen2 没到（' + $H.Retrain + '）→ 若该 x16 槽的 PCIe 速率被锁在 Gen1，去 BIOS 设成 Auto（关键词 PCIe Speed / Link Speed）；另外要确认卡插在 x16 槽上') }
  [void]$nice.Add('装完第一次开机**必须看到 40HX 跑码界面**（先闪几行解锁固件文字再进 Windows）；没看到就查三项：启动顺序里 40HX 项排第一位、CSM 关、Fast Boot 关')
  if ($must.Count -eq 0 -and $nice.Count -eq 0) { return }
  Ln ''
  Ln '---- 设置项体检（这些不改，装了也看不到效果）----' 'Cyan'
  foreach ($m in $must) { Ln ('  [必改] ' + $m) 'Red' }
  foreach ($n in $nice) { Ln ('  [建议] ' + $n) 'Yellow' }
  Ln '  → 改完回来重跑本入口即可（菜单里也可以按 x：先退出、什么都不改）'
}

# 2026-10-14（用户拍板：体检阶段不加载驱动）：改成"选了 2 → 主线安装把驱动铺好之后"再跑一次**只读**探测
#   （工具不带 -Apply = 零写），从输出里取 BAR0 基址：≥ 4 GiB ⇒ 固件确实把设备 BAR 放在 4G 以上（Above 4G 强证据）。
#   失败/读不到只告警，不阻断 —— 新检查默认"告警 + 继续"。
function Invoke-BarProbe {
  $tool = Join-Path $script:Here 'payload\windows\40hx-retrain-inpout.ps1'
  if (-not (Test-Path -LiteralPath $tool)) { Wr ('BAR 只读探测跳过：包里没有 ' + $tool); return }
  $out = ''
  try { $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -AllowPrime 2>&1 | Out-String) }
  catch { Wr ('BAR 只读探测没能跑起来: ' + $_.Exception.Message + '（不影响本次部署，开机自证会给最终结果）'); return }
  $m = [regex]::Match($out, 'BAR0 \(validated\)\s*=\s*0x([0-9A-Fa-f]+)')
  if (-not $m.Success) { Wr 'BAR 只读探测：没拿到 BAR0 基址（驱动没起来 / 设备没打开）—— 不影响本次部署，开机自证会给最终结果'; return }
  $base = [uint64]('0x' + $m.Groups[1].Value)
  if ($base -ge 0x100000000) { Ok ('BAR 只读探测：BAR0 基址 = 0x' + $base.ToString('X') + ' → **在 4 GiB 以上**，固件确实在用 64 位窗口（ReBAR 的前提成立）') }
  else { Wr ('BAR 只读探测：BAR0 基址 = 0x' + $base.ToString('X') + ' → 还在 4 GiB 以下（Above 4G Decoding 很可能没开）→ 本次 ReBAR 大概率会回滚，登录后看 ESP 的 40hx_log.txt 里的原因') }
}

function Show-Health {
  param($H)
  Ln ''
  Ln '==== 体检（只读）====' 'Cyan'
  Ln ('  管理员: ' + $(if ($H.Admin) { '[OK] 是' } else { '[失败] 否（必须管理员运行）' }))
  Ln ('  固件类型: ' + $(if ($H.FwType -eq 'UEFI') { '[OK] UEFI' } else { '[注意] ' + $H.FwType + '（本方案要求 UEFI）' }))
  Ln ('  主线前提体检: ' + $(if ($H.MainCheck.Code -eq 0) { '[OK] 通过' } elseif ($H.MainCheck.Code -eq -1) { $(if ($DryRun) { '[注意] 未执行（DryRun）' } else { '[失败] 没执行（找不到工具或进程起不来）' }) } else { '[注意] 退出码 ' + $H.MainCheck.Code + '（见 ' + $H.MainCheck.Log + '）' }))
  Ln ('  40HX 设备: ' + $(if ($H.DevOk) { '[OK] 在位，状态码 ' + $H.DevCode } else { '[失败] 没找到' }))
  Ln ('  VBIOS: ' + $(if ($H.Vbios) { $H.Vbios } else { '读不到' }) + '  （仅记录用：本包**不按 VBIOS 版本**判定能不能解）')
  Ln ('  BAR1（ReBAR 现状）: ' + $(if ($H.Bar1 -gt 0) { $H.Bar1.ToString() + ' MiB' } else { '读不到' }))
  Ln ('  Above 4G Decoding: ' + $(if ($H.Above4G -eq 'yes') { '[OK] 有证据（这块卡在 4G 以上有 MMIO 窗口 ' + $H.MmioWin + '）' } elseif ($H.Above4G -eq 'no') { '[注意] 无证据（只看到 4G 以下窗口 ' + $H.MmioWin + '）→ ReBAR 前提很可能没开' } else { '[注意] 读不到（CIM 查询失败）→ 按未知处理' }))
  Ln ('  Secure Boot: ' + $H.Sb + $(if ($H.Sb -match '^True') { '  ← 主线把它当硬门槛；选 2 需先关掉（或 -Force 知情强制）' } else { '' }))
  Ln ('  当前默认启动项: ' + $(if ($H.DefaultDesc) { $H.DefaultDesc } else { '读不到' }) + $(if ($H.Order.Count -gt 0) { '   BootOrder=' + (Format-BootOrderIndices $H.Order) } else { '' }))
  Ln ('  ReBAR 启动项: ' + $(if ($H.ReBarEntry) { $H.ReBarEntry + '（已存在，会复用）' } else { '还没有（首次部署时创建）' }) + '   ESP 上的 ReBAR EFI: ' + $(if ($H.HasReBarEfi) { '有' } else { '无' }))
  Ln ('  Gen2 现状: ' + $H.Retrain)
  foreach ($b in $H.Blockers) { Ln ('  [阻塞] ' + $b) 'Red' }
  foreach ($w in $H.Warnings) { Ln ('  [注意] ' + $w) 'Yellow' }
  foreach ($n in $H.Notes) { Ln ('  [说明] ' + $n) }
}

function Get-Advice {
  param($H)
  # 2026-10-15（用户定稿）：**不再按 VBIOS 版本判定** —— 2026-10-14 交叉换机实证（C11）表明能解与否由平台/主板决定，
  #   版本号（.04/.06）已被反例推翻（同镜像不同命运、同卡换板结局翻转）。现在的判据只有三条：
  #   顺序：ReBAR 现状（BAR1=8192）→ 设备状态码（≠0 推 r）→ 阻塞项（推 r）→ Above 4G 有没有证据（有=2 / 无或未知=1）。
  #   卡坏或环境不达标时先让人去修（r），Above 4G 只决定"要不要带 ReBAR"。**只影响"回车默认选哪个"**，菜单永远列全部 6 项。
  if ($H.Bar1 -eq 8192) {
    return @{ Recommended = '2'; Why = '本机 ReBAR 现在就开着（BAR1=8192 MiB，设备窗口 ' + $H.MmioWin + '）→ 选 2 保持现状；选 1 会把启动项换回主线 EFI、ReBAR 会关掉。' }
  }
  if ($H.DevOk -and $H.DevCode -ne '0' -and $H.DevCode -ne '') {
    return @{ Recommended = 'r'; Why = '卡在设备管理器里有状态码 ' + $H.DevCode + '（43 = 驱动没起来）→ 先按上面提示修好（GSP / 完全关机再开机）再装，否则装完也看不到效果。' }
  }
  if ($H.Blockers.Count -gt 0) {
    return @{ Recommended = 'r'; Why = '体检有阻塞项（见上面红字）→ 先把它们处理干净（最常见是 Secure Boot 没关）再装；现在装大概率白跑一次。确认要硬试就选 1/2/f。' }
  }
  if ($H.Above4G -eq 'yes') {
    return @{ Recommended = '2'; Why = '有 Above 4G 证据（这块卡在 4G 以上有 MMIO 窗口 ' + $H.MmioWin + '）→ 推荐算力 + Gen2 + ReBAR 一起开（第一次开机会自证，失败会整体回滚）。' }
  }
  if ($H.Above4G -eq 'no') {
    return @{ Recommended = '1'; Why = '没看到 4G 以上的窗口（Above 4G Decoding 很可能没开）→ 先选 1（算力+Gen2）；想开 ReBAR 就先去 BIOS 打开 Above 4G 再回来选 2。' }
  }
  return @{ Recommended = '1'; Why = 'Above 4G 读不到（未知）+ 没发现阻塞项 → 按保守推荐：算力 + Gen2（想连 ReBAR 一起试就直接选 2，第一次开机会自证，失败整体回滚）。' }
}

function Show-ReBarRisks {
  Ln ''
  Ln '---- 选项 2（ReBAR 8 GiB）必须知情的事 ----' 'Yellow'
  Ln '  1) ReBAR 只能在 EFI 阶段开（Windows 侧热启用实测死路）→ 要改的是开机固件路径，不是装个驱动。'
  Ln '  2) 主板前提：Above 4G Decoding 打开 + 有一块空闲的 64 位 MMIO 窗口放得下 8 GiB 对齐空间。'
  Ln '     不满足时 EFI 会整体回滚 —— 系统照常启动，只是 ReBAR 没开（不会黑屏、不会进不去系统）。'
  Ln '     （"BIOS 里的 Re-Size BAR Support 没开"不影响本方式，但 Above 4G Decoding 必须开。）'
  Ln '  3) 本方式目前只在作者本机验证过（B560M + 1 张 40HX + 驱动 616.92）：r8-C1 版 EFI 于 2026-10-13'
  Ln '     开机实测过 [rebar] BAR1 8 GiB active；其它主板/驱动/多卡、长时间负载、游戏+反作弊（ACE）场景都还没实测。'
  Ln '  4) 装完会把它设为第一启动项（长期生效）；BIOS 重置/主板固件更新后可能需要重装一次。'
  Ln '  5) 随时可退：-Choice undo 撤掉本方案（切回主线 EFI / 删 ReBAR 启动项与文件）。'
}

function Deploy-ReBar {
  param([switch]$AsDefault)
  $src = $script:ReBarEfiSrc
  if (-not (Test-Path $src)) { Bad ('缺 ReBAR EFI: ' + $src); return $false }
  $sha = (Get-FileHash $src -Algorithm SHA256).Hash
  if ($sha -ne $script:ReBarSha) { Bad ('ReBAR EFI 哈希与冻结值不符（包被改过？）: ' + $sha); return $false }
  Ok ('ReBAR EFI 哈希门禁通过: ' + $sha)
  $script:EspLeak = $false   # 必修⑤：本次挂载阶段是否有盘符没卸掉
  $esp = Mount-EspDiag
  if (-not $esp) { Bad 'ESP 挂不上'; return $false }
  if ($script:EspLeak) { [void](Dismount-EspDiag); Bad '挂载 ESP 时挂错卷且有盘符没能卸载（已计入本次失败）→ 先手动 mountvol <盘符>: /D 清干净再重跑'; return $false }
  $dst = Join-Path ($esp + '\') ($script:ReBarPath.TrimStart('\'))
  $dir = Split-Path -Parent $dst
  Ensure-Dir $dir
  if ($DryRun) { Info ('[DryRun] 将写 ' + $dst) } else {
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $rb = (Get-FileHash $dst -Algorithm SHA256).Hash
    if ($rb -ne $sha) { Bad '写入后回读哈希不一致'; [void](Dismount-EspDiag); return $false }
    Ok ('已写到 ' + $dst + '（回读一致）')
  }
  # 启动项：复用或新建
  Re-EnableFwPriv
  $entries = Get-AllBootEntries
  $exist = @($entries | Where-Object { $_.Entry.Description -eq $script:ReBarDesc -or $_.Entry.Description -eq $script:ReBarOldDesc })
  if ($exist.Count -gt 0) {
    $index = ($exist | Select-Object -First 1).Index
    $name = ($exist | Select-Object -First 1).Name
    Ok ('已有启动项 ' + $name + '（复用）')
  } else {
    $tpl = @($entries | Where-Object { $_.Entry.Description -eq $script:MainDesc })
    if ($tpl.Count -eq 0) { $tpl = @($entries | Where-Object { $_.Entry.Description -match 'Windows Boot Manager' }) }
    if ($tpl.Count -eq 0) { Bad '没有可参考的启动项，无法构造设备路径（先跑 选项 1 / 主线安装）'; [void](Dismount-EspDiag); return $false }
    $index = Get-FreeBootSlot $entries
    if ($index -lt 0) { Bad '没有空闲 Boot#### 槽位'; [void](Dismount-EspDiag); return $false }
    $name = 'Boot{0:X4}' -f $index
    $attrs = [uint32]$tpl[0].Entry.Attributes
    $node = $tpl[0].Entry.DeviceNode
    if (-not $node -or -not $node.Length) { Bad '参考启动项的设备路径为空 → 拒绝构造（防写坏）'; [void](Dismount-EspDiag); return $false }
    $bytes = New-BootEntryBytes -DeviceNode $node -Description $script:ReBarDesc -EfiPath $script:ReBarPath -Attributes $attrs -OptionalData $null
    if ($DryRun) { Info ('[DryRun] 将新建 ' + $name + '（' + $bytes.Length + ' 字节）→ ' + $script:ReBarPath) }
    else {
      if (-not (Write-FwVar $name $bytes)) { Bad ('写 ' + $name + ' 失败（安全软件拦固件？）'); [void](Dismount-EspDiag); return $false }
      $rback = Read-FwVar $name
      if (-not $rback -or [Convert]::ToBase64String($rback) -ne [Convert]::ToBase64String($bytes)) { Bad ('回读不一致 ' + $name); [void](Dismount-EspDiag); return $false }
      Ok ('已建启动项 ' + $name + ' 并逐字节回读一致')
    }
  }
  $dmOk = Dismount-EspDiag   # 必修⑤：核对 mountvol /D 的退出码与结果
  if (-not $dmOk) { Bad 'ESP 盘符卸载失败（盘符可能残留）→ 本次按失败计' }
  if ($AsDefault) {
    $order = Get-BootOrderIndices
    if (@($order).Count -eq 0) { Bad '读不到 BootOrder → 拒绝改引导顺序'; return $false }
    if ($order[0] -eq $index) { Ok ('BootOrder 第一位已经是 ' + ('{0:X4}' -f $index)) }
    else {
      $newOrder = @($index) + @($order | Where-Object { $_ -ne $index })
      if ($DryRun) { Info ('[DryRun] BootOrder: ' + (Format-BootOrderIndices $order) + ' → ' + (Format-BootOrderIndices $newOrder)) }
      else {
        if (Write-BootOrderIndices -Indices $newOrder -BackupDir $script:BkDir) {
          $rb = Get-BootOrderIndices
          if ((Format-BootOrderIndices $rb) -eq (Format-BootOrderIndices $newOrder)) { Ok ('BootOrder 现在 = ' + (Format-BootOrderIndices $rb) + '（原顺序已备份到 backup-EFI\BootOrder.before.bin）') }
          else { Bad ('BootOrder 回读不符: ' + (Format-BootOrderIndices $rb)); return $false }
        } else { Bad 'BootOrder 写失败'; return $false }
      }
    }
    if (Read-FwVar 'BootNext') { if ($DryRun) { Info '[DryRun] 将清 BootNext' } else { Remove-FwVar 'BootNext' | Out-Null; Ok '已清 BootNext（长期生效靠 BootOrder，不需要一次性）' } }
  }
  if (-not $dmOk) { return $false }
  return $true
}

function Undo-ReBar {
  Re-EnableFwPriv
  $script:EspPart = Get-EspPartition
  $script:EspLeak = $false
  $undoFail = $false   # 必修②：任一关键步失败即置位，最后用非 0 退出码报"部分失败"
  $entries = Get-AllBootEntries
  $mine = @($entries | Where-Object { $_.Entry.Description -eq $script:ReBarDesc -or $_.Entry.Description -eq $script:ReBarOldDesc })
  $delOk = $true       # 必修②：启动项是否"全部"删成功 —— 没全删成功就不许删 ESP 文件
  $delIdx = @()        # 已删掉的 Boot#### 槽位（给 BootOrder 剔除用）
  foreach ($e in $mine) {
    if (Remove-FwVar $e.Name) { Ok ('已删启动项 ' + $e.Name); $delIdx += $e.Index }
    else { Bad ('删 ' + $e.Name + ' 失败（会留下指向已删文件的启动项）'); $delOk = $false; $undoFail = $true }
  }
  if ($mine.Count -eq 0) { Ok '没有 ReBAR 启动项（本来就没有）' }
  if ($delOk) {
    $esp = Mount-EspDiag
    if ($esp) {
      $f = Join-Path ($esp + '\') ($script:ReBarPath.TrimStart('\'))
      if (-not (Test-Path $f)) { Ok 'ESP 上没有 ReBAR EFI（本来就没有）' }
      elseif ($DryRun) { Info ('[DryRun] 将删 ' + $f) }
      else {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $f) { Bad ('删 ' + $f + ' 失败（文件仍在）'); $undoFail = $true } else { Ok ('已删 ' + $f) }
      }
      if (-not (Dismount-EspDiag)) { Bad 'ESP 盘符卸载失败（计入本次失败）'; $undoFail = $true }
    } else { Bad 'ESP 挂不上 → ReBAR EFI 文件没能删（计入本次失败）'; $undoFail = $true }
  } else { Bad '有启动项没删掉 → 已跳过删 ESP 文件（避免留下"启动项指向已删文件"）' }
  foreach ($t in @('REBAR Verify (one-shot)','REBAR Soak Log')) {
    $o = (schtasks /delete /tn $t /f 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) { Ok ('已删计划任务「' + $t + '」') } else { Info ('计划任务「' + $t + '」不存在或删失败: ' + ($o -replace "`r?`n",' ')) }
  }
  $bk = Join-Path $script:BkDir 'BootOrder.before.bin'
  if (Test-Path $bk) {
    $raw = [IO.File]::ReadAllBytes($bk)
    $list = @(); for ($i = 0; ($i + 1) -lt $raw.Length; $i += 2) { $list += [int][BitConverter]::ToUInt16($raw, $i) }
    if ($DryRun) { Info ('[DryRun] 将把 BootOrder 还原成 ' + (Format-BootOrderIndices $list)) }
    elseif (Write-FwVar 'BootOrder' $raw) { Ok ('BootOrder 已还原成 ' + (Format-BootOrderIndices $list)) }
    else { Bad 'BootOrder 还原失败（进 BIOS 手动把 Windows Boot Manager 排第一）'; $undoFail = $true }
  } else {
    # 必修②：没有备份 → 把已删的槽位从当前 BootOrder 里剔除再写回（留 stale 引用会让固件找不到启动项）
    if (@($delIdx).Count -gt 0) {
      Wr ('没有 BootOrder 备份 → 从当前 BootOrder 里剔除已删槽位 ' + (Format-BootOrderIndices ([int[]]$delIdx)))
      $cur = Get-BootOrderIndices
      if (@($cur).Count -eq 0) { Bad '读不到当前 BootOrder → 无法剔除已删槽位（BootOrder 可能仍指向已删启动项）'; $undoFail = $true }
      else {
        $new = @($cur | Where-Object { $delIdx -notcontains $_ })
        if (@($new).Count -eq 0) { Bad '剔除后 BootOrder 为空 → 拒绝写入（进 BIOS 手动排序）'; $undoFail = $true }
        elseif ($DryRun) { Info ('[DryRun] BootOrder: ' + (Format-BootOrderIndices $cur) + ' → ' + (Format-BootOrderIndices $new)) }
        elseif (Write-BootOrderIndices -Indices $new -BackupDir $null) {
          $rb = Get-BootOrderIndices
          if ((Format-BootOrderIndices $rb) -eq (Format-BootOrderIndices $new)) { Ok ('BootOrder 已剔除已删槽位: ' + (Format-BootOrderIndices $rb)) }
          else { Bad ('BootOrder 回读不符: ' + (Format-BootOrderIndices $rb)); $undoFail = $true }
        } else { Bad 'BootOrder 剔除已删槽位写回失败（可能仍指向已删启动项）'; $undoFail = $true }
      }
    } else { Wr '没有 BootOrder 备份（backup-EFI\BootOrder.before.bin 不存在）→ 引导顺序保持现状；要切回主线 EFI 请跑 -Choice 1 再跑一次主线安装' }
  }
  if ($script:EspLeak) { Bad '挂载 ESP 时有盘符没能卸载（残留盘符）'; $undoFail = $true }
  if ($undoFail) { Bad '撤销未能全部完成：有 [失败] 行（启动项/ESP 文件/BootOrder 可能不一致，见上面逐条）'; return $false }
  Ok '撤销完成（算力解锁的 EFI/启动项没动 —— 要连它一起撤，跑主线 -Mode Uninstall -Yes）'
  return $true
}

function Show-NextSteps {
  param([string]$Choice)
  Ln ''
  Ln '==== 下一步 ====' 'Cyan'
  if ($Choice -eq '3') {
    Ln '1. 完全关机再开机（不是重启）；开机后跑 一键修复Gen2 或等开机任务自己跑完（1~3 分钟）'
    Ln '2. 双击主线的 状态自检.bat 复核 Gen2（[3/5] 带宽判定）；算力这版**不解**（要在 BIOS 里解的话选选项 1/2）'
  } else {
    Ln '1. 重启（或完全关机再开）—— 这次开机由固件启动项跑解锁固件（选项 1 = 主线 EFI；选项 2 = ReBAR 版）'
    Ln '2. 看屏幕跑码：绿=该步成功；选项 2 应看到 [rebar] BAR1 8 GiB active'
    Ln '3. 登录后 1~2 分钟可跑主线 状态自检.bat：选项 2 的 [1/5] 区块里 ReBAR 行会显示 已启用（BAR1=8192 MiB）'
    if ($Choice -eq '2') { Ln '4. 想长期试跑：保持选项 2 的启动顺序即可；要退回主线 EFI：-Choice 1（或 -Choice undo）' }
  }
}

# ================================ 主流程 ================================
Set-Rc 999 'RUNNING'
Ln '============================================================' 'Cyan'
Ln ' 一键解锁 40HX（算力 + Gen2 + ReBAR）—— 1 算力+Gen2 / 2 +ReBAR / 3 只 Gen2' 'Cyan'
Ln '============================================================' 'Cyan'
Info ('本脚本目录: ' + $script:Here)
Info ('主项目目录: ' + $script:MainDir)
if (-not (Test-Path $script:MainInstaller)) { Bad ('找不到主项目安装器: ' + $script:MainInstaller + '（用 -MainDir 指定）'); Set-Rc 3 'mainline-missing'; exit 3 }
if (-not (Test-Admin)) { Bad '必须管理员运行（双击 一键解锁40HX.bat 会自动提权）'; Set-Rc 2 'not-admin'; exit 2 }
if (-not (Initialize-FwAccess)) { Bad '固件变量访问初始化失败（安全软件的启动项保护？）'; Set-Rc 2 'fw-access'; exit 2 }

if ($Choice -eq 'undo') { Ln ''; Ln '== 撤销 ReBAR 部署（菜单选项 2 的 ReBAR 部分）==' 'Cyan'; if (Undo-ReBar) { Set-Rc 0 'undo-done'; exit 0 } else { Ln ''; Ln '撤销未能全部完成（上面有 [失败] 行）—— 请按提示手工收尾' 'Red'; Set-Rc 6 'undo-partial'; exit 6 } }

$H = Test-Health
Show-Health $H
Show-SetupHints $H   # 2026-10-14：必须先讲清"哪些设置项要先去改、去哪改"
$adv = Get-Advice $H
Ln ''
Ln ('★ 本机推荐: 选项 ' + $adv.Recommended + ' —— ' + $adv.Why) 'Cyan'
Ln '  （体检结论只读、不碰硬件；推荐项是给你省事，装什么由你定）'

if ($Choice -eq 'check') { Set-Rc 0 'check-only'; exit 0 }

# ============ 菜单（2026-10-14 起在主入口里：先体检、给推荐，再让你选）============
if ($Choice -eq 'menu' -or $Choice -eq 'force') {
  $selNow = ''
  if ($Choice -eq 'force') { $selNow = '1'; $Force = $true }
  elseif ($Yes) { $selNow = [string]$adv.Recommended }
  else {
    Ln ''
    Ln '---- 要做什么？（直接回车 = 上面那个推荐项）----' 'Cyan'
    Ln '  1  解锁算力 + Gen2                （主线路径：算力 + Gen2，绝大多数机器选它）'
    Ln '  2  解锁算力 + Gen2 + ReBAR 8GiB   （选做；ReBAR 已开着的机器用这个保持）'
    Ln '  3  只解锁 Gen2                    （只想先要 Gen2 / 不想动算力和 ESP 启动项时选它）'
    Ln '  f  强行解锁算力                   （连锁死批次/没见过的批次也照装 —— 我们还没找到解不开的根因，留这条路）'
    Ln '  r  只体检（什么都不改）'
    Ln '  u  撤销 ReBAR 部署（切回主线 EFI、删 ReBAR 启动项与文件）'
    Ln '  x  我先去 BIOS 改上面那些设置项（改完重跑本入口；现在什么都不改）'
    for ($try = 1; $try -le 3; $try++) {
      $ans = Read-Host ('  输入 1 / 2 / 3 / f / r / u / x 后回车（回车 = ' + [string]$adv.Recommended + '）')
      if ([string]::IsNullOrWhiteSpace($ans)) { $selNow = [string]$adv.Recommended; break }
      $a = $ans.Trim().ToLower()
      if ($a -in @('1','2','3','f','force','r','check','u','undo','x')) { $selNow = $a; break }
      Wr ('输入 "' + $ans + '" 不认识（只认 1 / 2 / 3 / f / r / u / x）')
    }
    if (-not $selNow) { Bad '连续 3 次输入都不认识 → 什么都没改，退出；重跑本入口即可'; Set-Rc 2 'bad-menu-choice'; exit 2 }
  }
  if ($selNow -eq 'x') { Ln ''; Ln '好 —— 去 BIOS 改上面的设置项，改完回 Windows 再双击 一键解锁40HX.bat（本次什么都没改）。' 'Green'; Set-Rc 0 'user-go-bios'; exit 0 }
  if ($selNow -eq 'f' -or $selNow -eq 'force') { $selNow = '1'; $Force = $true }
  if ($selNow -eq 'u' -or $selNow -eq 'undo') { Ln ''; Ln '== 撤销 ReBAR 部署（选项 u）==' 'Cyan'; if (Undo-ReBar) { Set-Rc 0 'undo-done'; exit 0 } else { Ln ''; Ln '撤销未能全部完成（上面有 [失败] 行）—— 请按提示手工收尾' 'Red'; Set-Rc 6 'undo-partial'; exit 6 } }
  if ($selNow -eq 'r' -or $selNow -eq 'check') { Ln ''; Ln '只体检：什么都没改。' 'Green'; Set-Rc 0 'check-only'; exit 0 }
  $Choice = [string]$selNow
  if ($Force) {
    Ln ''
    Ln '==== 强行解锁（你选了强制）====' 'Yellow'
    Ln '  · 连锁死批次 / 没见过的批次，本包都不再劝退，装完由这次开机自证。'
    Ln '  · 2026-10-14 交叉换机实证：同一张卡换一块主板就从「全失败」变「一次 attempt 就解锁」→ 解不开多半在平台/主板'
    Ln '    （BIOS 三项 / BIOS 太老 / 64 位地址解码），不按 VBIOS 版本判卡；所以留这条路。'
    Ln '  · 风险：开机跑码阶段可能把卡留在异常态 → 设备管理器 代码 43；自救 = 双击 一键卸载.cmd，'
    Ln '    或进 BIOS 把 Windows Boot Manager 排回第一启动项（40HX 项不跑就没有 43，Windows 侧 Gen2 工具照常工作）。'
    Ln '  · 前提硬门槛（Secure Boot / BitLocker / MBR 盘）仍会拦 —— 那几项不处理，装了也不生效。'
    if ($Choice -eq '1') { Ln '  · 本次会给主线安装器带上 -ForceLockedBatch（锁死批次也照装）。' }
  }
  Ln ''
  Ln ('== 你的选择：' + $Choice + $(if ($Force) { '（强制）' } else { '' }) + ' ==') 'Cyan'
}

if ($Choice -eq '2') {
  Show-ReBarRisks
  $blocked = ($H.Blockers.Count -gt 0)
  if ($blocked -or $H.Warnings.Count -gt 0) {
    if ($Force) { Wr '按 -Force 继续（体检有阻塞/注意项，风险已知情）' }
    else {
      Wr '体检没全过 —— 现在装选项 2 有风险（上面逐条列了）'
      if ($Yes) { Bad '非交互模式且没给 -Force → 不自动放行，退出（要强行装请加 -Force）'; Set-Rc 2 'need-force'; exit 2 }
      $ans = Read-Host '确实要强制装吗？输入 FORCE 回车继续，其它任意键退出'
      if ($ans -ne 'FORCE') { Ln ''; Ln '已按体检建议停下，什么也没改。建议：选 1（主线路径）或先处理上面的阻塞项。' 'Yellow'; Set-Rc 0 'user-abort'; exit 0 }
      Wr '用户执意继续（FORCE）—— 已告知风险，继续执行'
    }
  }
}

Ln ''
Ln ('== 开始执行：选项 ' + $Choice + ' ==' ) 'Cyan'
$fail = $false
if ($Choice -eq '1' -or $Choice -eq '2') {
  if ($Choice -eq '1') { Add-Ran '选项1：主线 -Mode Install（完整：EFI+启动项+开机任务）' }
  else { Add-Ran '选项2：主线 -Mode Install 打底 + ReBAR 版 EFI 设为第一启动项' }
  # 2026-10-14：强制路径会给安装器带上 -ForceLockedBatch（它只在『批次预检判为锁死』时才生效；unknown 本来就照装）
  $instArgs = @('-Mode','Install')
  if ($Force) { $instArgs += '-ForceLockedBatch'; Info '安装参数：-Mode Install -ForceLockedBatch（强制：锁死批次也照装）' }
  $r = Invoke-MainTool -File $script:MainInstaller -ToolArgs $instArgs -TimeoutSec $MainTimeoutSec -Tag '主线安装'
  if ($DryRun) { Info '[DryRun] 已跳过主线安装' }
  elseif ($r.Code -eq 0) { Ok '主线安装完成（退出码 0）' }
  elseif ($r.Code -eq 6) { Wr '主线判为锁死批次，用户选择不装（退出码 6）—— 本包到此结束'; Set-Rc 6 'locked-batch'; exit 6 }
  else { Bad ('主线安装退出码 ' + $r.Code + '（详见 ' + $r.Log + '）'); $fail = $true }
  if ($Choice -eq '2' -and -not $fail) {
    # 2026-10-14（用户拍板）：驱动已由主线安装铺好 → 这里做一次只读 BAR 探测（Above 4G 的强证据；失败只告警）
    if ($DryRun) { Info '[DryRun] 已跳过 BAR 只读探测' } else { Invoke-BarProbe }
    if (Deploy-ReBar -AsDefault) { Ok 'ReBAR 部署完成（已设为第一启动项）' } else { Bad 'ReBAR 部署失败'; $fail = $true }
  }
} elseif ($Choice -eq '3') {
  Add-Ran '选项3：主线 -Mode Repair（不动 ESP/固件启动项/不解算力）+ Windows 侧 Gen2 工具'
  $r = Invoke-MainTool -File $script:MainInstaller -ToolArgs @('-Mode','Repair') -TimeoutSec $MainTimeoutSec -Tag '主线Repair'
  if ($DryRun) { Info '[DryRun] 已跳过主线 Repair' } elseif ($r.Code -eq 0) { Ok '主线 Repair 完成（Windows 侧 Gen2 组件已就位，未动 ESP/固件）' } else { Wr ('主线 Repair 退出码 ' + $r.Code + '（详见 ' + $r.Log + '）') }
  if (Test-Path $script:MainGen2) {
    $r2 = Invoke-MainTool -File $script:MainGen2 -ToolArgs @() -TimeoutSec 600 -Tag 'Gen2修复'
    if ($DryRun) { Info '[DryRun] 已跳过 Gen2 修复工具' } elseif ($r2.Code -eq 0) { Ok 'Gen2 修复工具通过（桌面有 40HX-Gen2修复结果-*.txt）' } else { Wr ('Gen2 修复工具退出码 ' + $r2.Code + '：看桌面 40HX-Gen2修复结果-*.txt（可能提示需要 补写Gen2预埋）') }
  }
  if (Test-Path $script:MainPrime) {
    Info '若 Gen2 仍不到（EFI 预埋被固件中止的机器），需要补写预埋：'
    Info ('   ' + $script:MainPrime + ' -Yes -NoWait    （会先把原值落盘，再写真值）')
    if ($Yes -and -not $DryRun) {
      $r3 = Invoke-MainTool -File $script:MainPrime -ToolArgs @('-Yes','-NoWait') -TimeoutSec 600 -Tag '补写预埋'
      if ($r3.Code -eq 0) { Ok '补写 Gen2 预埋完成' } else { Wr ('补写预埋退出码 ' + $r3.Code + '：看桌面 40HX-Gen2补写预埋-*.txt') }
    } else { Info '（本次没自动补写：要自动补请在非交互时加 -Yes）' }
  }
}

Show-NextSteps $Choice
Ln ''
if ($fail) { Bad '有步骤失败：请把上面日志 + logs\ 目录里的文件发回'; Set-Rc 1 ('choice=' + $Choice); exit 1 }
Ln ('完成。记录：' + (($script:Ran) -join '；')) 'Green'
Set-Rc 0 ('choice=' + $Choice)
exit 0
