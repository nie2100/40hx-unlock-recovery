# 试跑REBAR.ps1 — 40HX ReBAR EFI（算力解锁+Gen2预埋+8GiB ReBAR）的一次性试跑部署
# 2026-10-12 r7 构建（Gen2 预埋"未收敛"判定改为只认 VSEC_DEVICE —— 原判定每开机必黄一次；
#   40HX-only 精简：去掉 6 个只被死函数引用的 blob，553K→358K，源码零改动、反汇编等价；
#   另修 /delay 假 OK）。QEMU/OVMF 冒烟通过；冻结 sha256 门禁不符拒绝部署。
# 2026-10-14：并入主线一键包；EFI 源从"脚本同目录"改为包内 payload\EFI\（与主线 EFI 同一存放位置）。
# 用法：试跑REBAR.cmd（默认=部署+BootNext 一次性试跑+注册开机验证任务）；undo = 撤掉
# 逻辑全部复用 Install-40HXUnlock.ps1 里已验证的 NVRAM/ESP 写法（逐字节回读、BootNext 一次性）。
# 2026-10-12 r8（本机开机实测归因，证据见 evidence/boot-*/核验结果.txt）：自动验证任务改名「REBAR Verify (one-shot)」。
#   原因：Gen2 的 C:\ProgramData\CMP40HXGen2\windows\RunPostBind.cmd 每次开机（Boot+Logon 各一轮）做"厂商遗留接管"：
#     schtasks /query /fo csv /nh | findstr /I "40HX ThrottleStop 40HXUnlock"  →  schtasks /change /tn <名> /disable
#   老名字「40HX ReBAR Verify」命中子串 40HX → 每次开机被静默禁用（postbind.log 有实锤），登录 2 分钟后根本没跑。
#   ⇒ 任务名**永远不要**含 40HX / ThrottleStop / 40HXUnlock；r8 起部署时会断言这一点并回读 Enabled。
param([string]$Action = 'run')

$ErrorActionPreference = 'Continue'
$script:DiagEfiName = '40HXUNLK-REBAR.EFI'
$script:DiagDesc    = '40HX REBAR TEST'
$script:DiagPath    = '\EFI\40HX\40HXUNLK-REBAR.EFI'
# r8：自动验证任务名 + PostBind 接管黑名单（改名字前先读文件头 r8 注释）
$script:VrfTask     = 'REBAR Verify (one-shot)'
$script:VrfTaskOld  = '40HX ReBAR Verify'              # 老名字，仅 undo 时清残留
$script:PostBindBan = '40HX|ThrottleStop|40HXUnlock'   # 与 RunPostBind.cmd 的 findstr 同源
$script:EspRoot     = $null
$script:EspPreMounted = $false
$script:FwGuid = '{8be4df61-93ca-11d2-aa0d-00e098032b8c}'
$script:FwTypeLoaded = $false

function Ln { param([string]$T) Write-Host $T }
function Ok { param([string]$T) Write-Host ('[OK] ' + $T) -ForegroundColor Green }
function Wr { param([string]$T) Write-Host ('[注意] ' + $T) -ForegroundColor Yellow }
function Bad { param([string]$T) Write-Host ('[失败] ' + $T) -ForegroundColor Red }

# 退出码落盘（r7d / DSH 第三轮中级项）：**每条退出路径**都要写真实结果，
#   覆盖 999=RUNNING(脚本已启动、结论未出) / 0=全好 / 1=源或门禁失败 / 2=权限或固件变量失败 / 4=ESP或NVRAM失败 / 7=已部署但自动验证任务未注册。
#   目录不可写时明确告警，不再静默。
$script:RcFile = Join-Path $PSScriptRoot '试跑REBAR-上次退出码.txt'
function Set-Rc { param([int]$Code, [string]$Note = '')
  try {
    ('exit=' + $Code + $(if ($Note) { '  state=' + $Note } else { '' }) + '  time=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) | Out-File -Encoding ascii -FilePath $script:RcFile -ErrorAction Stop
  } catch {
    Write-Host ('[注意] 退出码文件写不了（' + $script:RcFile + '）：' + $_.Exception.Message) -ForegroundColor Yellow
  }
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pr = New-Object Security.Principal.WindowsPrincipal($id)
  return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------- NVRAM 固件变量（代码原样取自 Install-40HXUnlock.ps1 已验证实现） ----------------
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

# ---------------- EFI_LOAD_OPTION 解析/构造（同一键包已验证实现） ----------------
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
  param([byte[]]$DeviceNode, [string]$Description, [string]$EfiPath, [uint32]$Attributes = 1)
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

# ESP 分区对象（挂载校验与设备路径节点构造共用同一份判定）
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

# ESP 分区 → HardDrive 设备路径节点（42B，GPT/GUID 签名）
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

# ---------------- ESP 挂载 ----------------
function Get-EspVolumeGuid {
  param([string]$Letter)
  $o = (mountvol $Letter /L 2>&1 | Out-String)
  $m = [regex]::Match($o, '(?i)Volume\{([0-9a-f-]{36})\}')
  if ($m.Success) { return $m.Groups[1].Value.ToLower() }
  return ''
}

function Mount-EspDiag {
  if ($script:EspRoot -and (Test-Path ($script:EspRoot + '\EFI'))) { return $script:EspRoot }
  $letters = @('Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K')
  $wantGuid = ''
  if ($script:EspPart) { $wantGuid = ([string]$script:EspPart.Guid).ToLower() }
  foreach ($dl in $letters) {
    if ((Test-Path ($dl + ':\EFI\Boot')) -or (Test-Path ($dl + ':\EFI\Microsoft'))) {
      # 已挂着的盘符可能不是系统盘的 ESP（U盘/别的磁盘）→ GPT 下卷 GUID 与分区 GUID 相同，不一致就跳过
      if ($wantGuid) {
        $gotGuid = Get-EspVolumeGuid ($dl + ':')
        if (-not $gotGuid) {
          Wr ('盘符 ' + $dl + ': 卷 GUID 读不到，无法核对是不是系统盘 ESP —— 按是接受（如写错卷请反馈）')
        } elseif ($gotGuid -ne $wantGuid) {
          Wr ('盘符 ' + $dl + ': 里的 EFI 目录不是系统盘 ESP（GUID 不符）→ 跳过')
          continue
        }
      }
      $script:EspRoot = $dl + ':'; $script:EspPreMounted = $true
      return $script:EspRoot
    }
  }
  foreach ($dl in $letters) {
    if (-not (Test-Path ($dl + ':\'))) {
      $out = (mountvol ($dl + ':') /S 2>&1 | Out-String).Trim()
      if ((Test-Path ($dl + ':\EFI\Boot')) -or (Test-Path ($dl + ':\EFI\Microsoft'))) {
        $script:EspRoot = $dl + ':'
        return $script:EspRoot
      }
    }
  }
  return $null
}

function Dismount-EspDiag {
  if ($script:EspRoot -and -not $script:EspPreMounted) { mountvol $script:EspRoot /D 2>&1 | Out-Null }
  $script:EspRoot = $null
}

# ================================ 主流程 ================================
Set-Rc 999 'RUNNING'   # r7d: 先置中间态，避免任何早退路径下读到上一轮的旧结果
if (-not (Test-Admin)) { Bad '必须管理员运行（用 试跑REBAR.cmd 双击会自动提权）'; Set-Rc 2; exit 2 }
if (-not (Initialize-FwAccess)) { Set-Rc 2; exit 2 }

if ($Action -eq 'undo') {
  Ln '== 撤掉 ReBAR 试跑 =='
  $script:EspPart = Get-EspPartition
  $entries = Get-AllBootEntries
  $diagEntries = @($entries | Where-Object { $_.Entry.Description -eq $script:DiagDesc })
  $bnRaw = Read-FwVar 'BootNext'
  if ($bnRaw -and $bnRaw.Length -eq 2) {
    $bnIdx = [int][BitConverter]::ToUInt16($bnRaw, 0)
    $bnIsDiag = @($diagEntries | ForEach-Object { $_.Index }) -contains $bnIdx
    $bnStale = @($entries | ForEach-Object { $_.Index }) -notcontains $bnIdx
    if ($bnIsDiag -or $bnStale) {
      Remove-FwVar 'BootNext' | Out-Null
      if ($bnIsDiag) { Ok 'BootNext 已清（指向 ReBAR 项）' } else { Wr ('BootNext 指向不存在的槽位 ' + ('{0:X4}' -f $bnIdx) + '（残留），已清') }
    }
  }
  foreach ($e in $diagEntries) {
    if (Remove-FwVar $e.Name) { Ok ('已删启动项 ' + $e.Name) } else { Bad ('删 ' + $e.Name + ' 失败') }
  }
  if ($diagEntries.Count -eq 0) { Ok '没有找到 ReBAR 启动项（本来就没有）' }
  $esp = Mount-EspDiag
  if ($esp) {
    $f = Join-Path ($esp + '\') ($script:DiagPath.TrimStart('\'))
    if (Test-Path $f) { Remove-Item $f -Force; Ok ('已删 ' + $f) } else { Ok 'ESP 上没有 ReBAR 文件（本来就没有）' }
  }
  # r8：新名字 + 老名字都清（老名字只可能是历史残留）
  schtasks /delete /tn $script:VrfTask /f 2>&1 | Out-Null
  schtasks /delete /tn $script:VrfTaskOld /f 2>&1 | Out-Null
  Dismount-EspDiag
  Ok '撤销完成（含一次性验证任务）'
  Set-Rc 0 'undo-done'; exit 0
}

# ---- run：部署 + BootNext 一次性试跑 ----
Ln '== 40HX ReBAR 一次性试跑部署 =='
# r7d: RUNNING 中间态已提到脚本顶部统一置位（原来在这里置，晚于权限/固件变量两个 exit 2）。
$src = Join-Path $PSScriptRoot ('payload\EFI\' + $script:DiagEfiName)
if (-not (Test-Path $src)) { Bad ('没找到 ' + $src + '（不要把 ps1 单独拷出来用，整包一起）'); Set-Rc 1; exit 1 }
$srcHash = (Get-FileHash $src -Algorithm SHA256).Hash
Ok ('源文件: ' + $src + '  sha256=' + $srcHash)
if ($srcHash -ne 'FDFE4EAF2186DA2FDA25E6599F243967EFF079C1699DA4A3EA1A08ECB5AC33FF'.ToUpper()) {
  Bad 'EFI 哈希与冻结值不符（包被改动过？）—— 拒绝部署'; Set-Rc 1; exit 1
}

$script:EspPart = Get-EspPartition
$esp = Mount-EspDiag
if (-not $esp) { Bad 'ESP 挂载失败（需要 UEFI+GPT 系统）'; Set-Rc 4; exit 4 }
Ok ('ESP 挂在 ' + $esp)

$dstDir = $esp + '\EFI\40HX'
if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
$dst = Join-Path $dstDir $script:DiagEfiName
Copy-Item -LiteralPath $src -Destination $dst -Force
$dstHash = (Get-FileHash $dst -Algorithm SHA256).Hash
if ($dstHash -ne $srcHash) { Bad 'ESP 写入回读校验不符！'; Dismount-EspDiag; Set-Rc 4; exit 4 }
Ok ('已写到 ' + $dst + '（回读 sha256 一致）')

$entries = Get-AllBootEntries
$node = Get-EspNodeFromLive $script:EspPart
if (-not $node) {
  $tpl = $entries | Where-Object { $_.Entry.DeviceNode -ne $null } | Select-Object -First 1
  if (-not $tpl) { Bad '取不到 ESP 分区也没有可参考的启动项，无法构造设备路径'; Dismount-EspDiag; Set-Rc 4; exit 4 }
  $node = $tpl.Entry.DeviceNode
  Wr ('设备路径节点沿用现有启动项 ' + $tpl.Name + ' 的字节')
}

$diag = $entries | Where-Object { $_.Entry.Description -eq $script:DiagDesc } | Select-Object -First 1
if ($diag) {
  $index = $diag.Index
  # 换盘/ESP 重建后旧节点会指向失效分区：复用前必须比对，不一致就原槽位重写
  if ($node -and ((-not $diag.Entry.DeviceNode) -or ([Convert]::ToBase64String($diag.Entry.DeviceNode) -ne [Convert]::ToBase64String($node)))) {
    Wr ('已有 ReBAR 启动项 ' + $diag.Name + ' 的设备路径与当前 ESP 不一致 → 原槽位重写')
    $bytesFix = New-BootEntryBytes -DeviceNode $node -Description $script:DiagDesc -EfiPath $script:DiagPath -Attributes 1
    if (-not (Write-FwVar $diag.Name $bytesFix)) { Dismount-EspDiag; Set-Rc 4; exit 4 }
    $rbFix = Read-FwVar $diag.Name
    if (-not $rbFix -or [Convert]::ToBase64String($rbFix) -ne [Convert]::ToBase64String($bytesFix)) {
      Bad ('重写 ' + $diag.Name + ' 后回读不一致'); Dismount-EspDiag; Set-Rc 4; exit 4
    }
    Ok ('已重写 ' + $diag.Name + '（逐字节回读一致）')
  } else {
    Ok ('已有 ReBAR 启动项 ' + $diag.Name + '（复用，设备路径一致）')
  }
} else {
  $index = Get-FreeBootSlot $entries
  if ($index -lt 0) { Bad '没有空闲 Boot 槽位'; Dismount-EspDiag; Set-Rc 4; exit 4 }
  $name = 'Boot{0:X4}' -f $index
  $bytes = New-BootEntryBytes -DeviceNode $node -Description $script:DiagDesc -EfiPath $script:DiagPath -Attributes 1
  if (-not (Write-FwVar $name $bytes)) { Dismount-EspDiag; Set-Rc 4; exit 4 }
  $readback = Read-FwVar $name
  if (-not $readback -or [Convert]::ToBase64String($readback) -ne [Convert]::ToBase64String($bytes)) {
    Bad ('启动项 ' + $name + ' 回读不一致')
    Remove-FwVar $name | Out-Null
    Wr ('已回收写坏的 ' + $name + '（不留在 NVRAM 里）')
    Dismount-EspDiag; Set-Rc 4; exit 4
  }
  Ok ('启动项已建好并逐字节回读一致: ' + $name + " = '" + $script:DiagDesc + "' -> " + $script:DiagPath)
}

$bn = New-Object byte[] 2
[Array]::Copy([BitConverter]::GetBytes([uint16]$index), 0, $bn, 0, 2)
if (Write-FwVar 'BootNext' $bn) {
  $rb = Read-FwVar 'BootNext'
  if ($rb -and $rb.Length -eq 2 -and [BitConverter]::ToUInt16($rb, 0) -eq $index) {
    Ok ('BootNext=' + ('{0:X4}' -f $index) + '（只在下次开机生效一次，之后自动失效；BootOrder 没动）')
  } else { Wr 'BootNext 回读不符 —— 进 BIOS 手动选一次 "40HX REBAR TEST" 启动项也行' }
}

# 注册一次性验证任务：登录后 2 分钟自动跑 验证REBAR.ps1（跑完自删）
# r8：任务名用 $script:VrfTask，**不能**含 40HX（会被 Gen2 PostBind 每次开机静默 /disable —— 见文件头 r8 注释）。
$vrfOk = $false   # r7b: 自动验证任务是否真的注册成功（决定退出码，见文件末尾）
$vrf = Join-Path $PSScriptRoot '验证REBAR.ps1'
$vrfTask = $script:VrfTask
if (Test-Path $vrf) {
  schtasks /delete /tn $vrfTask /f 2>&1 | Out-Null
  schtasks /delete /tn $script:VrfTaskOld /f 2>&1 | Out-Null   # r8：清老名字残留
  $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $vrf + '"'
  # 2026-10-12 r7 修复：/delay 必须是 mmmm:ss（2 分钟 = 0002:00）；原写 0000:02:00 被 schtasks 判非法，
  #   而输出被 Out-Null 吞掉 → 任务从来没建成，脚本却打印“已注册”（假 OK）。现在捕获输出+退出码+/query 回读。
  $scOut = (schtasks /create /tn $vrfTask /sc onlogon /delay 0002:00 /rl highest /f /tr $tr 2>&1 | Out-String).Trim()
  $scRc  = $LASTEXITCODE
  if ($scRc -eq 0) {
    # r7b（DSH 审查 Q3）：不只查任务在不在，还要核对"要运行的任务"里确实是 验证REBAR.ps1
    $qOut = (schtasks /query /tn $vrfTask /fo LIST /v 2>&1 | Out-String)
    if (($qOut -match [regex]::Escape($vrfTask)) -and ($qOut -match [regex]::Escape($vrf))) {   # r7b2: 精确匹配完整路径，不只文件名
      Ok ('已注册一次性验证任务「' + $vrfTask + '」（登录 2 分钟后自动出报告，跑完自删）—— 已回读确认（含要运行的任务）')
      $vrfOk = $true
    }
    else { Wr 'schtasks 报成功但回读核对不上（任务缺失或要运行的任务不对）—— 开机后请手动跑 验证REBAR.ps1 出报告'; Wr ('回读输出: ' + ($qOut -replace "`r?`n", ' | ')) }
    # ---- r8 断言 1：任务必须 Enabled（建出来就 Disabled / 事后被别的程序禁用，登录后都不会跑）----
    if ($vrfOk) {
      $en = 'no-node'
      try { $x = Export-ScheduledTask -TaskName $vrfTask -ErrorAction Stop; if ($x -match '<Enabled>(\w+)</Enabled>') { $en = $Matches[1] } } catch { $en = 'query-fail' }
      if ($en -eq 'false') {
        Wr '任务建出来是 Disabled —— 先 /change /enable 纠正再回读'
        schtasks /change /tn $vrfTask /enable 2>&1 | Out-Null
        $en = 'query-fail'
        try { $x2 = Export-ScheduledTask -TaskName $vrfTask -ErrorAction Stop; $en = $(if ($x2 -match '<Enabled>false</Enabled>') { 'false' } else { 'enabled' }) } catch { }
      }
      if ($en -eq 'false') { Bad ('任务「' + $vrfTask + '」处于 Disabled —— 登录后不会自动出报告（请手动跑 验证REBAR.ps1）'); $vrfOk = $false }
      elseif ($en -eq 'query-fail') { Wr '读不回任务的 Enabled 状态 —— 按未确认处理（开机后留意报告有没有自动出）' }
      else { Ok ('任务状态回读: Enabled=' + $(if ($en -eq 'no-node') { '启用（XML 无 Enabled 节点）' } else { $en })) }
    }
    # ---- r8 断言 2：任务名必须躲开 PostBind 接管黑名单 ----
    #   RunPostBind.cmd 每次开机跑：schtasks /query /fo csv /nh | findstr /I "40HX ThrottleStop 40HXUnlock" → /change /disable
    #   这里用同一条 pipeline 复现它的判定：命中 = 开机后必被静默禁用 = 部署无效。
    if ($vrfOk) {
      $caught = $false
      $qcsv = (schtasks /query /fo csv /nh 2>&1 | Out-String)
      # r8b：先证明任务真的出现在全量列表里（脚本自己刚跑过 验证REBAR.ps1 把一次性任务删了的话，这里必须报失败而不是"没进黑名单=通过"）
      $present = @(($qcsv -split "`r?`n") | Where-Object { $_ -match [regex]::Escape($vrfTask) })
      if ($present.Count -eq 0) { Bad ('任务「' + $vrfTask + '」没出现在 schtasks 全量列表里 —— 按注册失败处理（开机后手动跑 验证REBAR.ps1）'); $vrfOk = $false }
      foreach ($line in ($qcsv -split "`r?`n")) {
        if (($line -match [regex]::Escape($vrfTask)) -and ($line -match $script:PostBindBan) -and ($line -notmatch 'CMP40HX Gen2 PostBind')) { $caught = $true }
      }
      if ($caught) { Bad ('任务名「' + $vrfTask + '」会被 Gen2 PostBind 的开机接管循环禁用（命中 RunPostBind.cmd 的 findstr）—— 换成不含 40HX/ThrottleStop/40HXUnlock 的名字'); $vrfOk = $false }
      else { Ok '任务名不在 PostBind 接管黑名单里 —— 开机后不会被静默禁用' }
    }
  } else {
    Bad ('注册一次性验证任务失败 (exit=' + $scRc + ')：' + ($scOut -replace "`r?`n", ' | '))
    Wr '开机后请手动跑 验证REBAR.ps1 出报告（右键管理员运行）'
  }
} else {
  Wr '没找到 验证REBAR.ps1 —— 开机后请手动跑它出报告'
}

Dismount-EspDiag
Ln ''
Ln '==== 下一步 ===='
Ln '1. 重启（或完全关机再开）—— 下次开机由 BootNext 跑一次 ReBAR 版 EFI（仅一次，之后自动回到原启动项）'
Ln '2. 本版含算力解锁 + Gen2 预埋 + 8GiB ReBAR；任一步失败 EFI 会整体回滚并记日志'
Ln '3. 登录后约 2 分钟自动生成本目录的 验证报告-latest.txt（BAR1/算力/Gen2/Code43 全量核对）'
Ln '4. 万一开机卡住/黑屏：强制关机再开即可（BootNext 一次性自动失效，不影响正常启动）'
Ln '撤销试跑：试跑REBAR.cmd undo'
# r7b（DSH 审查 Q3）：原实现无论注册成败都 exit 0 → 上层 cmd 打印"退出码: 0（0=成功）"，
#   机器可读层仍然是假 OK。现在注册没成 → 退出码 7（EFI/启动项已部署，试跑照常）。
$rc = 0
if (-not $vrfOk) { $rc = 7 }
# r7b2/r7d：UAC 提权路径下父 cmd 只能 exit /b 0（拿不到提权子进程的码）→ 退出码落盘；
#   r7d 起每条退出路径都走 Set-Rc（不再只有 0/7 两条被覆盖）。
Set-Rc $rc ('vrfOk=' + $vrfOk)
if (-not $vrfOk) {
  Ln ''
  Bad '注意：EFI 与启动项已部署，但"登录后自动验证任务"没注册成功 —— 试跑照旧，开机后要手动跑 验证REBAR.ps1 出报告'
  Ln '（退出码 ' + $rc + ' 已写入 试跑REBAR-上次退出码.txt）'
  exit $rc
}
Set-Rc 0 ('vrfOk=' + $vrfOk)
exit 0
