$ErrorActionPreference='Continue'
# 设置/恢复 NVRAM 引导顺序
# 用法: powershell -File nvram_bootorder.ps1          -> 写入 [0003,0000,0002] (解锁EFI优先)
#       powershell -File nvram_bootorder.ps1 -rollback -> 删除 Boot0003/BootNext, 恢复原顺序 [0000,0002]
param([switch]$rollback)
$log='D:\40hx-unlock\nvram_bootorder.log'
function W($s){ ($s | Out-String) | Out-File -FilePath $log -Append -Encoding utf8 }
W ("=== " + (Get-Date) + " rollback=" + $rollback)

$sig = @"
using System;
using System.Runtime.InteropServices;
public class FwBo {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct TP { public uint Count; public LUID Luid; public uint Attributes; }
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP nw, uint len, IntPtr prev, IntPtr ret);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint GetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetFirmwareEnvironmentVariableW(string name, string guid, byte[] buf, uint size);
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
W ("priv: " + [FwBo]::Enable())
$g = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}"

function RV($n) { $b = New-Object byte[] 8192; $x = [FwBo]::GetFirmwareEnvironmentVariableW($n,$g,$b,[uint32]$b.Length); if ($x -gt 0) { return $b[0..([int]$x-1)] } return $null }
function SV($n, [byte[]]$d) { $r = [FwBo]::SetFirmwareEnvironmentVariableW($n,$g,$d,[uint32]$d.Length); W ("  write $n -> $r err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()); return $r }
function DEL($n) { $e = New-Object byte[] 0; $r = [FwBo]::SetFirmwareEnvironmentVariableW($n,$g,$e,0); W ("  delete $n -> $r err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()); return $r }

$bk='D:\40hx-unlock\nvram_backup'
if ($rollback) {
  DEL "BootNext" | Out-Null
  DEL "Boot0003" | Out-Null
  $orig = [IO.File]::ReadAllBytes((Join-Path $bk 'BootOrder.bin'))   # 安装前? 这是安装后读到的 0000 0000 0002 0000
  # 恢复成干净的两项顺序
  [byte[]]$clean = @(0,0, 2,0)
  SV "BootOrder" $clean | Out-Null
  W "已回滚: 删除 Boot0003/BootNext, BootOrder=[0000,0002]"
} else {
  if ((RV "Boot0003") -eq $null) { W "!! Boot0003 不存在 — 请先确认解锁引导项已写入" }
  [byte[]]$order = @(3,0, 0,0, 2,0)
  SV "BootOrder" $order | Out-Null
  # 清掉一次性 BootNext (若还在)
  DEL "BootNext" | Out-Null
  W "已写入 BootOrder=[0003(40HX Unlock),0000(Windows),0002]"
}
$bo = RV "BootOrder"
if ($bo) { $ns=@(); for($i=0;$i -lt $bo.Length;$i+=2){ $ns += "{0:X4}" -f [BitConverter]::ToUInt16($bo,$i) }; W ("BootOrder 现在 = " + ($ns -join " ")) }
W "done"
