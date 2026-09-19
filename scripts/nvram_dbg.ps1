$ErrorActionPreference='Continue'
$log='D:\40hx-unlock\nvram_dbg.txt'
if (Test-Path $log) { Remove-Item $log -Force }
function W($s){ $s | Out-File -FilePath $log -Append -Encoding utf8 }
$sig = @"
using System;
using System.Runtime.InteropServices;
public class FwD {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct TP { public uint Count; public LUID Luid; public uint Attributes; }
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP nw, uint len, IntPtr prev, IntPtr ret);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint GetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="GetFirmwareEnvironmentVariableExW")] public static extern uint GetFirmwareEnvironmentVariableExW(string name, string guid, byte[] buf, uint size, out uint attr);
  public static string Enable() {
    IntPtr tok;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return "open fail " + Marshal.GetLastWin32Error();
    LUID luid;
    if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) return "lookup fail " + Marshal.GetLastWin32Error();
    TP tp = new TP(); tp.Count=1; tp.Luid=luid; tp.Attributes=0x2;
    if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return "adjust fail " + Marshal.GetLastWin32Error();
    return "ok err=" + Marshal.GetLastWin32Error();
  }
}
"@
Add-Type -TypeDefinition $sig
W ("priv: " + [FwD]::Enable())
$g = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}"
foreach ($n in @("PlatformLang","SecureBoot","BootOrder","Boot0000")) {
  $b = New-Object byte[] 8192
  [Runtime.InteropServices.Marshal]::WriteByte([Runtime.InteropServices.Marshal]::AllocHGlobal(1),0,0) | Out-Null
  $x = [FwD]::GetFirmwareEnvironmentVariableW($n, $g, $b, [uint32]$b.Length)
  $e1 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  $attr = 0
  $y = [FwD]::GetFirmwareEnvironmentVariableExW($n, $g, $b, [uint32]$b.Length, [ref]$attr)
  $e2 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  W ("$n : plain=$x err=$e1 ex=$y attr=$attr err=$e2")
  if ($x -gt 0) {
    [IO.File]::WriteAllBytes(("D:\40hx-unlock\nvram_backup\" + $n + ".bin"), $b[0..($x-1)])
    W ("   saved $x bytes")
  }
}
W "dbg done"
