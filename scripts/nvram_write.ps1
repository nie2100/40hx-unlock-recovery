$ErrorActionPreference='Continue'
$log='D:\40hx-unlock\nvram_write.txt'
if (Test-Path $log) { Remove-Item $log -Force }
function W($s){ $s | Out-File -FilePath $log -Append -Encoding utf8 }
$sig = @"
using System;
using System.Runtime.InteropServices;
public class FwW {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct TP { public uint Count; public LUID Luid; public uint Attributes; }
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP nw, uint len, IntPtr prev, IntPtr ret);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint GetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetFirmwareEnvironmentVariableExW(string name, string guid, byte[] buf, uint size, uint attrs);
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
W ("priv: " + [FwW]::Enable())
$g = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}"
function RV($n) { $b = New-Object byte[] 8192; $x=[FwW]::GetFirmwareEnvironmentVariableW($n,$g,$b,[uint32]$b.Length); if($x -gt 0){ return $b[0..($x-1)] } ; return $null }

[byte[]]$data = [IO.File]::ReadAllBytes('D:\40hx-unlock\nvram_backup\Boot0003.bin')
W ("writing Boot0003, " + $data.Length + " bytes")
$ok = [FwW]::SetFirmwareEnvironmentVariableW("Boot0003", $g, $data, [uint32]$data.Length)
W ("set rc=" + $ok + " err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
Start-Sleep -Milliseconds 400
$rb = RV "Boot0003"
if ($rb -eq $null) { W "READBACK FAILED" }
else {
  W ("readback " + $rb.Length + " bytes, identical=" + ([Convert]::ToBase64String($rb) -eq [Convert]::ToBase64String($data)))
  W ("readback hex: " + [BitConverter]::ToString($rb))
}

W "--- set BootNext = 0003 ---"
[byte[]]$bn = @(3,0)
$ok2 = [FwW]::SetFirmwareEnvironmentVariableW("BootNext", $g, $bn, 2)
W ("set BootNext rc=" + $ok2 + " err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
$bnr = RV "BootNext"
if ($bnr) { W ("BootNext readback = " + [BitConverter]::ToString($bnr)) } else { W "BootNext readback FAILED" }

W "--- BootOrder now ---"
$bo = RV "BootOrder"
if ($bo) { $ns=@(); for($i=0;$i -lt $bo.Length;$i+=2){ $ns += "{0:X4}" -f [BitConverter]::ToUInt16($bo,$i) }; W ($ns -join " ") }
W "write done"
