$ErrorActionPreference='Continue'
$dir='D:\40hx-unlock\nvram_backup'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$log='D:\40hx-unlock\nvram_read.txt'
if (Test-Path $log) { Remove-Item $log -Force }
function W($s){ $s | Out-File -FilePath $log -Append -Encoding utf8 }

$sig = @"
using System;
using System.Runtime.InteropServices;
public class FwR {
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
W ("priv: " + [FwR]::Enable())
$g = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}"
function RV($n) { $b = New-Object byte[] 8192; $x=[FwR]::GetFirmwareEnvironmentVariableW($n,$g,$b,$b.Length); if($x -gt 0){ return ,$b[0..($x-1)] } return $null }

$bo = RV "BootOrder"
if ($bo) { [IO.File]::WriteAllBytes((Join-Path $dir 'BootOrder.bin'), $bo); W ("BootOrder saved " + $bo.Length + " bytes") }
foreach ($n in @('Boot0000','Boot0002','Boot0003','BootNext')) {
  $d = RV $n
  if ($d) { [IO.File]::WriteAllBytes((Join-Path $dir ($n + '.bin')), $d); W ("$n saved " + $d.Length + " bytes") }
  else { W "$n not present" }
}
W "done"
