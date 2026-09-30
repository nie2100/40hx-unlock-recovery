param([switch]$Apply, [string]$GpuBdf = '', [string]$RootBdf = '')
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

function PciRead([uint32]$bdf,[uint32]$off,[uint32]$len){
  $in=New-Object byte[] 8; [Array]::Copy([BitConverter]::GetBytes($bdf),0,$in,0,4); [Array]::Copy([BitConverter]::GetBytes($off),0,$in,4,4)
  $o=New-Object byte[] 4; $n=[uint32]0
  if(-not [P]::DeviceIoControl($hw,$RD_PCI,$in,8,$o,$len,[ref]$n,[IntPtr]::Zero)){ return $null }
  return [BitConverter]::ToUInt32($o,0)
}
function PciWrite16([uint32]$bdf,[uint32]$off,[uint16]$val){
  $in=New-Object byte[] 10
  [Array]::Copy([BitConverter]::GetBytes($bdf),0,$in,0,4); [Array]::Copy([BitConverter]::GetBytes($off),0,$in,4,4)
  [Array]::Copy([BitConverter]::GetBytes($val),0,$in,8,2)
  $o=New-Object byte[] 1; $n=[uint32]0
  return [P]::DeviceIoControl($hw,$WR_PCI,$in,10,$o,1,[ref]$n,[IntPtr]::Zero)
}
function FindPcieCap([uint32]$bdf){
  $st=PciRead $bdf 0x34 1
  if($st -eq $null){ return $null }
  $p=[int]($st -band 0xFF); $g=0
  while($p -ne 0 -and $g -lt 32){
    $g++
    $hdr=PciRead $bdf ([uint32]$p) 2
    if($hdr -eq $null){ return $null }
    $id=[int]($hdr -band 0xFF); $nx=[int](($hdr -shr 8) -band 0xFF)
    if($id -eq 0x10){ return $p }
    $p=$nx
  }
  return $null
}
function LinkSta([uint32]$cap,[uint32]$bdf){
  $v=PciRead $bdf ([uint32]($cap+0x12)) 2
  if($v -eq $null){ return $null }
  return [uint32]($v -band 0xFFFF)
}
function MmioRead([uint64]$addr){
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
W("==== 40HX Gen2 retrain (inpoutx64 MMIO + WinRing0 PCI, anti-cheat untouched)   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Apply=$Apply ====")
try {
  $smi="$env:SystemRoot\System32\nvidia-smi.exe"
  if(Test-Path $smi){ W("  vbios/driver: " + ((& $smi --query-gpu=vbios_version,driver_version --format=csv,noheader 2>&1 | Out-String).Trim())) }
} catch { }
try {
  $bl = [string](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Name 'VulnerableDriverBlocklistEnable' -ErrorAction SilentlyContinue).VulnerableDriverBlocklistEnable
  W("  VulnerableDriverBlocklistEnable=" + $(if($bl -eq ''){'<未设置>'}else{$bl}))
} catch { }
W("  admin=$adm   sys_driver=" + (Test-Path $SYS) + "   dll=" + (Test-Path $DLL))
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
$wrWas=(SvcState 'WinRing0_1_2_0') -eq 'RUNNING'
if(-not $wrWas){
  $WRF='C:\Windows\System32\drivers\WinRing0x64.sys'
  if(-not (Test-Path $WRF)){
    foreach($s in @('C:\ProgramData\CMP40HXGen2\drivers\WinRing0x64.sys','C:\ProgramData\40HXUnlock\drivers\WinRing0x64.sys')){
      if(-not (Test-Path $WRF) -and (Test-Path $s)){ Copy-Item $s $WRF -Force -ErrorAction SilentlyContinue }
    }
  }
  if(-not (Test-Path $WRF)){ W(">>> WinRing0x64.sys missing and no source"); exit 3 }
  # 2026-09-30（客户机实测 Start=4 DISABLED）：360/ACE/易受攻击驱动列表都可能把启动类型改掉 → 启动前纠正
  if((SvcState 'WinRing0_1_2_0') -ne 'MISSING'){
    $stp=(sc.exe qc WinRing0_1_2_0 2>&1 | Out-String)
    if($stp -notmatch 'DEMAND_START'){
      W("  WinRing0 start type=" + $(([regex]::Match($stp,'START_TYPE\s*:\s*\d+\s+(\S+)').Groups[1].Value)) + " -> fixing to demand")
      sc.exe config WinRing0_1_2_0 start= demand 2>&1 | Out-Null
      W("  WinRing0 start type now=" + $([regex]::Match((sc.exe qc WinRing0_1_2_0 2>&1 | Out-String),'START_TYPE\s*:\s*\d+\s+(\S+)').Groups[1].Value))
    }
  }
  $wrPre=SvcState 'WinRing0_1_2_0'
  W("  WinRing0 pre-state=$wrPre   sysfile=" + (Test-Path $WRF))
  if($wrPre -eq 'STOP_PENDING'){
    # 上次 stop 没收尾（进程被强杀/文件被删）→ 这时 start 必然失败；先等它落定
    [void](WaitSvcState 'WinRing0_1_2_0' @('STOPPED','MISSING','RUNNING') 45)
    W("  WinRing0 after wait=" + (SvcState 'WinRing0_1_2_0'))
  }
  if((SvcState 'WinRing0_1_2_0') -eq 'MISSING'){
    sc.exe create WinRing0_1_2_0 type= kernel start= demand binPath= '\SystemRoot\System32\drivers\WinRing0x64.sys' 2>&1 | Out-Null
    W("  WinRing0 create -> " + (SvcState 'WinRing0_1_2_0'))
  }
  for($k=1; $k -le 3; $k++){
    $o=(sc.exe start WinRing0_1_2_0 2>&1 | Out-String).Trim()
    Start-Sleep -Milliseconds 1200
    $now=SvcState 'WinRing0_1_2_0'
    W("  WinRing0 start try ${k} -> $now  [" + ($o -replace "`r?`n",' | ') + "]")
    if($now -eq 'RUNNING'){ break }
    if($now -eq 'STOP_PENDING'){ [void](WaitSvcState 'WinRing0_1_2_0' @('STOPPED','MISSING','RUNNING') 20) }
    Start-Sleep -Seconds 2
  }
}
function CleanupDrivers(){
  if(-not $ioWas){
    sc.exe stop inpoutx64T 2>&1 | Out-Null
    for($k=1; $k -le 12; $k++){ $q=(sc.exe query inpoutx64T 2>&1 | Out-String); if(($q -match '1060') -or ($q -match 'STOPPED')){ break }; Start-Sleep -Milliseconds 500 }
    sc.exe delete inpoutx64T 2>&1 | Out-Null
  }
  if(-not $wrWas){
    # 先关掉自己开着的 WinRing0 句柄：句柄不关，驱动卸不下去 → 服务会停在 STOP_PENDING（客户机见过这个状态）
    if($hw -ne $null -and [int64]$hw -ne -1){ try { [void][P]::CloseHandle($hw); $hw=[IntPtr]::Zero; W("  cleanup: closed WinRing0 handle") } catch { } }
    sc.exe stop WinRing0_1_2_0 2>&1 | Out-Null
    [void](WaitSvcState 'WinRing0_1_2_0' @('STOPPED','MISSING') 20)
    W("  cleanup: WinRing0=" + (SvcState 'WinRing0_1_2_0'))
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

$hw=[P]::CreateFileA("\\.\WinRing0_1_2_0",[uint32]3221225472,0,[IntPtr]::Zero,3,0,[IntPtr]::Zero)
if([int64]$hw -eq -1){
  W("  WinRing0 SCM state=" + (SvcState 'WinRing0_1_2_0'))
  Fatal 3 ">>> cannot open WinRing0 (service state above; STOP_PENDING = 上次没停干净，需重启或等它落定)"
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
$dec = DecideTargets ([uint32]$(if($lc0 -eq $null){0}else{$lc0})) ([uint32]$(if($pm1 -eq $null){0}else{$pm1}))
$guardOk=($boot0 -ne $null -and $boot0 -eq $GUARD_EXP -and $lc0 -ne $null -and $pm1 -ne $null -and $dec.Ok)
W("  GUARD = " + $(if($guardOk){'PASS'}else{'FAIL ' + $dec.Reason}))
if(-not $guardOk){ Fatal 11 ">>> baseline is not a known state - refusing to write" }
W("  plan  : LINK_CONFIG_0 0x" + $lc0.ToString('X8') + " -> 0x" + $dec.Lc0.ToString('X8') + " (Gen2 bit18=0)   PRIV_MISC_1 0x" + $pm1.ToString('X8') + " -> 0x" + $dec.Pm1.ToString('X8') + " (Gen2 bit13=1)")

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
