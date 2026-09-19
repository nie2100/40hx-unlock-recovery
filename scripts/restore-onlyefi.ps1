# restore-onlyefi.ps1 -- put the OnlyEFI v0.1.1 unlock EFI back on the ESP
# and return the machine to the known-good "compute + Gen2" configuration.
$ErrorActionPreference = 'Continue'
$out = 'D:\40hx-unlock\restore-onlyefi.txt'
$lines = New-Object System.Collections.ArrayList
function W($s) { [void]$lines.Add([string]$s) }

$only = 'D:\40hx-unlock\onlyefi-v0.1.1\EFI\40HXUNLK.EFI'
$bk   = 'D:\40hx-unlock\efi_backup_v3.2.0'
$want = '1e9ca43fab3d5ce851e8fcd09dc9be63282fbf3ce3828c3dbcdcbb21cf7ce1c7'

W "=== restore-onlyefi $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
if (-not (Test-Path $only)) { W "FATAL: $only missing"; $lines -join "`n" | Set-Content $out -Encoding UTF8; exit 1 }
$h = (Get-FileHash $only -Algorithm SHA256).Hash.ToLower()
W ("source EFI sha256 = " + $h)
W ("expected          = " + $want)
if ($h -ne $want) { W "FATAL: source EFI hash mismatch"; $lines -join "`n" | Set-Content $out -Encoding UTF8; exit 1 }

# 1) mount ESP
$esp = $null
foreach ($l in @('Y','X','W','V','U','T','S','R','Q')) {
  if (-not (Test-Path "${l}:\")) {
    mountvol "${l}:" /S | Out-Null
    if (Test-Path "${l}:\") { $esp = "${l}:"; break }
  }
}
if (-not $esp) { W "FATAL: cannot mount ESP"; $lines -join "`n" | Set-Content $out -Encoding UTF8; exit 1 }
W ("ESP mounted at " + $esp)

# 2) backup current (v3.2.0) EFI files
if (-not (Test-Path $bk)) { New-Item -ItemType Directory -Path $bk -Force | Out-Null }
foreach ($pair in @(@("$esp\EFI\40HX\40HXUNLK.EFI", "$bk\_EFI_40HX_40HXUNLK.EFI.v320"), @("$esp\EFI\Boot\bootx64.efi", "$bk\_EFI_Boot_bootx64.efi.v320"))) {
  if (Test-Path $pair[0]) {
    Copy-Item $pair[0] $pair[1] -Force
    W ("backup: {0} -> {1} (MD5={2})" -f $pair[0], $pair[1], (Get-FileHash $pair[0] -Algorithm MD5).Hash)
  }
}

# 3) write OnlyEFI EFI to both paths
foreach ($dst in @("$esp\EFI\40HX\40HXUNLK.EFI", "$esp\EFI\Boot\bootx64.efi")) {
  Copy-Item $only $dst -Force
  $hh = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
  W ("write: {0} sha256={1} {2}" -f $dst, $hh, $(if ($hh -eq $want) { 'OK' } else { 'MISMATCH' }))
}

# 4) driver fallback sources on ESP
foreach ($f in @("$esp\EFI\40HX\drv\ThrottleStop.sys", "$esp\EFI\40HX\drv\WinRing0x64.sys")) {
  if (Test-Path $f) { W ("drv src OK: {0} {1}" -f $f, (Get-Item $f).Length) } else { W ("drv src MISSING: " + $f) }
}
mountvol $esp /D | Out-Null
W ("ESP unmounted " + $esp)

# 5) vendor Gen2 tasks off (they cannot retrain on this board without a device reset)
foreach ($t in @('40HX PCIe Gen2 Bring-up', '40HX-Gen2-Retrain')) {
  try { Disable-ScheduledTask -TaskName $t -ErrorAction Stop | Out-Null; W ("task disabled: " + $t) }
  catch { W ("task disable failed ($t): " + $_.Exception.Message) }
}

# 6) vendor login autostart off
try {
  $run = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop
  if ($run.PSObject.Properties.Name -contains '40HXGen2') {
    $v = $run.'40HXGen2'
    Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name '40HXGen2_v32_bak' -Value $v -ErrorAction Stop
    Remove-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name '40HXGen2' -ErrorAction Stop
    W ("HKCU Run: 40HXGen2 -> parked as 40HXGen2_v32_bak (" + $v + ")")
  } else { W "HKCU Run: 40HXGen2 not present" }
} catch { W ("HKCU Run edit failed: " + $_.Exception.Message) }

# 7) ensure the OnlyEFI post-bind task is enabled
try { Enable-ScheduledTask -TaskName 'CMP40HX Gen2 PostBind' -ErrorAction Stop | Out-Null; W "task enabled: CMP40HX Gen2 PostBind" }
catch { W ("task enable failed: " + $_.Exception.Message) }

# 8) policy keys: no auto Stage2, no PnP fallback (must never reset the GPU)
foreach ($kv in @(@('Gen2AutoHard', 0), @('Gen2PnpFallback', 0))) {
  reg add "HKLM\SOFTWARE\40HXUnlock" /v $kv[0] /t REG_DWORD /d $kv[1] /f | Out-Null
  W ("policy: {0} = {1}" -f $kv[0], $kv[1])
}

# 9) final task snapshot
W ""
W "=== tasks after change ==="
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { ($_.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -join ' ' -match '40HX|CMP40HX' } | ForEach-Object {
  W ("  [{0}] enabled={1} {2}" -f $_.State, $_.Settings.Enabled, $_.TaskName)
}
W ""
W "=== done $(Get-Date -Format 'HH:mm:ss') ==="
$lines -join "`n" | Set-Content -Path $out -Encoding UTF8
