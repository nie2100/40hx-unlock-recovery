# 40HX candidate driver test - READ ONLY, needs Administrator
# Loads inpoutx64.sys as a temporary service, maps GPU BAR0, reads the registers,
# compares to the known-good values, then removes the service. No MMIO writes.
$ErrorActionPreference = 'Continue'
$out = 'C:\Temp\40hx-cand-inpout.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function W($s) { $s | Out-File $out -Append -Encoding utf8; Write-Host $s }

function CTL([uint32]$t,[uint32]$f,[int]$a){ return [uint32]((([int64]$t) -shl 16) -bor (([int64]$a) -shl 14) -bor (([int64]$f) -shl 2)) }

$cs = @"
using System;
using System.Runtime.InteropServices;
public static class DD {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Ansi)] public static extern IntPtr CreateFileA(string n,uint a,uint s,IntPtr sec,uint d,uint f,IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool DeviceIoControl(IntPtr h,uint c,byte[] i,uint isz,byte[] o,uint osz,out uint r,IntPtr ov);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("D:\\40hx-unlock\\cand2\\inpoutx64.dll", EntryPoint="MapPhysToLin", CallingConvention=CallingConvention.StdCall, SetLastError=true)]
  public static extern IntPtr MapPhysToLin(IntPtr pbPhysAddr, uint dwPhysSize, out IntPtr pPhysicalMemoryHandle);
  [DllImport("D:\\40hx-unlock\\cand2\\inpoutx64.dll", EntryPoint="UnMapPhysicalMemory", CallingConvention=CallingConvention.StdCall, SetLastError=true)]
  public static extern bool UnMapPhysicalMemory(IntPtr pPhysicalMemoryHandle, IntPtr pbPhysAddr);
}
"@
Add-Type -TypeDefinition $cs -ErrorAction Stop

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$princ = New-Object Security.Principal.WindowsPrincipal($id)
$isAdmin = $princ.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

W("==== inpoutx64 candidate test (READ ONLY)   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====")
W("  running as  : " + $id.Name)
W("  IsAdmin     : $isAdmin")
W("")
if (-not $isAdmin) {
  W(">>> NOT ELEVATED - right-click this script and choose 'Run as administrator'. Aborting.")
  exit 1
}

# ---- 1) ACE state before ----
W("---- 1) ACE state BEFORE (must stay RUNNING all along) ----")
W("  ACE-BOOT    : " + ((sc.exe query ACE-BOOT | Select-String 'STATE' | Out-String).Trim()))
W("  ACE-Tray    : PIDs " + ((@(Get-Process ACE-Tray -ErrorAction SilentlyContinue) | ForEach-Object { $_.Id }) -join ','))
W("  ThrottleStop: " + ((sc.exe query ThrottleStop | Select-String 'STATE' | Out-String).Trim()))

# ---- 2) GPU BAR0 (WMI, no driver needed) ----
W("")
W("---- 2) GPU BAR0 ----")
$bar = [uint64]0
$memres = Get-CimInstance Win32_PnPAllocatedResource -ErrorAction SilentlyContinue | Where-Object { $_.Dependent -like '*VEN_10DE&DEV_1F0B*' }
foreach ($r in $memres) {
  $a = $r.Antecedent
  if ($a -and $a.StartingAddress) {
    $st = [uint64]$a.StartingAddress
    W("  memory range start = 0x" + $st.ToString('X'))
    if ($bar -eq 0 -and $st -lt 0x100000000) { $bar = $st }   # BAR0 is the low one (below 4GB)
  }
}
if ($bar -eq 0) { $bar = [uint64]0x40000000 }
W("  using BAR0 = 0x" + $bar.ToString('X'))

# ---- 3) install inpoutx64 as temp service ----
W("")
W("---- 3) install inpoutx64.sys (temp service) ----")
$drv = 'D:\40hx-unlock\cand2\inpoutx64.sys'
W("  file: $drv  " + (Get-Item $drv).Length + " B")
& sc.exe delete inpoutx64T 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$c = (& sc.exe create inpoutx64T type= kernel start= demand binPath= $drv 2>&1 | Out-String).Trim()
W("  create : " + ($c -replace "`r?`n", " | "))
Start-Sleep -Milliseconds 400
$s = (& sc.exe start inpoutx64T 2>&1 | Out-String).Trim()
W("  start  : " + ($s -replace "`r?`n", " | "))
Start-Sleep -Milliseconds 900
W("  state  : " + ((& sc.exe query inpoutx64T 2>&1 | Out-String).Trim() -replace "`r?`n", " | "))
W("  ACE-BOOT after install: " + ((sc.exe query ACE-BOOT | Select-String 'STATE' | Out-String).Trim()))

# ---- 4) map and read (READ ONLY) ----
W("")
W("---- 4) MapPhysToLin + read registers (READ ONLY) ----")
$regs = @(
  @('BOOT0',          0x0,      '166000A1'),
  @('XVE_OVR',        0x8872C,  '00000006'),
  @('CYA_0',          0x8C2C0,  '068731B3'),
  @('PL_LINK_RATE',   0x8C1C0,  '00220036'),
  @('VSEC_DEVICE',    0x8860C,  '00000801'),
  @('LINK_CONFIG_0',  0x8C040,  '80085800'),
  @('PRIV_MISC_1',    0x8841C,  'E0B42D00'),
  @('SS0',            0x409664, '88888888'),
  @('SS1',            0x40966C, '00000008')
)
$first = $null
foreach ($r in $regs) {
  $name = $r[0]; $off = [uint64]$r[1]
  $h = [IntPtr]::Zero
  $v = [DD]::MapPhysToLin([IntPtr][int64]($bar + $off), 4096, [ref]$h)
  if ($v -ne [IntPtr]::Zero -and [int64]$v -ne -1) {
    $b = New-Object byte[] 4
    [Runtime.InteropServices.Marshal]::Copy($v, $b, 0, 4)
    $val = [BitConverter]::ToUInt32($b, 0)
    $expected = [uint32]::Parse($r[2], [Globalization.NumberStyles]::HexNumber)
    $mark = if ($val -eq $expected) { 'MATCH' } else { 'diff ' }
    W("  " + $name.PadRight(14) + " = 0x" + $val.ToString('X8') + "   expect 0x" + $expected.ToString('X8') + "   $mark")
    if ($name -eq 'BOOT0') { $first = $val }
    [DD]::UnMapPhysicalMemory($h, $v) | Out-Null
  } else {
    W("  " + $name.PadRight(14) + " MAP FAILED err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
  }
}
W("")
if ($first -eq 0x166000A1) {
  W(">>> VERDICT: PASS - inpoutx64 reads GPU MMIO with ACE running. This driver can replace ThrottleStop.")
  W(">>> Next step would be: write LINK_CONFIG_0 / PRIV_MISC_1 through the same handle (needs your OK).")
} else {
  W(">>> VERDICT: read did not return 0x166000A1 (got $(if($first -eq $null){'NULL'}else{'0x' + ([uint32]$first).ToString('X8')})) - driver may be blocked or BAR changed.")
}

# ---- 5) cleanup ----
W("")
W("---- 5) cleanup ----")
& sc.exe stop inpoutx64T 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
& sc.exe delete inpoutx64T 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
W("  service after cleanup: " + ((& sc.exe query inpoutx64T 2>&1 | Out-String).Trim() -replace "`r?`n", " | "))
W("  ACE-BOOT final : " + ((sc.exe query ACE-BOOT | Select-String 'STATE' | Out-String).Trim()))
W("  ACE-Tray final : PIDs " + ((@(Get-Process ACE-Tray -ErrorAction SilentlyContinue) | ForEach-Object { $_.Id }) -join ','))
W("  ThrottleStop   : " + ((sc.exe query ThrottleStop | Select-String 'STATE' | Out-String).Trim()))
W("")
W("==== end $(Get-Date -Format 'HH:mm:ss') ====")
Copy-Item $out 'D:\40hx-unlock\cand2\inpout-test-result.txt' -Force -ErrorAction SilentlyContinue
