# ghost-clean.ps1 -- remove the non-present (ghost) PnP instance of the CMP 40HX.
# Backs up the registry Enum key first, then removes with pnputil; falls back to Remove-PnpDevice.
$ErrorActionPreference = 'Continue'
$out = 'D:\40hx-unlock\ghost-clean.txt'
$lines = New-Object System.Collections.ArrayList
function W($s) { [void]$lines.Add([string]$s) }

$target = 'PCI\VEN_10DE&DEV_1F0B&SUBSYS_88041043&REV_A1\4&31FD5A8&0&00DC'
$keep   = 'PCI\VEN_10DE&DEV_1F0B&SUBSYS_88041043&REV_A1\4&212EBC66&0&0008'
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$target"

W "=== CMP40HX ghost instance cleanup $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
W ("identity: " + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
W ("os: " + (Get-CimInstance Win32_OperatingSystem).Caption + " build " + (Get-CimInstance Win32_OperatingSystem).BuildNumber)

function Show-Instances($tag) {
  W ""
  W "--- $tag : every VEN_10DE&DEV_1F0B instance ---"
  $found = 0
  Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VEN_10DE&DEV_1F0B' } | ForEach-Object {
    $found++
    W ("  present={0,-6} status={1,-9} problem=0x{2:X}  {3}" -f $_.Present, $_.Status, [int]$_.Problem, $_.InstanceId)
  }
  if ($found -eq 0) { W "  (none reported by Get-PnpDevice)" }
}

Show-Instances 'BEFORE'
W ""
W ("registry Enum key: " + $regPath)
W ("  exists = " + (Test-Path $regPath))
if (Test-Path $regPath) {
  $p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Enum\' -ErrorAction SilentlyContinue
  $known = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
  W ("  Service/ClassGUID/DeviceDesc keys present: " + (($known.PSObject.Properties.Name) -join ', '))
}

# ---- backup ----
W ""
W "--- backup ---"
$bakReg = 'D:\40hx-unlock\ghost-enum-backup.reg'
$rc = 0
& reg.exe export "HKLM\SYSTEM\CurrentControlSet\Enum\$target" $bakReg /y *> $null
$rc = $LASTEXITCODE
W ("  reg export exit=" + $rc + "  file=" + $bakReg + "  exists=" + (Test-Path $bakReg) + "  size=" + $(if (Test-Path $bakReg) { (Get-Item $bakReg).Length } else { 0 }))

# ---- remove ----
W ""
W "--- remove (pnputil) ---"
$o = & pnputil.exe /remove-device "$target" 2>&1
$o | ForEach-Object { W ("  " + $_) }
W ("  pnputil exit=" + $LASTEXITCODE)

if (Test-Path $regPath) {
  W ""
  W "--- pnputil did not clear it, trying Remove-PnpDevice ---"
  try {
    Remove-PnpDevice -InstanceId $target -Confirm:$false -ErrorAction Stop
    W "  Remove-PnpDevice: ok"
  } catch {
    W ("  Remove-PnpDevice failed: " + $_.Exception.Message)
  }
}

# ---- after ----
Show-Instances 'AFTER'
W ""
W ("registry Enum key exists now = " + (Test-Path $regPath))

W ""
W "--- sanity: live card unaffected ---"
Get-PnpDevice -InstanceId $keep -ErrorAction SilentlyContinue | ForEach-Object {
  W ("  present={0} status={1} problem=0x{2:X}" -f $_.Present, $_.Status, [int]$_.Problem)
}
W "  nvidia-smi:"
(& 'C:\Windows\System32\nvidia-smi.exe' --query-gpu=name,pcie.link.gen.current,pcie.link.gen.max --format=csv 2>&1) | ForEach-Object { W ("    " + $_) }

$lines -join "`n" | Set-Content -Path $out -Encoding UTF8
