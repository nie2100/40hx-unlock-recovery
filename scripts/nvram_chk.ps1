$ErrorActionPreference='Continue'
$log='D:\40hx-unlock\nvram_chk.txt'
if (Test-Path $log) { Remove-Item $log -Force }
function W($s){ $s | Out-File -FilePath $log -Append -Encoding utf8 }
$sig = @"
using System;
using System.Runtime.InteropServices;
public class FwC {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct TP { public uint Count; public LUID Luid; public uint Attributes; }
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP nw, uint len, IntPtr prev, IntPtr ret);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint GetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  public static string Enable() {
    IntPtr tok;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return "open fail " + Marshal.GetLastWin32Error();
    LUID luid;
    if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) return "lookup fail";
    TP tp = new TP(); tp.Count=1; tp.Luid=luid; tp.Attributes=0x2;
    if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return "adjust fail " + Marshal.GetLastWin32Error();
    return "ok";
  }
}
"@
Add-Type -TypeDefinition $sig
W ("priv: " + [FwC]::Enable())
$g = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}"
$dir='D:\40hx-unlock\nvram_backup'
foreach ($n in @("BootOrder","Boot0000","Boot0002","Boot0003","BootNext","SecureBoot")) {
  $b = New-Object byte[] 8192
  $x = [FwC]::GetFirmwareEnvironmentVariableW($n, $g, $b, [uint32]$b.Length)
  $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  W ("$n : len=$x err=$e")
  if ($x -gt 0) {
    $bytes = $b[0..($x-1)]
    W ("   hex: " + [BitConverter]::ToString($bytes))
    if ($n -like 'Boot*0*') { [IO.File]::WriteAllBytes((Join-Path $dir ($n + '.now.bin')), $bytes) }
  }
}
W "=== bcdedit /enum firmware (first 60 lines) ==="
((bcdedit /enum firmware 2>&1 | Select-Object -First 60) -join "`n") | Out-File $log -Append -Encoding utf8
W "chk done"
