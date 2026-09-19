# coldboot-report.ps1 -- one-shot report written ~3 min after the next cold boot.
# Registered as SYSTEM boot task "40HX ColdBoot Verify"; deletes itself when done.
$ErrorActionPreference = 'Continue'
$out = 'D:\40hx-unlock\coldboot-report.txt'
$lines = New-Object System.Collections.ArrayList
function W($s) { [void]$lines.Add([string]$s) }

Start-Sleep -Seconds 30
W "=== 40HX cold-boot verify report  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
W ("LastBootUpTime : " + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime)

# ---- ESP: unlock firmware log + EFI hashes ----
$esp = $null
foreach ($l in @('Y','X','W','V','U','T','S','R','Q')) {
  if (-not (Test-Path "${l}:\")) {
    mountvol "${l}:" /S | Out-Null
    if (Test-Path "${l}:\") { $esp = "${l}:"; break }
  }
}
$computeOk = $false
W ""
W "=== ESP / EFI firmware ==="
if ($esp) {
  W ("ESP = " + $esp)
  foreach ($f in @("$esp\EFI\40HX\40HXUNLK.EFI", "$esp\EFI\Boot\bootx64.efi")) {
    if (Test-Path $f) {
      $sh = (Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
      $tag = if ($sh -eq '1e9ca43fab3d5ce851e8fcd09dc9be63282fbf3ce3828c3dbcdcbb21cf7ce1c7') { 'OnlyEFI v0.1.1 OK' } else { 'UNEXPECTED (not OnlyEFI)' }
      W ("  {0}  sha256={1}  [{2}]  mtime={3}" -f $f, $sh.Substring(0,16), $tag, (Get-Item $f).LastWriteTime)
    } else { W "  MISSING $f" }
  }
  $lg = "$esp\40hx_log.txt"
  if (Test-Path $lg) {
    W ("  [40hx_log.txt] mtime=" + (Get-Item $lg).LastWriteTime)
    $txt = Get-Content $lg -ErrorAction SilentlyContinue
    $hits = $txt | Select-String -Pattern 'UNLOCKED|TLS|NO-RETRAIN|efi-b' -SimpleMatch:$false
    if ($hits) { $hits | ForEach-Object { W ("    " + $_.Line) } }
    if ($txt -match 'UNLOCKED \(SS0=0x88888888 SS1=0x8\)') { $computeOk = $true }
    W "    --- tail 8 ---"
    $txt | Select-Object -Last 8 | ForEach-Object { W ("    " + $_) }
  } else { W "  40hx_log.txt MISSING (firmware did not run this boot)" }
  mountvol $esp /D | Out-Null
} else { W "  cannot mount ESP" }

# ---- OnlyEFI windows-side post-bind ----
W ""
W "=== OnlyEFI post-bind ==="
$pl = 'C:\ProgramData\CMP40HXGen2\windows\logs\postbind.log'
$ll = 'C:\ProgramData\CMP40HXGen2\windows\logs\last.log'
$gen2Ok = $false
if (Test-Path $pl) {
  $pb = Get-Content $pl
  W "  [postbind.log tail 12]"
  $pb | Select-Object -Last 12 | ForEach-Object { W ("    " + $_) }
  $lastExit = ($pb | Select-String -Pattern 'PostBind EXIT=(\d+)' | Select-Object -Last 1)
  if ($pb -match 'PostBind EXIT=0') { $gen2Ok = $true }
} else { W "  postbind.log missing" }
if (Test-Path $ll) {
  W "  [last.log]"
  Get-Content $ll | Where-Object { $_ -match 'GUARD|PASS|ERROR|EXIT|LINK_CONFIG|PRIV_MISC|final|TLS|LNKCAP|SS0' } | ForEach-Object { W ("    " + $_) }
  $l2 = Get-Content $ll
  if (-not ($l2 -match 'PASS: physical Gen2 x16')) { $gen2Ok = $false }
} else { W "  last.log missing" }

# ---- vendor-side status file ----
$gs = 'C:\ProgramData\40HXUnlock\gen2_status.txt'
if (Test-Path $gs) { W ""; W "=== vendor gen2_status.txt ==="; Get-Content $gs | ForEach-Object { W ("  " + $_) } }

# ---- device / driver state ----
W ""
W "=== GPU device state ==="
Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VEN_10DE&DEV_1F0B' } | ForEach-Object {
  W ("  {0}  Status={1}  Problem=0x{2:X}" -f $_.InstanceId, $_.Status, [int]$_.Problem)
}
W "  nvidia-smi:"
(& 'C:\Windows\System32\nvidia-smi.exe' --query-gpu=name,driver_version,pcie.link.gen.current,pcie.link.gen.max,pcie.link.gen.gpucurrent,pcie.link.gen.gpumax --format=csv 2>&1) | ForEach-Object { W ("    " + $_) }

# ---- task results ----
W ""
W "=== tasks ==="
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { ($_.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -join ' ' -match '40HX|CMP40HX' } | ForEach-Object {
  $i = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue
  W ("  [{0}] {1}  last={2} rc=0x{3:X}" -f $_.State, $_.TaskName, $i.LastRunTime, $i.LastTaskResult)
}

# ---- verdict ----
W ""
W "=================== 结论 ==================="
W ("  算力解锁(EFI)  : " + $(if ($computeOk) { 'PASS - SS0=0x88888888 SS1=0x8' } else { 'FAIL - 见上面 EFI 日志' }))
W ("  PCIe Gen2      : " + $(if ($gen2Ok) { 'PASS - post-bind exit 0 / physical Gen2 x16' } else { 'FAIL - 见 postbind.log 与 last.log' }))
W "==========================================="
$lines -join "`n" | Set-Content -Path $out -Encoding UTF8

# remove the one-shot task
Unregister-ScheduledTask -TaskName '40HX ColdBoot Verify' -Confirm:$false -ErrorAction SilentlyContinue
