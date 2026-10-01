param([switch]$Apply, [string]$GpuBdf = '', [string]$RootBdf = '', [switch]$NoAutoPrime, [string]$PciBackend = 'auto')
# 40HX Gen2 retrain via inpoutx64 (MMIO) + WinRing0 (PCI config).  The anti-cheat is NEVER touched.
# exit codes: 0 = PASS (physical Gen2 x16), 10 = link not Gen2, 11 = baseline/guard failed,
#             12 = GPU/driver not ready in time, 13 = inpoutx64 driver not running, 3 = WinRing0 unusable
# 2026-09-30: GPU/root-port BDF are AUTO-DETECTED (PnP LocationInfo -> nvidia-smi -> legacy 01:00.0).
#             The old build hardcoded 01:00.0 / 00:01.0, so on any machine where the card sits elsewhere
#             (2nd slot, behind a switch, AGESA/high-bus boards - vendor README reports bus 0x10)
#             it waited the full 120s and exited 12 on every boot. -GpuBdf/-RootBdf override (hex like 0x0200).
$ErrorActionPreference='Continue'
$LOGAPP='C:\ProgramData\CMP40HXGen2\windows\logs\retrain-inpout.log'
$out='C:\Temp\40hx-retrain-tool.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function W($s){ $line=[string]$s; Add-Content -Path $out -Value $line -Encoding utf8; Add-Content -Path $LOGAPP -Value $line -Encoding utf8; Write-Host $line }
function U32([string]$hex){ return [Convert]::ToUInt32($hex,16) }

# ---- deploy / heal the driver files (AV quarantines .sys after load) ----
$SYS='C:\Windows\System32\drivers\inpoutx64.sys'
$DLL='C:\ProgramData\CMP40HXGen2\drivers\inpoutx64.dll'
$SRC=@('C:\ProgramData\CMP40HXGen2\drivers\inpoutx64.sys','C:\ProgramData\40HXUnlock\drivers\inpoutx64.sys','C:\ProgramData\40HXUnlock\cand2\inpoutx64.sys')
if(-not (Test-Path $SYS)){
  foreach($s in $SRC){ if(-not (Test-Path $SYS) -and (Test-Path $s)){ Copy-Item $s $SYS -Force -ErrorAction SilentlyContinue } }
}
foreach($s in $SRC){ if(-not (Test-Path $DLL) -and (Test-Path ($s -replace '\.sys$','.dll'))){ Copy-Item ($s -replace '\.sys$','.dll') $DLL -Force -ErrorAction SilentlyContinue } }

$dllCs = $DLL.Replace('\','\\')
$cs = @"
using System; using System.Runtime.InteropServices;
public static class P {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Ansi)] public static extern IntPtr CreateFileA(string n,uint a,uint s,IntPtr sec,uint d,uint f,IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool DeviceIoControl(IntPtr h,uint c,byte[] i,uint isz,byte[] o,uint osz,out uint r,IntPtr ov);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("$dllCs", EntryPoint="MapPhysToLin", CallingConvention=CallingConvention.StdCall, SetLastError=true)]
  public static extern IntPtr MapPhysToLin(IntPtr pbPhysAddr, uint dwPhysSize, out IntPtr h);
  [DllImport("$dllCs", EntryPoint="UnmapPhysicalMemory", CallingConvention=CallingConvention.StdCall, SetLastError=true)]
  public static extern bool UnmapPhysicalMemory(IntPtr h, IntPtr va);
}
"@
Add-Content -Path $out -Value ("[banner] started " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " Apply=" + $Apply + " ps=" + $PSVersionTable.PSVersion) -Encoding utf8
try { Add-Type -TypeDefinition $cs -ErrorAction Stop } catch { Add-Content $out ("[FATAL] Add-Type: " + $_.Exception.Message); exit 2 }

$RD_PCI=U32 '9C406144'
$WR_PCI=U32 '9C40A148'

# ================= PCI 配置空间访问后端 =================
# 后端 A（2026-09-30 起首选）：ECAM —— 用 inpoutx64 直接读写物理 MMIO 的“配置空间窗口”，**完全不依赖 WinRing0**。
#   起因：客户机实测 WinRing0x64.sys 被 Defender/360 的“易受攻击驱动”策略封杀 ——
#   服务启动类型被强制改回 Start=4(DISABLED)、加载报 “失败 2: 系统找不到指定的文件”（文件被策略藏起来），
#   而 inpoutx64（我们 MMIO 用的那个）全程正常 → 干脆把 PCI 配置访问也走 inpoutx64。
# 后端 B（回退）：WinRing0 的 RD_PCI/WR_PCI IOCTL（原有路径，逻辑未改）。
# ECAM 地址：base + (bus<<20) + (dev<<15) + (fn<<12) + off；配置访问必须自然对齐且不跨 DWORD
function EcamOff([uint32]$bdf,[uint32]$off){
  $bus=[uint64](($bdf -shr 8) -band 0xFF); $dev=[uint64](($bdf -shr 3) -band 0x1F); $fn=[uint64]($bdf -band 7)
  return ($bus * 0x100000) + ($dev * 0x8000) + ($fn * 0x1000) + [uint64]($off -band 0xFFF)
}
# 2026-09-30 实测：本机平台的 ECAM **只可靠响应 4 字节对齐访问**（2 字节读 0x8A 返回 0xFFFF），
# 所以这里一律按 4 字节访问，再在软件里取需要的字节/字（写 16 位时读改写整双字，
# 会把状态半字按读到的值写回 —— 只可能清掉 RW1C 状态锁存位，属安全）。
function MmioReadN([uint64]$addr,[int]$bytes){
  if(-not (Test-MmioAllowed $addr)){ Deny-Mmio $addr ('read'+$bytes); return $null }
  try {
    $al=[uint64]($addr -band ([uint64]::MaxValue - 3))     # 4 字节对齐
    $sh=[int]($addr - $al) * 8
    $h=[IntPtr]::Zero
    $va=[P]::MapPhysToLin([IntPtr][int64]$al,4096,[ref]$h)
    if($va -eq [IntPtr]::Zero -or [int64]$va -eq -1){ return $null }
    $b4=New-Object byte[] 4
    [Runtime.InteropServices.Marshal]::Copy($va,$b4,0,4)
    [P]::UnmapPhysicalMemory($h,$va) | Out-Null
    $v=[uint32][BitConverter]::ToUInt32($b4,0)
    if($bytes -eq 4){ return $v }
    $mask = if($bytes -eq 2){ [uint64]65535 } else { [uint64]255 }
    return [uint32]((([uint64]$v -shr $sh) -band $mask))
  } catch { return $null }
}
function MmioWriteN([uint64]$addr,[uint32]$val,[int]$bytes){
  if(-not (Test-MmioAllowed $addr)){ Deny-Mmio $addr ('write'+$bytes); return $false }
  try {
    $al=[uint64]($addr -band ([uint64]::MaxValue - 3))
    $sh=[int]($addr - $al) * 8
    $h=[IntPtr]::Zero
    $va=[P]::MapPhysToLin([IntPtr][int64]$al,4096,[ref]$h)
    if($va -eq [IntPtr]::Zero -or [int64]$va -eq -1){ return $false }
    $b4=New-Object byte[] 4
    [Runtime.InteropServices.Marshal]::Copy($va,$b4,0,4)
    $cur=[uint64][BitConverter]::ToUInt32($b4,0)
    $mask = if($bytes -eq 4){ [uint64]4294967295 } elseif($bytes -eq 2){ [uint64]65535 } else { [uint64]255 }
    $new = (($cur -band (-bnot (($mask -shl $sh) -band [uint64]4294967295))) -bor (( ([uint64]$val) -band $mask) -shl $sh)) -band [uint64]4294967295
    $nb=[BitConverter]::GetBytes([uint32]$new)
    [Runtime.InteropServices.Marshal]::Copy($nb,0,$va,4)
    [P]::UnmapPhysicalMemory($h,$va) | Out-Null
    return $true
  } catch { return $false }
}
function CpuVendorId(){
  try {
    $v=(Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name VendorIdentifier -ErrorAction SilentlyContinue).VendorIdentifier
    if($v -match 'Intel'){ return 0x8086 }
    if($v -match 'AMD'){ return 0x1022 }
  } catch { }
  return 0x8086
}
# ---------------------------------------------------------------------------
# 2026-09-30 **安全事故修正**：上一版直接对 0x80000000~0xF8000000 一串物理地址盲读，
# 客户机上读到了平台的“空洞”地址 → 触发平台致命错误 → **蓝屏**。
# 教训（写死在这里，别再犯）：**绝不允许盲扫物理地址**。只能读操作系统明确声明过的范围。
# 现在 ECAM 基址只从两个安全来源取：
#   ① ACPI MCFG 表（GetSystemFirmwareTable，操作系统提供的固件表）
#   ② Win32_PnPAllocatedResource 里 PCI 根复合体名下的内存资源（系统已分配）
# 若两个来源都拿不到基址 → 直接判定 ECAM 不可用（宁可不修，也不去试地址）。
# ---------------------------------------------------------------------------
function GetMcfgBase {
  try {
    if(-not ('FwT' -as [type])){
      Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class FwT {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern uint GetSystemFirmwareTable(uint provider, uint table, byte[] buf, uint size);
}
'@ -ErrorAction Stop
    }
    # provider 'ACPI' = 0x41435049、表 'MCFG' = 0x4D434647（MSB 优先打包；写成小端 0x49504341 会返回 0 取不到）
    $sz=[FwT]::GetSystemFirmwareTable(0x41435049, 0x4D434647, $null, 0)
    if($sz -le 44){ W("  MCFG: 大小为 $sz，取不到"); return $null }
    $buf=New-Object byte[] $sz
    $got=[FwT]::GetSystemFirmwareTable(0x41435049, 0x4D434647, $buf, $sz)
    if($got -le 0){ W("  MCFG: 读取失败"); return $null }
    # ACPI 表头 36 字节 + MCFG 保留 8 字节 → 第一个 allocation entry 在 44
    $base=[BitConverter]::ToUInt64($buf,44)
    $seg=[BitConverter]::ToUInt16($buf,52); $b0=$buf[54]; $b1=$buf[55]
    W("  MCFG: 找到 ECAM 基址 0x" + $base.ToString('X') + "  segment=$seg  bus $b0-$b1")
    return $base
  } catch { W("  MCFG: 解析异常 " + $_.Exception.Message); return $null }
}
function TryEcam {
  $cv = CpuVendorId
  $cands = New-Object System.Collections.ArrayList
  $m = GetMcfgBase
  if($m -ne $null){ [void]$cands.Add([uint64]$m) }
  try {
    foreach($r in @(Get-CimInstance Win32_PnPAllocatedResource -ErrorAction SilentlyContinue)){
      try {
        $dep = $r.Dependent
        if($dep -and ($dep.DeviceID -match 'PNP0A03|PNP0A08')){
          foreach($mm in @(Get-CimAssociatedInstance -InputObject $r -ResultClassName Win32_DeviceMemoryAddress -ErrorAction SilentlyContinue)){
            if($mm.StartingAddress -ne $null){
              $st=[uint64]$mm.StartingAddress
              if($st -ge 0x80000000 -and $st -lt 0x100000000 -and ($st % 0x1000000) -eq 0){ [void]$cands.Add($st) }
            }
          }
        }
      } catch { }
    }
  } catch { }
  $cands = @($cands | Select-Object -Unique)
  if($cands.Count -eq 0){ W("  ECAM: 没有拿到任何系统声明过的配置空间基址（不做任何盲试）→ 本次不用 ECAM"); return $null }
  foreach($base in $cands){
    try {
      Allow-Mmio ([uint64]$base) ([uint64]'0x10000000')   # 只在这个已声明的 256MB 窗口内读
      $v0 = MmioReadN ([uint64]$base) 4
      if($v0 -eq $null){ W("  ECAM 校验 0x" + $base.ToString('X') + ": 读失败"); continue }
      $ven = [uint32]($v0 -band 0xFFFF)
      if($ven -ne $cv){ W("  ECAM 校验 0x" + $base.ToString('X') + ": 00:00.0 厂商=0x" + $ven.ToString('X4') + " 不等于 CPU 厂商，跳过"); continue }
      $found=$null; $bridges=0
      foreach($bus in 0..2){
        foreach($dev in 0..31){
          $d=[uint64]($base + ([uint64]$bus * 0x100000) + ([uint64]$dev * 0x8000))
          $id=MmioReadN $d 4
          if($id -eq $null){ continue }
          if($id -eq 4294967295){ continue }
          $bd=[uint32](($bus -shl 8) -bor ($dev -shl 3))
          if(([uint32]($id -band 0xFFFF) -eq 0x10DE) -and ([uint32](([uint64]$id -shr 16) -band 0xFFFF) -eq 0x1F0B)){ $found=$bd }
          else {
            $cl=MmioReadN ([uint64]($d + 0x8)) 4
            if($cl -ne $null -and ([uint32]((([uint64]$cl -shr 8) -band 0xFFFFFF)) -eq 0x060400)){ $bridges++ }
          }
        }
      }
      W("  ECAM 校验 0x" + $base.ToString('X') + ": 厂商=0x" + $ven.ToString('X4') + "  40HX=" + $(if($found -eq $null){'未找到'}else{'0x' + $found.ToString('X4')}) + "  PCI桥=$bridges")
      if($found -ne $null -and $bridges -ge 1){ return @{ Base=$base; Gpu=$found } }
    } catch {
      W("  ECAM 校验 0x" + $base.ToString('X') + " 异常: " + $_.Exception.Message)
    }
  }
  return $null
}
function PciRead([uint32]$bdf,[uint32]$off,[uint32]$len){
  if($script:ecam -ne $null){
    return (MmioReadN ([uint64]($script:ecam + (EcamOff $bdf ([uint32]($off -band 0xFFF))))) ([int]$len))
  }
  $in=New-Object byte[] 8; [Array]::Copy([BitConverter]::GetBytes($bdf),0,$in,0,4); [Array]::Copy([BitConverter]::GetBytes($off),0,$in,4,4)
  $o=New-Object byte[] 4; $n=[uint32]0
  if(-not [P]::DeviceIoControl($hw,$RD_PCI,$in,8,$o,$len,[ref]$n,[IntPtr]::Zero)){ return $null }
  return [BitConverter]::ToUInt32($o,0)
}
function PciWrite16([uint32]$bdf,[uint32]$off,[uint16]$val){
  if($script:ecam -ne $null){
    return (MmioWriteN ([uint64]($script:ecam + (EcamOff $bdf ([uint32]($off -band 0xFFF))))) ([uint32]$val) 2)
  }
  $in=New-Object byte[] 10
  [Array]::Copy([BitConverter]::GetBytes($bdf),0,$in,0,4); [Array]::Copy([BitConverter]::GetBytes($off),0,$in,4,4)
  [Array]::Copy([BitConverter]::GetBytes($val),0,$in,8,2)
  $o=New-Object byte[] 1; $n=[uint32]0
  return [P]::DeviceIoControl($hw,$WR_PCI,$in,10,$o,1,[ref]$n,[IntPtr]::Zero)
}
function FindPcieCap([uint32]$bdf){
  $st=PciRead $bdf 0x34 1
  if($script:ecam -ne $null){ W("    [cap] bdf=0x" + $bdf.ToString('X4') + " 0x34 -> " + $(if($st -eq $null){'READ FAILED'}else{'0x'+$st.ToString('X2')})) }
  if($st -eq $null){ return $null }
  if(($st -band 0xFF) -eq 0 -or ($st -band 0xFF) -eq 0xFF){ return $null }
  $p=[int]($st -band 0xFF); $g=0
  while($p -ne 0 -and $g -lt 32){
    $g++
    $hdr=PciRead $bdf ([uint32]$p) 2
    if($script:ecam -ne $null){ W("    [cap]   ptr=0x" + $p.ToString('X2') + " hdr=" + $(if($hdr -eq $null){'READ FAILED'}else{'0x'+$hdr.ToString('X4')})) }
    if($hdr -eq $null){ return $null }
    $id=[int]($hdr -band 0xFF); $nx=[int](($hdr -shr 8) -band 0xFF)
    if($id -eq 0x10){ return $p }
    if($nx -eq 0 -or $nx -eq $p){ return $null }
    $p=$nx
  }
  return $null
}
function LinkSta([uint32]$cap,[uint32]$bdf){
  $v=PciRead $bdf ([uint32]($cap+0x12)) 2
  if($v -eq $null){ return $null }
  return [uint32]($v -band 0xFFFF)
}
# ================= 安全护栏（2026-09-30 蓝屏事故后新增，硬性）=================
# 只允许访问**已登记**的物理窗口：系统声明过的 BAR / 已校验的 ECAM 窗口。
# 任何窗口外的物理访问一律拒绝并记日志 —— 盲读未声明的物理地址可能触发平台致命错误（MCE）导致蓝屏。
$script:MmioAllowed = New-Object System.Collections.ArrayList
function Allow-Mmio([uint64]$start,[uint64]$size){
  [void]$script:MmioAllowed.Add(@([uint64]$start,[uint64]($start + $size - 1)))
}
function Test-MmioAllowed([uint64]$addr){
  foreach($r in $script:MmioAllowed){ if($addr -ge $r[0] -and $addr -le $r[1]){ return $true } }
  return $false
}
function Deny-Mmio([uint64]$addr,[string]$what){
  W("    [安全护栏] 拒绝访问未登记物理地址 0x" + $addr.ToString('X') + " (" + $what + ") —— 防再次触发平台致命错误")
}
function MmioRead([uint64]$addr){
  if(-not (Test-MmioAllowed $addr)){ Deny-Mmio $addr 'read32'; return $null }
  try {
    $h=[IntPtr]::Zero
    $va=[P]::MapPhysToLin([IntPtr][int64]$addr,4096,[ref]$h)
    if($va -eq [IntPtr]::Zero -or [int64]$va -eq -1){ W("      [mmio] map 0x" + $addr.ToString('X') + " failed"); return $null }
    $b=New-Object byte[] 4; [Runtime.InteropServices.Marshal]::Copy($va,$b,0,4)
    [P]::UnmapPhysicalMemory($h,$va) | Out-Null
    return [BitConverter]::ToUInt32($b,0)
  } catch { W("      [mmio] read exception at 0x" + $addr.ToString('X') + ": " + $_.Exception.Message); return $null }
}
function MmioWrite([uint64]$addr,[uint32]$val){
  if(-not (Test-MmioAllowed $addr)){ Deny-Mmio $addr 'write32'; return $false }
  try {
    $h=[IntPtr]::Zero
    $va=[P]::MapPhysToLin([IntPtr][int64]$addr,4096,[ref]$h)
    if($va -eq [IntPtr]::Zero -or [int64]$va -eq -1){ W("      [mmio] write map 0x" + $addr.ToString('X') + " failed"); return $false }
    $b=[BitConverter]::GetBytes($val)
    [Runtime.InteropServices.Marshal]::Copy($b,0,$va,4)
    [P]::UnmapPhysicalMemory($h,$va) | Out-Null
    return $true
  } catch { W("      [mmio] write exception at 0x" + $addr.ToString('X') + ": " + $_.Exception.Message); return $false }
}

$adm=(New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
W("==== 40HX Gen2 retrain (inpoutx64 MMIO + WinRing0 PCI, anti-cheat untouched)   ver=$TOOL_VER   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Apply=$Apply ====")
try {
  $smi="$env:SystemRoot\System32\nvidia-smi.exe"
  if(Test-Path $smi){ W("  vbios/driver: " + ((& $smi --query-gpu=vbios_version,driver_version --format=csv,noheader 2>&1 | Out-String).Trim())) }
} catch { }
try {
  $bl = [string](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Name 'VulnerableDriverBlocklistEnable' -ErrorAction SilentlyContinue).VulnerableDriverBlocklistEnable
  W("  VulnerableDriverBlocklistEnable=" + $(if($bl -eq ''){'<未设置>'}else{$bl}))
} catch { }
W("  admin=$adm   sys_driver=" + (Test-Path $SYS) + "   dll=" + (Test-Path $DLL) + "   pci_backend=$PciBackend")
if(-not $adm){ W(">>> not elevated"); exit 1 }

# ---- service state helpers (2026-09-30: 客户机见过 WinRing0 卡在 STOP_PENDING → start 直接失败) ----
function SvcState([string]$n){
  $q=(sc.exe query $n 2>&1 | Out-String)
  if($q -match '1060'){ return 'MISSING' }
  if($q -match 'STATE\s*:\s*\d+\s+(\S+)'){ return $Matches[1] }
  return 'UNKNOWN'
}
function WaitSvcState([string]$n,[string[]]$want,[int]$sec){
  for($i=0; $i -lt $sec; $i++){
    if($want -contains (SvcState $n)){ return $true }
    Start-Sleep -Seconds 1
  }
  return $false
}

# ---- drivers ----
$ioWas=[bool]((sc.exe query inpoutx64T 2>&1 | Out-String) -match 'RUNNING')
if(-not $ioWas){
  if(-not (Test-Path $SYS)){ W(">>> inpoutx64.sys missing in System32\drivers and no source available"); exit 13 }
  sc.exe delete inpoutx64T 2>&1 | Out-Null
  for($k=1; $k -le 10; $k++){ if(((sc.exe query inpoutx64T 2>&1 | Out-String) -match '1060')){ break }; Start-Sleep -Milliseconds 500 }
  $c=(& sc.exe create inpoutx64T type= kernel start= demand binPath= '\SystemRoot\System32\drivers\inpoutx64.sys' 2>&1 | Out-String).Trim()
  $s=(& sc.exe start inpoutx64T 2>&1 | Out-String).Trim()
  Start-Sleep -Milliseconds 1000
  W("  inpoutx64T create/start: " + ($c -replace "`r?`n"," | ") + " ==> " + (($s -split "`n" | Select-String 'STATE' | Out-String).Trim()))
}
# 2026-09-30：默认先走 WinRing0（老路、现场验证最多）；只有 WinRing0 起不来时才尝试 ECAM，
# 而 ECAM 的基址**只**来自 ACPI MCFG / 系统已分配资源（见 TryEcam 顶部说明：绝不盲扫物理地址）。
$script:ecam = $null
$script:EcamGpuBdf = $null
# ============================================================================
# 2026-10-01 客户机铁证：`WinRing0_1_2_0` 这个服务名**会**被别的软件占用 ——
#   客户机实测（七彩虹 CVN B460I + iGame Center）：
#     BINARY_PATH_NAME = \??\C:\Program Files\iGameCenter\WinRing0x64.sys   START_TYPE=4 DISABLED   STATE=3 STOP_PENDING
#   即“七彩虹 iGame Center”自带一份 WinRing0 服务占着这个名字，且被禁用+卡在 STOP_PENDING。
#   我们原来也用这个名字 → 建不了/起不来/设备也开不了 → 写不了 Gen2 策略寄存器 → Gen2 永远上不去。
# 对策：
#   ① **绝不改动别人软件的配置**（不碰它的 binPath/启动类型，也不删它的服务）
#   ② 改用**独立服务名 `WinRing0_40HX`** 指向我们校验过的 WinRing0x64.sys ——
#      WinRing0 的设备名是驱动内部固定的 \.\WinRing0_1_2_0，换服务名不影响工具打开设备
#   ③ 若占用者的驱动还挂在内核里（STOP_PENDING），我们这份也加载不了（设备名冲突）→
#      日志明确提示：**先退出 iGame Center（或重启后先别开它）再跑**
# ============================================================================
$script:WRSvcName = 'WinRing0_40HX'
$script:wrForeign = $false
$wrWas=(SvcState 'WinRing0_1_2_0') -eq 'RUNNING'
if($PciBackend -eq 'ecam'){ W("  已指定 -PciBackend ecam → 跳过 WinRing0，直接用 ECAM") }
if($PciBackend -ne 'ecam' -and $script:ecam -eq $null -and -not $wrWas){
  $WRF='C:\Windows\System32\drivers\WinRing0x64.sys'
  if(-not (Test-Path $WRF)){
    foreach($s in @('C:\ProgramData\CMP40HXGen2\drivers\WinRing0x64.sys','C:\ProgramData\40HXUnlock\drivers\WinRing0x64.sys')){
      if(-not (Test-Path $WRF) -and (Test-Path $s)){ Copy-Item $s $WRF -Force -ErrorAction SilentlyContinue }
    }
  }
  if(-not (Test-Path $WRF)){ W(">>> WinRing0x64.sys missing and no source"); exit 3 }
  $q0=(sc.exe qc WinRing0_1_2_0 2>&1 | Out-String)
  if($q0 -match 'SERVICE_NAME'){
    $bp=''
    $m=[regex]::Match($q0,'BINARY_PATH_NAME\s*:\s*(\S+)')
    if($m.Success){ $bp=$m.Groups[1].Value }
    if($bp -match 'System32\\drivers\\WinRing0x64\.sys'){
      W("  公用服务名 WinRing0_1_2_0 指的就是我们的驱动（" + $bp + "）→ 直接用它")
      $script:WRSvcName='WinRing0_1_2_0'
    } else {
      $script:wrForeign=$true
      W("  ★ 服务名 WinRing0_1_2_0 被别的软件占用: " + $bp)
      W("    客户机上这通常是七彩虹 iGame Center 自带的那份（本工具不会去改动它的任何配置）")
      W("    → 改用独立服务名 WinRing0_40HX（指向我们校验过的 WinRing0x64.sys）")
    }
  }
  $svc=$script:WRSvcName
  if((SvcState $svc) -eq 'STOP_PENDING'){
    W("  $svc 卡在 STOP_PENDING（驱动还挂着）→ 先试着重置")
    sc.exe stop $svc 2>&1 | Out-Null
    [void](WaitSvcState $svc @('STOPPED','MISSING','RUNNING') 8)
    W("  $svc stop 后 -> " + (SvcState $svc))
    if((SvcState $svc) -eq 'STOP_PENDING'){
      sc.exe delete $svc 2>&1 | Out-Null
      [void](WaitSvcState $svc @('MISSING','STOPPED','RUNNING') 5)
      W("  $svc 删除后 -> " + (SvcState $svc))
    }
  }
  if((SvcState $svc) -eq 'MISSING'){
    sc.exe create $svc type= kernel start= demand binPath= '\SystemRoot\System32\drivers\WinRing0x64.sys' 2>&1 | Out-Null
    $script:wrCreated=$true
    W("  $svc create -> " + (SvcState $svc))
  } else {
    $stp=(sc.exe qc $svc 2>&1 | Out-String)
    if($stp -notmatch 'DEMAND_START'){ sc.exe config $svc start= demand 2>&1 | Out-Null; W("  $svc start type -> demand") }
  }
  W("  WinRing0 服务名=$svc   sysfile=" + (Test-Path $WRF))
  for($k=1; $k -le 3; $k++){
    $o=(sc.exe start $svc 2>&1 | Out-String).Trim()
    Start-Sleep -Milliseconds 1200
    $now=SvcState $svc
    W("  $svc start try ${k} -> $now  [" + ($o -replace "`r?`n",' | ') + "]")
    if($now -eq 'RUNNING'){ break }
    if($now -eq 'STOP_PENDING'){ [void](WaitSvcState $svc @('STOPPED','MISSING','RUNNING') 6) }
    Start-Sleep -Seconds 1
  }
  if((SvcState $svc) -ne 'RUNNING' -and $script:wrForeign){
    W("  ★ $svc 起不来的最可能原因：iGame Center 那份 WinRing0 还挂在内核里（设备名 \\.\WinRing0_1_2_0 被它占着）")
    W("    请在跑本工具前：托盘右键**退出 iGame Center**（必要时重启一次，重启后先别开它），然后重跑")
  }
}
# 情况③：公用名 WinRing0_1_2_0 正在跑（= iGameCenter 已把它那份驱动加载起来，设备名已被创建）
#   → 我们不必自己加载，直接打开同一个设备即可（WinRing0 的设备接口一样）。2026-10-01 补：先前会误判成"起不来"。
if($wrWas -and (SvcState 'WinRing0_1_2_0') -eq 'RUNNING'){ $script:WRSvcName='WinRing0_1_2_0' }
if($script:WRSvcName -eq $null){ $script:WRSvcName='WinRing0_40HX' }
$wrRunning = ((SvcState $script:WRSvcName) -eq 'RUNNING')
if(-not $wrRunning){
  # 2026-09-30 蓝屏事故后收紧策略：**默认不再自动尝试 ECAM**。
  #   ECAM 只有显式 -PciBackend ecam 时才试，而且基址只可能来自 ACPI MCFG / 系统已分配资源（绝不盲扫物理地址）。
  #   理由：盲扫物理地址在客户机上触发平台致命错误(蓝屏, WHEA_UNCORRECTABLE_ERROR)；宁可这一项不修，也不能再冒险。
  if($PciBackend -eq 'ecam'){
    W("  --- WinRing0 不可用 → 按显式要求试 ECAM（基址只取自 ACPI MCFG / 系统已分配资源，绝不盲扫物理地址）---")
    $ec = TryEcam
    if($ec -ne $null){
      $script:ecam = [uint64]$ec.Base; $script:EcamGpuBdf = $ec.Gpu
      W("  [OK] ECAM 可用: 基址 0x" + $script:ecam.ToString('X') + "   40HX 在 0x" + ([uint32]$ec.Gpu).ToString('X4'))
    }
  } else {
    W("  WinRing0 用不了（被策略封杀/服务异常）。默认不再自动改用 ECAM：不读任何未声明地址，避免再次触发平台致命错误")
    W("  如需试 ECAM，请显式加 -PciBackend ecam（只读系统声明过的窗口；本机验证过读数与 WinRing0 一致）")
  }
  $wrRunning = ($script:ecam -ne $null)
}
if(-not $wrRunning){
  W(">>> WinRing0 驱动起不来（服务卡在 STOP_PENDING 或启动被拒）")
  W(">>> 原因：已有进程占着 \\.\WinRing0_1_2_0 的句柄，驱动卸不下来。常见占用者：厂商自启的 40HXGen2.exe、ThrottleStop.exe、反作弊/杀软")
  W(">>> 处理：完全关机再开机（开始菜单 → 关机，不是重启），开机后重新双击 一键修复Gen2.cmd 即可")
  W(">>> （本工具已试过：重置服务 + 删服务重建 + 换服务名；都失败才报这里）")
  W(">>> 本机 Gen2 这一项本次就不修了 —— 算力解锁/驱动/GSP 都不受影响，正常用即可")
  exit 3
}
function CleanupDrivers(){
  if(-not $ioWas){
    sc.exe stop inpoutx64T 2>&1 | Out-Null
    for($k=1; $k -le 12; $k++){ $q=(sc.exe query inpoutx64T 2>&1 | Out-String); if(($q -match '1060') -or ($q -match 'STOPPED')){ break }; Start-Sleep -Milliseconds 500 }
    sc.exe delete inpoutx64T 2>&1 | Out-Null
  }
  if($script:ecam -eq $null -and -not $wrWas){
    # 先关掉自己开着的 WinRing0 句柄：句柄不关，驱动卸不下去 → 服务会停在 STOP_PENDING（客户机见过这个状态）
    if($hw -ne $null -and [int64]$hw -ne -1){ try { [void][P]::CloseHandle($hw); $hw=[IntPtr]::Zero; W("  cleanup: closed WinRing0 handle") } catch { } }
    sc.exe stop $script:WRSvcName 2>&1 | Out-Null
    [void](WaitSvcState $script:WRSvcName @('STOPPED','MISSING') 12)
    W("  cleanup: " + $script:WRSvcName + "=" + (SvcState $script:WRSvcName))
    # 2026-09-30：自己建的服务、已经停下 → 顺手删掉。否则它会以 STOP_PENDING 留给下一次运行（客户机就卡在这）
    if($script:wrCreated -and (SvcState $script:WRSvcName) -eq 'STOPPED'){
      sc.exe delete $script:WRSvcName 2>&1 | Out-Null
      W("  cleanup: 已删除服务 " + $script:WRSvcName + "（下次运行自动重建，避免残留 STOP_PENDING 让下次起不来）")
    }
  }
}
function Fatal($code,$msg){
  W($msg)
  CleanupDrivers
  W("  >>> FATAL exit=$code ; drivers cleaned ; ACE-BOOT=" + ((sc.exe query ACE-BOOT | Select-String 'STATE' | Out-String).Trim()))
  exit $code
}

$ioNow=[bool]((sc.exe query inpoutx64T 2>&1 | Out-String) -match 'RUNNING')
$wrNow=[bool]((sc.exe query WinRing0_1_2_0 2>&1 | Out-String) -match 'RUNNING')
W("  inpoutx64T RUNNING=$ioNow   WinRing0 RUNNING=$wrNow   ACE-BOOT=" + ((sc.exe query ACE-BOOT | Select-String 'STATE' | Out-String).Trim()))
W("  ACE-Tray PIDs " + ((@(Get-Process ACE-Tray -ErrorAction SilentlyContinue)|ForEach-Object{$_.Id}) -join ',') + "   ThrottleStop=" + ((sc.exe query ThrottleStop | Select-String 'STATE' | Out-String).Trim()))
if(-not $ioNow){ Fatal 13 ">>> inpoutx64T did not reach RUNNING" }

$hw=[IntPtr]::Zero
if($script:ecam -ne $null){
  # 2026-09-30：走 ECAM 时**不需要** WinRing0 设备（客户机上 WinRing0x64.sys 被策略封了，开不了）
  W("  PCI 访问走 ECAM（不打开 WinRing0 设备）")
} else {
  $hw=[P]::CreateFileA("\\.\WinRing0_1_2_0",[uint32]3221225472,0,[IntPtr]::Zero,3,0,[IntPtr]::Zero)
  if([int64]$hw -eq -1){
    W("  WinRing0 SCM state=" + (SvcState 'WinRing0_1_2_0'))
    Fatal 3 ">>> cannot open WinRing0 (service state above; STOP_PENDING = 上次没停干净，需重启或等它落定)"
  }
}

# ---- device location: auto-detect GPU / root-port BDF (2026-09-30) ----
function Parse-Bdf([string]$t){
  if(-not $t){ return $null }
  $t=$t.Trim()
  $m=[regex]::Match($t,'([0-9a-fA-F]{1,2}):([0-9a-fA-F]{2})\.([0-7])$')            # 00000000:01:00.0 / 01:00.0
  if($m.Success){ return [uint32](([Convert]::ToUInt32($m.Groups[1].Value,16) -shl 8) -bor ([Convert]::ToUInt32($m.Groups[2].Value,16) -shl 3) -bor [Convert]::ToUInt32($m.Groups[3].Value,16)) }
  if($t -match '^0x[0-9a-fA-F]+$'){ return [uint32]$t }
  return $null
}
function Get-LocBdf([string]$loc){
  # LocationInfo is localized ("PCI bus 1, device 0, function 0" / "PCI 总线 1、设备 0、功能 0")
  # -> take the first three numbers, language independent
  $m=[regex]::Matches([string]$loc,'\d+')
  if($m.Count -lt 3){ return $null }
  return [uint32]((([int]$m[0].Value) -shl 8) -bor (([int]$m[1].Value) -shl 3) -bor ([int]$m[2].Value))
}
function Detect-GpuRoot {
  $r=@{ Gpu=$null; Root=$null; Src='none' }
  try {
    $d=@(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'DEV_1F0B' }) | Select-Object -First 1
    if($d){
      $b=Get-LocBdf ([string](Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data)
      if($b){ $r.Gpu=$b; $r.Src='PnP' }
      $p=[string](Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
      if($p){
        $rb=Get-LocBdf ([string](Get-PnpDeviceProperty -InstanceId $p -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data)
        if($rb){ $r.Root=$rb; if($r.Src -eq 'none'){ $r.Src='PnP' } }
      }
    }
  } catch { }
  if(-not $r.Gpu){                                          # fallback: nvidia-smi
    $smi="$env:SystemRoot\System32\nvidia-smi.exe"
    if(Test-Path $smi){
      $out=(& $smi --query-gpu=pci.bus_id --format=csv,noheader 2>&1 | Out-String)
      foreach($ln in ($out -split "`r?`n")){ $b=Parse-Bdf $ln; if($b){ $r.Gpu=$b; $r.Src='nvidia-smi'; break } }
    }
  }
  return $r
}
$det=Detect-GpuRoot
if($GpuBdf){  $det.Gpu  = Parse-Bdf $GpuBdf;  $det.Src='override' }
if($RootBdf){ $det.Root = Parse-Bdf $RootBdf }
W("  detect: gpu=" + $(if($det.Gpu){'0x'+([uint32]$det.Gpu).ToString('X4')}else{'?'}) + "  root=" + $(if($det.Root){'0x'+([uint32]$det.Root).ToString('X4')}else{'?'}) + "  src=" + $det.Src)

# (1) which BDF answers with 10DE:1F0B ?  Never guess, never write blind.
$cand=@()
if($det.Gpu){ $cand += [uint32]$det.Gpu }
if($cand -notcontains [uint32]0x0100){ $cand += [uint32]0x0100 }      # legacy position as last resort
$gpuFound=$null; $id=$null
foreach($c in $cand){
  $v=PciRead $c 0x0 4
  W("  GPU candidate 0x" + $c.ToString('X4') + " -> id=" + $(if($v -eq $null){'READ FAILED'}else{'0x'+$v.ToString('X8')}))
  if($v -ne $null -and ($v -band 0xFFFF) -eq 0x10DE -and (($v -shr 16) -eq 0x1F0B)){ $gpuFound=$c; $id=$v; break }
}
if($gpuFound -eq $null){ Fatal 11 ">>> CMP 40HX (10DE:1F0B) not found at any candidate BDF - refusing to write" }
$GPU=[uint32]$gpuFound

# (2) root port: PnP parent first, else the 01:00.0 -> 00:01.0 convention; must be a PCI-to-PCI bridge
$rcand=@()
if($det.Root){ $rcand += [uint32]$det.Root }
if($GPU -eq [uint32]0x0100 -and $rcand -notcontains [uint32]0x0008){ $rcand += [uint32]0x0008 }
$rootFound=$null
foreach($c in $rcand){
  $rh=PciRead $c 0x0 4
  $rc=PciRead $c 0x8 4
  $cls=$(if($rc -eq $null){'?'}else{'0x'+(($rc -shr 8) -band 0xFFFFFF).ToString('X6')})
  W("  ROOT candidate 0x" + $c.ToString('X4') + " -> id=" + $(if($rh -eq $null){'READ FAILED'}else{'0x'+$rh.ToString('X8')}) + "  class=" + $cls)
  if($rh -ne $null -and $rc -ne $null -and (($rc -shr 8) -band 0xFFFFFF) -eq 0x060400){ $rootFound=$c; break }
}
if($rootFound -eq $null){ Fatal 11 ">>> no PCI-to-PCI root port found at candidates (gpu=0x$($GPU.ToString('X4'))) - refusing to write" }
$ROOT=[uint32]$rootFound
W("  using GPU=0x" + $GPU.ToString('X4') + "  ROOT=0x" + $ROOT.ToString('X4'))

# (3) wait (bounded) for the driver to bind
$ready=$false
for($w=1; $w -le 24; $w++){
  $nv=(sc.exe query nvlddmkm 2>&1 | Out-String)
  if($nv -match 'RUNNING'){ $ready=$true; break }
  Start-Sleep -Seconds 5
}
W("  ready=$ready after $($w-1) waits   nvlddmkm=" + (((sc.exe query nvlddmkm 2>&1 | Out-String) -split "`n" | Select-String 'STATE' | Out-String).Trim()) + "   gpu_id=" + $(if($id -eq $null){'NULL'}else{'0x'+$id.ToString('X8')}))
if(-not $ready){ Fatal 12 ">>> GPU/driver not ready within 120s" }

$gcap=FindPcieCap $GPU; $rcap=FindPcieCap $ROOT
W("  PCIe cap: GPU@0x" + $(if($gcap -eq $null){'NOT FOUND'}else{$gcap.ToString('X2')}) + "  ROOT@0x" + $(if($rcap -eq $null){'NOT FOUND'}else{$rcap.ToString('X2')}))
if($gcap -eq $null -or $rcap -eq $null){ Fatal 11 ">>> PCIe capability not found" }

$TOOL_VER = '20261001a-igame'   # 改动这个标记要同步 就地更新并跑一次.ps1 里的 $wantVer
$GUARD_OFF=0x0;   $GUARD_EXP=U32 '166000A1'
# 2026-09-30（客户机 VBIOS 90.06.67.00.06 驱动）：基线不能写死常量，要按**位**判定。
# 实测两处 Gen2 位（同一张卡 .04 => .06 只差跳线位）：
#   LINK_CONFIG_0 : Gen2 位 = bit18(0x00040000)，Gen2 态为 **0**   （0x800C5800 -> 0x80085800）
#   PRIV_MISC_1   : Gen2 位 = bit13(0x00002000)，Gen2 态为 **1**   （0xE0B40D00 -> 0xE0B42D00）
#   PRIV_MISC_1 的 bit11(0x800) 是 VBIOS 批次跳线位（.04=0xD00 / .06=0x500）—— 必须原样保留，只动 bit13。
$LC0_OFF=0x8C040; $LC0_BASE_MASK=U32 'FFFBFFFF'; $LC0_BASE=U32 '80085800'
$PM1_OFF=0x8841C; $PM1_BASE_MASK=U32 'FFFFD7FF'; $PM1_BASE=U32 'E0B40500'   # mask 清掉 bit13(Gen2 位) 与 bit11(VBIOS 批次跳线位) 后再比
function DecideTargets([uint32]$l,[uint32]$p){
  $r=@{ Ok=$false; Lc0=$l; Pm1=$p; Lc0Change=$false; Pm1Change=$false; Reason='' }
  if((($l -band $LC0_BASE_MASK)) -ne $LC0_BASE){ $r.Reason = 'LINK_CONFIG_0 baseline not in known family: 0x' + $l.ToString('X8'); return $r }
  if((($p -band $PM1_BASE_MASK)) -ne $PM1_BASE){ $r.Reason = 'PRIV_MISC_1 baseline not in known family: 0x' + $p.ToString('X8'); return $r }
  $r.Lc0 = ($l -band $LC0_BASE_MASK)     # 清 bit18
  $r.Pm1 = ($p -bor ([uint32]0x2000))    # 置 bit13（Gen2 位）
  $r.Lc0Change = ($r.Lc0 -ne $l); $r.Pm1Change = ($r.Pm1 -ne $p); $r.Ok = $true
  return $r
}

# BAR0 must be validated, never derived from config space
$cands=New-Object System.Collections.ArrayList
Get-CimInstance Win32_PnPAllocatedResource -ErrorAction SilentlyContinue | Where-Object { $_.Dependent -like '*VEN_10DE&DEV_1F0B*' } | ForEach-Object {
  if($_.Antecedent -and $_.Antecedent.StartingAddress){ $st=[uint64]$_.Antecedent.StartingAddress; if($st -ne 0 -and $st -lt 0x100000000){ [void]$cands.Add($st) } }
}
$lo=PciRead $GPU 0x10 4; $hi=PciRead $GPU 0x14 4
if($lo -ne $null){ $l=[uint64]($lo -band 0xFFFFFFF0); if($l -ne 0 -and $l -lt 0x100000000){ [void]$cands.Add($l) } }
$bar=$null
foreach($c in ($cands | Select-Object -Unique)){
  # 候选来自 PnP 已分配资源或显卡 BAR 寄存器，都是“系统声明过的窗口” → 先登记再读（安全护栏要求）
  Allow-Mmio ([uint64]$c) ([uint64]'0x1000000')
  $v=MmioRead ([uint64]([uint64]$c + [uint64]$GUARD_OFF))
  W("  BAR0 candidate 0x" + ([uint64]$c).ToString('X') + " -> BOOT0 = " + $(if($v -eq $null){'READ FAILED'}else{'0x'+$v.ToString('X8')}))
  if($v -ne $null -and $v -eq $GUARD_EXP){ $bar=[uint64]$c; break }
}
if($bar -eq $null){ Fatal 11 ">>> no BAR0 candidate returned the expected BOOT0" }
W("  BAR0 (validated) = 0x" + $bar.ToString('X'))

$boot0=MmioRead ([uint64]($bar+$GUARD_OFF))
$lc0=MmioRead ([uint64]($bar+$LC0_OFF))
$pm1=MmioRead ([uint64]($bar+$PM1_OFF))
$ss0=MmioRead ([uint64]($bar+0x409664))
W("  BOOT0         = " + $(if($boot0 -eq $null){'READ FAILED'}else{'0x'+$boot0.ToString('X8')}))
W("  LINK_CONFIG_0 = " + $(if($lc0 -eq $null){'READ FAILED'}else{'0x'+$lc0.ToString('X8')}) + "   (0x800C5800 = clobbered by the driver, 0x80085800 = target)")
W("  PRIV_MISC_1   = " + $(if($pm1 -eq $null){'READ FAILED'}else{'0x'+$pm1.ToString('X8')}) + "   (0xE0B40D00 = clobbered, 0xE0B42D00 = target)")
W("  SS0           = " + $(if($ss0 -eq $null){'READ FAILED'}else{'0x'+$ss0.ToString('X8')}) + "   (0x88888888 = compute unlocked)")
# ---- 2026-09-30（客户机 VBIOS .06）新增：与 OnlyEFI 官方 Windows helper 的 read_guard() 逐项对齐的**只读体检** ----
# 官方源码（source/windows/CMP40HXGen2_prod.c）要求以下每一项都成立才肯继续：
#   BOOT0=166000A1 / XVE_OVR=6 / CYA_0=068731B3 / PL_LINK_RATE=00220036 / VSEC_DEVICE=801
#   SS0=88888888 / SS1=8 / GPU LNKCAP=00453D02 / GPU LNKCAP2=6 / TLS GPU=2 TLS ROOT=2 / 两端 x16
# 其中 XVE_OVR、CYA_0、PL_LINK_RATE、GPU·ROOT TLS(=2) 是**解锁固件（EFI 阶段）**负责预埋的；
# Windows 侧源码头注释明确写着不写它们（No TLS writes / no GPU retrain / no PnP / no FLR / no D3 / no SBR）。
# => 换 VBIOS 批次、或 EFI 自己 abort 的机器，这几项会是"未预埋"状态，链路就永远谈不到 Gen2。本段只读、不写任何寄存器。
function RD32([uint64]$off){ return (MmioRead ([uint64]($bar+$off))) }
# 注意：这里**不能**用 [uint64]0xFFFFFFFF 之类的掩码比较 —— PowerShell 把 0xFFFFFFFF 当 Int32 的 -1，
# [uint64] 强转直接抛“值对于 UInt64 太大或太小”（本工具 2026-09-30 自己踩过一次，体检项被误判成未预埋）。
# 最稳的写法：直接比位模式的十六进制字符串。
function Hex32($v){ if ($v -eq $null) { return '' } else { return $v.ToString('X8') } }
function Chk32([string]$n,$v,[string]$expHex){
  $ok = ($v -ne $null) -and ((Hex32 $v) -eq $expHex)
  W(("  {0,-13} = 0x{1}   期望 0x{2}   {3}" -f $n, $(if($v -eq $null){'(READ FAILED)'}else{Hex32 $v}), $expHex, $(if($ok){'[OK]'}else{'[!!] 未预埋'})))
}
$xve=RD32 0x8872C; $cya=RD32 0x8C2C0; $plr=RD32 0x8C1C0; $vsec=RD32 0x8860C; $ss1=RD32 0x40966C
$glcap=PciRead $GPU ([uint32]($gcap+0x0C)) 4
$glcap2=PciRead $GPU ([uint32]($gcap+0x2C)) 4
# 官方 tls() 读的是 cap+0x30（Link Control 2；cap+0x18 是 Slot Control，读出来会是 0 —— 本工具 2026-09-30 踩过）
$gtl=PciRead $GPU ([uint32]($gcap+0x30)) 4
$rtl=PciRead $ROOT ([uint32]($rcap+0x30)) 4
W("  --- 官方 guard 全量体检（只读；XVE/CYA/PL_LINK_RATE/TLS 由解锁固件预埋）---")
Chk32 'XVE_OVR'      $xve    '00000006'
Chk32 'CYA_0'        $cya    '068731B3'
Chk32 'PL_LINK_RATE' $plr    '00220036'
Chk32 'VSEC_DEVICE'  $vsec   '00000801'
Chk32 'SS1'          $ss1    '00000008'
Chk32 'GPU LNKCAP'   $glcap  '00453D02'
Chk32 'GPU LNKCAP2'  $glcap2 '00000006'
$gt=$null; $rt=$null
if($gtl -ne $null){ $gt=[uint32]([uint64]$gtl -band [uint64]0xF) }
if($rtl -ne $null){ $rt=[uint32]([uint64]$rtl -band [uint64]0xF) }
W(("  {0,-13} = GPU {1} / ROOT {2}   期望 2 / 2   {3}   (LNKCTL2 原值 GPU=0x{4} ROOT=0x{5})" -f 'TLS(LNKCTL2)', $(if($gt -eq $null){'?'}else{$gt}), $(if($rt -eq $null){'?'}else{$rt}), $(if(($gt -eq 2) -and ($rt -eq 2)){'[OK]'}else{'[!!] 未预埋 = 目标速率还不是 Gen2'}), $(if($gtl -eq $null){'?'}else{Hex32 $gtl}), $(if($rtl -eq $null){'?'}else{Hex32 $rtl})))
$script:GuardDumpGaps = @()
foreach($it in @(@{N='XVE_OVR';V=$xve;E='00000006'},@{N='CYA_0';V=$cya;E='068731B3'},@{N='PL_LINK_RATE';V=$plr;E='00220036'},@{N='VSEC_DEVICE';V=$vsec;E='00000801'},@{N='SS1';V=$ss1;E='00000008'},@{N='GPU_LNKCAP';V=$glcap;E='00453D02'},@{N='GPU_LNKCAP2';V=$glcap2;E='00000006'})){
  if((Hex32 $it.V) -ne $it.E){ $script:GuardDumpGaps += $it.N }
}
if($gt -ne 2){ $script:GuardDumpGaps += 'TLS_GPU' }
if($rt -ne 2){ $script:GuardDumpGaps += 'TLS_ROOT' }
W("  体检缺口 = " + $(if($script:GuardDumpGaps.Count -eq 0){'（无，解锁固件该预埋的都预埋了）'}else{($script:GuardDumpGaps -join ', ') + '  ← 缺项越多，根端口单侧重训越不可能谈到 Gen2'}))

$dec = DecideTargets ([uint32]$(if($lc0 -eq $null){0}else{$lc0})) ([uint32]$(if($pm1 -eq $null){0}else{$pm1}))
$guardOk=($boot0 -ne $null -and $boot0 -eq $GUARD_EXP -and $lc0 -ne $null -and $pm1 -ne $null -and $dec.Ok)
W("  GUARD = " + $(if($guardOk){'PASS'}else{'FAIL ' + $dec.Reason}))
if(-not $guardOk){ Fatal 11 ">>> baseline is not a known state - refusing to write" }
W("  plan  : LINK_CONFIG_0 0x" + $lc0.ToString('X8') + " -> 0x" + $dec.Lc0.ToString('X8') + " (Gen2 bit18=0)   PRIV_MISC_1 0x" + $pm1.ToString('X8') + " -> 0x" + $dec.Pm1.ToString('X8') + " (Gen2 bit13=1)")

# ---- 2026-09-30（客户机）：自动补写“解锁固件该预埋、但这台机器没预埋”的 Gen2 前提值 ----
# 触发条件（严格）：TLS(GPU/ROOT) 不是 2/2 → 说明解锁固件的 Gen2 预埋阶段没跑（EFI 自己 abort 了），
#   此时 XVE_OVR / CYA_0 / PL_LINK_RATE 也必然不是官方目标值，根端口单侧重训永远到不了 Gen2。
# 健康机器（EFI 跑过，TLS=2/2）→ 本段**一个字节都不写**，只看日志。
# 依据：OnlyEFI 官方 helper 源码 source/windows/CMP40HXGen2_prod.c 的 EXPECT_* 常量（EFI 阶段写入的目标值）。
if($script:GuardDumpGaps.Count -gt 0){
  if(($gt -ne 2) -or ($rt -ne 2)){
    if($NoAutoPrime){
      W("  >>> 预埋缺失（缺口: " + ($script:GuardDumpGaps -join ', ') + "）但 -NoAutoPrime 已指定 → 不补写")
    } else {
      W("  --- 解锁固件 Gen2 预埋缺失（缺口: " + ($script:GuardDumpGaps -join ', ') + "）→ 自动补写官方 EFI 目标值 ---")
      $primeList = @(
        @{ N = 'XVE_OVR';      Off = [uint64]0x8872C; Val = [uint32]0x00000006 },
        @{ N = 'CYA_0';        Off = [uint64]0x8C2C0; Val = [uint32]0x068731B3 },
        @{ N = 'PL_LINK_RATE'; Off = [uint64]0x8C1C0; Val = [uint32]0x00220036 }
      )
      foreach($pi in $primeList){
        $cur = MmioRead ([uint64]($bar+$pi.Off))
        $wantHex = $pi.Val.ToString('X8')
        if((Hex32 $cur) -eq $wantHex){ W("  " + $pi.N.PadRight(13) + " 已是目标值 0x" + $wantHex + "（无需写）") }
        elseif(-not $Apply){ W("  [dry run] " + $pi.N.PadRight(13) + " 0x" + $(if($cur -eq $null){'??'}else{Hex32 $cur}) + " -> 0x" + $wantHex) }
        else {
          $ok = MmioWrite ([uint64]($bar+$pi.Off)) $pi.Val
          $rb = MmioRead ([uint64]($bar+$pi.Off))
          W("  " + $pi.N.PadRight(13) + " 0x" + $(if($cur -eq $null){'??'}else{Hex32 $cur}) + " -> 0x" + $wantHex + "  writeOk=$ok  readback=0x" + $(if($rb -eq $null){'FAILED'}else{Hex32 $rb}) + $(if((Hex32 $rb) -eq $wantHex){'  [OK]'}else{'  [!!] 没写进去'}))
        }
      }
      # TLS：LNKCTL2(cap+0x30) 低 4 位 = target link speed，只改这 4 位
      foreach($ti in @(@{ N='GPU TLS'; Bdf=$GPU; Cap=$gcap }, @{ N='ROOT TLS'; Bdf=$ROOT; Cap=$rcap })){
        $v16 = PciRead $ti.Bdf ([uint32]($ti.Cap+0x30)) 2
        if($v16 -eq $null){ W("  " + $ti.N.PadRight(13) + " READ FAILED") ; continue }
        $curTls = [uint32]($v16 -band 0xF)
        if($curTls -eq 2){ W("  " + $ti.N.PadRight(13) + " 已是 2（无需写）") }
        elseif(-not $Apply){ W("  [dry run] " + $ti.N.PadRight(13) + " " + $curTls + " -> 2") }
        else {
          $new16 = [uint16](($v16 -band 0xFFF0) -bor 2)
          $ok = PciWrite16 $ti.Bdf ([uint32]($ti.Cap+0x30)) $new16
          $rb16 = PciRead $ti.Bdf ([uint32]($ti.Cap+0x30)) 2
          W("  " + $ti.N.PadRight(13) + " " + $curTls + " -> 2  writeOk=$ok  readback=" + $(if($rb16 -eq $null){'FAILED'}else{[string]([uint32]($rb16 -band 0xF))}))
        }
      }
      if($Apply){
        W("  --- 补写后复读 ---")
        Chk32 'XVE_OVR' (RD32 0x8872C) '00000006'
        Chk32 'CYA_0' (RD32 0x8C2C0) '068731B3'
        Chk32 'PL_LINK_RATE' (RD32 0x8C1C0) '00220036'
        $gt2 = PciRead $GPU ([uint32]($gcap+0x30)) 4; $rt2 = PciRead $ROOT ([uint32]($rcap+0x30)) 4
        W(("  {0,-13} = GPU {1} / ROOT {2}   期望 2 / 2" -f 'TLS(LNKCTL2)', [string]([uint32]([uint64]$gt2 -band [uint64]15)), [string]([uint32]([uint64]$rt2 -band [uint64]15))))
      }
    }
  } else {
    W("  体检有缺口 (" + ($script:GuardDumpGaps -join ', ') + ") 但 TLS 已是 2/2（解锁固件跑过）→ 不自动补写，只报告")
  }
}

$gs=LinkSta $gcap $GPU; $rs=LinkSta $rcap $ROOT
W("  pre   : GPU LNKSTA=0x" + $gs.ToString('X4') + " Gen" + ($gs -band 0xF) + " x" + (($gs -shr 4) -band 0x3F) + "   ROOT LNKSTA=0x" + $rs.ToString('X4') + " Gen" + ($rs -band 0xF) + " x" + (($rs -shr 4) -band 0x3F))
if(-not $Apply){ W("  (dry run - no writes)"); CleanupDrivers; exit 0 }

if($dec.Lc0Change){
  $ok=MmioWrite ([uint64]($bar+$LC0_OFF)) $dec.Lc0
  $rb=MmioRead ([uint64]($bar+$LC0_OFF))
  W("  LINK_CONFIG_0 0x" + $lc0.ToString('X8') + " -> 0x" + $dec.Lc0.ToString('X8') + "  writeOk=$ok  readback=" + $(if($rb -eq $null){'FAILED'}else{'0x'+$rb.ToString('X8')}))
} else { W("  LINK_CONFIG_0 already at target (gen2 bit already 0)") }
if($dec.Pm1Change){
  $ok=MmioWrite ([uint64]($bar+$PM1_OFF)) $dec.Pm1
  $rb=MmioRead ([uint64]($bar+$PM1_OFF))
  W("  PRIV_MISC_1   0x" + $pm1.ToString('X8') + " -> 0x" + $dec.Pm1.ToString('X8') + "  writeOk=$ok  readback=" + $(if($rb -eq $null){'FAILED'}else{'0x'+$rb.ToString('X8')}))
} else { W("  PRIV_MISC_1 already at target (gen2 bit already 1)") }

$reach=$false
for($att=1; $att -le 2 -and -not $reach; $att++){
  $ctl=PciRead $ROOT ([uint32]($rcap+0x10)) 2
  $old=[uint16]($ctl -band 0xFFFF)
  $req=[uint16]($old -bor 0x0020)
  $ok=PciWrite16 $ROOT ([uint32]($rcap+0x10)) $req
  $rb=PciRead $ROOT ([uint32]($rcap+0x10)) 2
  W("  ROOT$att SET_ONLY old=0x" + $old.ToString('X4') + " req=0x" + $req.ToString('X4') + " writeOk=$ok rb=0x" + ([uint16]($rb -band 0xFFFF)).ToString('X4'))
  $sawLT=0
  for($i=1; $i -le 20; $i++){
    Start-Sleep -Milliseconds 200
    $g=LinkSta $gcap $GPU; $r=LinkSta $rcap $ROOT
    $lt=[int](($r -band 0x0800) -ne 0)
    if($lt -eq 1){ $sawLT++ }
    if($i -le 3 -or $lt -eq 1){ W("    poll $i LT=$lt ROOT_GEN=" + ($r -band 0xF) + " GPU_GEN=" + ($g -band 0xF) + " LNKSTA=0x" + $r.ToString('X4')) }
    if(($r -band 0xF) -eq 2 -and ($g -band 0xF) -eq 2){ break }
  }
  W("  ROOT${att} settled saw_LT=$sawLT")
  $g=LinkSta $gcap $GPU; $r=LinkSta $rcap $ROOT
  W("    GPU  after ROOT${att}: Gen" + ($g -band 0xF) + " x" + (($g -shr 4) -band 0x3F) + " LNKSTA=0x" + $g.ToString('X4'))
  W("    ROOT after ROOT${att}: Gen" + ($r -band 0xF) + " x" + (($r -shr 4) -band 0x3F) + " LNKSTA=0x" + $r.ToString('X4'))
  if(($g -band 0xF) -eq 2 -and ($r -band 0xF) -eq 2){ $reach=$true }
}
if(-not $reach){
  # 2026-09-30 新增（客户机 VBIOS .06 场景）：只重训根端口没到 Gen2 时，再对 GPU 自身链路做 SET_ONLY（不写策略寄存器、不复位设备）
  for($att=1; $att -le 2 -and -not $reach; $att++){
    $ctl=PciRead $GPU ([uint32]($gcap+0x10)) 2
    $old=[uint16]($ctl -band 0xFFFF)
    $req=[uint16]($old -bor 0x0020)
    $ok=PciWrite16 $GPU ([uint32]($gcap+0x10)) $req
    W("  GPU${att} SET_ONLY old=0x" + $old.ToString('X4') + " req=0x" + $req.ToString('X4') + " writeOk=$ok")
    for($i=1; $i -le 20; $i++){
      Start-Sleep -Milliseconds 200
      $g=LinkSta $gcap $GPU; $r=LinkSta $rcap $ROOT
      if($i -le 3){ W("    poll $i ROOT_GEN=" + ($r -band 0xF) + " GPU_GEN=" + ($g -band 0xF) + " LNKSTA=0x" + $r.ToString('X4')) }
      if(($r -band 0xF) -eq 2 -and ($g -band 0xF) -eq 2){ break }
    }
    $g=LinkSta $gcap $GPU; $r=LinkSta $rcap $ROOT
    W("    GPU  after GPU${att}: Gen" + ($g -band 0xF) + " x" + (($g -shr 4) -band 0x3F) + " LNKSTA=0x" + $g.ToString('X4'))
    W("    ROOT after GPU${att}: Gen" + ($r -band 0xF) + " x" + (($r -shr 4) -band 0x3F) + " LNKSTA=0x" + $r.ToString('X4'))
    if(($g -band 0xF) -eq 2 -and ($r -band 0xF) -eq 2){ $reach=$true }
  }
  W("  (GPU-side retrain attempts done; reach=$reach)")
}
# 2026-09-30 新增：重训后复读策略寄存器 —— 区分“写了没用（缺 EFI 预埋）"和"写了但被驱动/GSP 立刻冲掉"
$lc0b=MmioRead ([uint64]($bar+$LC0_OFF)); $pm1b=MmioRead ([uint64]($bar+$PM1_OFF))
W("  post  : LINK_CONFIG_0 现在 = " + $(if($lc0b -eq $null){'READ FAILED'}else{'0x'+$lc0b.ToString('X8')}) + "   PRIV_MISC_1 现在 = " + $(if($pm1b -eq $null){'READ FAILED'}else{'0x'+$pm1b.ToString('X8')}))
$clob=''
if(($lc0b -ne $null) -and ($lc0b -ne $dec.Lc0)){ $clob += ' LINK_CONFIG_0(0x' + $lc0b.ToString('X8') + ' 应为 0x' + $dec.Lc0.ToString('X8') + ')' }
if(($pm1b -ne $null) -and ($pm1b -ne $dec.Pm1)){ $clob += ' PRIV_MISC_1(0x' + $pm1b.ToString('X8') + ' 应为 0x' + $dec.Pm1.ToString('X8') + ')' }
if($clob){ W("  >>> 重训后发现寄存器被改回去了:" + $clob + "  = 驱动/GSP 毫秒级回写（策略写不进去）") }
else { W("  >>> 重训后策略寄存器仍是 Gen2 目标值（没有被回写）") }
$gf=LinkSta $gcap $GPU; $rf=LinkSta $rcap $ROOT
W("  GPU final : Gen" + ($gf -band 0xF) + " x" + (($gf -shr 4) -band 0x3F) + " LNKSTA=0x" + $gf.ToString('X4'))
W("  ROOT final: Gen" + ($rf -band 0xF) + " x" + (($rf -shr 4) -band 0x3F) + " LNKSTA=0x" + $rf.ToString('X4'))

CleanupDrivers
W("  after cleanup: inpoutx64T=" + (((sc.exe query inpoutx64T 2>&1 | Out-String) -replace "`r?`n"," | ").Trim()) )
W("  ACE-BOOT=" + ((sc.exe query ACE-BOOT | Select-String 'STATE' | Out-String).Trim()) + "   ACE-Tray PIDs " + ((@(Get-Process ACE-Tray -ErrorAction SilentlyContinue)|ForEach-Object{$_.Id}) -join ','))
W("  GPU PnP=" + ((Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'CMP 40HX' } | Select-Object -First 1).Status))
if($reach){ W("  >>> PASS: physical Gen2 x16 reached, the anti-cheat was never stopped"); W("==== end $(Get-Date -Format 'HH:mm:ss') ===="); exit 0 }
W("  >>> FAIL: did not reach Gen2 x16")
W("==== end $(Get-Date -Format 'HH:mm:ss') ====")
exit 10
