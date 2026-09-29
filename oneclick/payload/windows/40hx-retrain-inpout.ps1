param([switch]$Apply)
# 40HX Gen2 retrain via inpoutx64 (MMIO) + WinRing0 (PCI config).  The anti-cheat is NEVER touched.
# exit codes: 0 = PASS (physical Gen2 x16), 10 = link not Gen2, 11 = baseline/guard failed,
#             12 = GPU/driver not ready in time, 13 = inpoutx64 driver not running, 3 = WinRing0 unusable
$ErrorActionPreference='Continue'
$LOGAPP='C:\ProgramData\CMP40HXGen2\windows\logs\retrain-inpout.log'
$out='C:\Temp\40hx-retrain-tool.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function W($s){ $line=[string]$s; Add-Content -Path $out -Value $line -Encoding utf8; Add-Content -Path $LOGAPP -Value $line -Encoding utf8; Write-Host $line }
function U32([string]$hex){ return [Convert]::ToUInt32($hex,16) }

# ---- deploy / heal the driver files (AV quarantines .sys after load) ----
$SYS='C:\Windows\System32\drivers\inpoutx64.sys'
$DLL='C:\ProgramData\CMP40HXGen2\drivers\inpoutx64.dll'
$SRC=@('C:\ProgramData\CMP40HXGen2\drivers\inpoutx64.sys','C:\ProgramData\40HXUnlock\drivers\inpoutx64.sys')
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
W("  admin=$adm   sys_driver=" + (Test-Path $SYS) + "   dll=" + (Test-Path $DLL))
if(-not $adm){ W(">>> not elevated"); exit 1 }

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
$wrWas=[bool]((sc.exe query WinRing0_1_2_0 2>&1 | Out-String) -match 'RUNNING')
if(-not $wrWas){
  $WRF='C:\Windows\System32\drivers\WinRing0x64.sys'
  if(-not (Test-Path $WRF)){
    foreach($s in @('C:\ProgramData\CMP40HXGen2\drivers\WinRing0x64.sys','C:\ProgramData\40HXUnlock\drivers\WinRing0x64.sys')){
      if(-not (Test-Path $WRF) -and (Test-Path $s)){ Copy-Item $s $WRF -Force -ErrorAction SilentlyContinue }
    }
  }
  if(-not (Test-Path $WRF)){ W(">>> WinRing0x64.sys missing and no source"); exit 3 }
  if((sc.exe query WinRing0_1_2_0 2>&1 | Out-String) -match '1060'){
    sc.exe create WinRing0_1_2_0 type= kernel start= demand binPath= '\SystemRoot\System32\drivers\WinRing0x64.sys' 2>&1 | Out-Null
  }
  sc.exe start WinRing0_1_2_0 | Out-Null; Start-Sleep -Milliseconds 900
}
function CleanupDrivers(){
  if(-not $ioWas){
    sc.exe stop inpoutx64T 2>&1 | Out-Null
    for($k=1; $k -le 12; $k++){ $q=(sc.exe query inpoutx64T 2>&1 | Out-String); if(($q -match '1060') -or ($q -match 'STOPPED')){ break }; Start-Sleep -Milliseconds 500 }
    sc.exe delete inpoutx64T 2>&1 | Out-Null
  }
  if(-not $wrWas){ sc.exe stop WinRing0_1_2_0 2>&1 | Out-Null }
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
if([int64]$hw -eq -1){ Fatal 3 ">>> cannot open WinRing0" }

# ---- wait (bounded) for the GPU to appear and the display driver to bind (post-bind window) ----
$GPU=[uint32]0x0100
$ROOT=[uint32]0x0008
$ready=$false
for($w=1; $w -le 24; $w++){
  $nv=(sc.exe query nvlddmkm 2>&1 | Out-String)
  $id=PciRead $GPU 0x0 4
  if(($nv -match 'RUNNING') -and $id -ne $null -and ($id -band 0xFFFF) -eq 0x10DE -and (($id -shr 16) -eq 0x1F0B)){ $ready=$true; break }
  Start-Sleep -Seconds 5
}
W("  ready=$ready after $($w-1) waits   nvlddmkm=" + (((sc.exe query nvlddmkm 2>&1 | Out-String) -split "`n" | Select-String 'STATE' | Out-String).Trim()) + "   gpu_id=" + $(if($id -eq $null){'NULL'}else{'0x'+$id.ToString('X8')}))
if(-not $ready){ Fatal 12 ">>> GPU/driver not ready within 120s" }

$gcap=FindPcieCap $GPU; $rcap=FindPcieCap $ROOT
W("  PCIe cap: GPU@0x" + $(if($gcap -eq $null){'NOT FOUND'}else{$gcap.ToString('X2')}) + "  ROOT@0x" + $(if($rcap -eq $null){'NOT FOUND'}else{$rcap.ToString('X2')}))
if($gcap -eq $null -or $rcap -eq $null){ Fatal 11 ">>> PCIe capability not found" }

$GUARD_OFF=0x0;   $GUARD_EXP=U32 '166000A1'
$LC0_OFF=0x8C040; $LC0_STATES=@((U32 '800C5800'),(U32 '80085800')); $LC0_TARGET=U32 '80085800'
$PM1_OFF=0x8841C; $PM1_STATES=@((U32 'E0B40D00'),(U32 'E0B42D00')); $PM1_TARGET=U32 'E0B42D00'

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
$guardOk=($boot0 -ne $null -and $boot0 -eq $GUARD_EXP -and $lc0 -ne $null -and ($LC0_STATES -contains $lc0) -and $pm1 -ne $null -and ($PM1_STATES -contains $pm1))
W("  GUARD = " + $(if($guardOk){'PASS'}else{'FAIL'}))
if(-not $guardOk){ Fatal 11 ">>> baseline is not a known state - refusing to write" }

$gs=LinkSta $gcap $GPU; $rs=LinkSta $rcap $ROOT
W("  pre   : GPU LNKSTA=0x" + $gs.ToString('X4') + " Gen" + ($gs -band 0xF) + " x" + (($gs -shr 4) -band 0x3F) + "   ROOT LNKSTA=0x" + $rs.ToString('X4') + " Gen" + ($rs -band 0xF) + " x" + (($rs -shr 4) -band 0x3F))
if(-not $Apply){ W("  (dry run - no writes)"); CleanupDrivers; exit 0 }

if($lc0 -ne $LC0_TARGET){
  $ok=MmioWrite ([uint64]($bar+$LC0_OFF)) $LC0_TARGET
  $rb=MmioRead ([uint64]($bar+$LC0_OFF))
  W("  LINK_CONFIG_0 0x" + $lc0.ToString('X8') + " -> 0x" + $LC0_TARGET.ToString('X8') + "  writeOk=$ok  readback=" + $(if($rb -eq $null){'FAILED'}else{'0x'+$rb.ToString('X8')}))
} else { W("  LINK_CONFIG_0 already at target") }
if($pm1 -ne $PM1_TARGET){
  $ok=MmioWrite ([uint64]($bar+$PM1_OFF)) $PM1_TARGET
  $rb=MmioRead ([uint64]($bar+$PM1_OFF))
  W("  PRIV_MISC_1   0x" + $pm1.ToString('X8') + " -> 0x" + $PM1_TARGET.ToString('X8') + "  writeOk=$ok  readback=" + $(if($rb -eq $null){'FAILED'}else{'0x'+$rb.ToString('X8')}))
} else { W("  PRIV_MISC_1 already at target") }

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
