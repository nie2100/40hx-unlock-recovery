# fw-inspect.ps1 -- list UEFI boot variables (BootOrder / Boot#### descriptions / BootNext)
$ErrorActionPreference = 'Continue'
$out = 'D:\40hx-unlock\fw-inspect.txt'
$lines = New-Object System.Collections.ArrayList
function W($s) { [void]$lines.Add([string]$s) }
$sig = @"
using System;
using System.Runtime.InteropServices;
public class FwI {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct TP { public uint Count; public LUID Luid; public uint Attributes; }
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP nw, uint len, IntPtr prev, IntPtr ret);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint GetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  public static string Enable() {
    IntPtr tok;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return "open fail";
    LUID luid;
    if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) return "lookup fail";
    TP tp = new TP(); tp.Count=1; tp.Luid=luid; tp.Attributes=0x2;
    if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return "adjust fail";
    return "ok";
  }
}
"@
Add-Type -TypeDefinition $sig
$g = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}"
W ("=== fw-inspect " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " priv=" + [FwI]::Enable() + " ===")
function RV($n) { $b = New-Object byte[] 8192; $x = [FwI]::GetFirmwareEnvironmentVariableW($n,$g,$b,[uint32]$b.Length); $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error(); $script:lastErr = $e; if ($x -gt 0) { return $b[0..([int]$x-1)] } return $null }

W ""
W "--- SecureBoot / BootNext ---"
foreach ($n in @('SecureBoot','BootNext')) {
  $v = RV $n
  if ($v) { W ("  {0} = {1}  ({2} bytes)" -f $n, [BitConverter]::ToString($v), $v.Length) } else { W ("  {0} = (absent)" -f $n) }
}

$bo = RV 'BootOrder'
W ""
W "--- BootOrder ---"
if ($bo) {
  $ns = @(); for ($i=0; $i -lt $bo.Length; $i+=2) { $ns += "{0:X4}" -f [BitConverter]::ToUInt16($bo,$i) }
  W ("  " + ($ns -join " "))
} else { W "  (unreadable)" }

W ""
W "--- Boot#### entries ---"
foreach ($n in @('Boot0000','Boot0001','Boot0002','Boot0003','Boot0004','Boot0005','Boot0006')) {
  $v = RV $n
  if (-not $v) { W ("  {0}: absent" -f $n); continue }
  $fpLen = [BitConverter]::ToUInt16($v,4)
  # description: UTF-16LE, null terminated, starts at offset 6
  $desc = ''
  $i = 6
  while ($i + 1 -lt $v.Length) {
    $c = [BitConverter]::ToUInt16($v,$i)
    if ($c -eq 0) { break }
    $desc += [char]$c
    $i += 2
  }
  $devStart = $i + 2
  $devLen = $v.Length - $devStart
  $dev = ''
  if ($devLen -gt 0) { $dev = ($v[$devStart..($v.Length-1)] | ForEach-Object { $_.ToString('x2') }) -join '' }
  W ("  {0}: len={1} attr=0x{2:X8} fpLen={3} desc='{4}'" -f $n, $v.Length, [BitConverter]::ToUInt32($v,0), $fpLen, $desc)
  W ("        devpath_hex=" + $dev)
}
$lines -join "`n" | Set-Content -Path $out -Encoding UTF8
