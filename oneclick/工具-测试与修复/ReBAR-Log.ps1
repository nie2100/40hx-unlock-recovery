# ReBAR-Log.ps1 -- READ ONLY helper (no NVRAM writes, no ESP writes).
# Purpose: show WHY the ReBAR firmware rolled back on this boot
#          (the [rebar] / placer / aperture lines in ESP \40hx_log.txt).
# Run via ReBAR-Log.cmd (self-elevates) or:
#   powershell -ExecutionPolicy Bypass -File ReBAR-Log.ps1
$ErrorActionPreference = 'Continue'

$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host '[!] Need Administrator. Run ReBAR-Log.cmd (it asks for elevation).' -ForegroundColor Yellow; exit 2 }

$letters = @('Y','X','W','V','U','T','S','R','Q','P','O','N')
$esp = $null
$mounted = $null

foreach ($l in $letters) {
  if ((Test-Path ($l + ':\EFI\Boot')) -or (Test-Path ($l + ':\EFI\Microsoft'))) { $esp = $l + ':'; break }
}
if (-not $esp) {
  foreach ($l in $letters) {
    if (Test-Path ($l + ':\')) { continue }
    mountvol ($l + ':') /S 2>&1 | Out-Null
    if ((Test-Path ($l + ':\EFI\Boot')) -or (Test-Path ($l + ':\EFI\Microsoft'))) { $esp = $l + ':'; $mounted = $l + ':'; break }
    mountvol ($l + ':') /D 2>&1 | Out-Null
  }
}
if (-not $esp) { Write-Host '[!] Could not mount the EFI System Partition (UEFI + GPT required).' -ForegroundColor Red; exit 4 }

Write-Host ('[*] ESP mounted at ' + $esp) -ForegroundColor Cyan
Write-Host ''
Write-Host '==== 1. EFI files on ESP ====' -ForegroundColor Cyan
foreach ($f in @('EFI\40HX\40HXUNLK.EFI','EFI\40HX\40HXUNLK-REBAR.EFI','EFI\Boot\bootx64.efi')) {
  $p = Join-Path ($esp + '\') $f
  if (Test-Path $p) {
    $i = Get-Item $p
    $h = (Get-FileHash $p -Algorithm SHA256).Hash.Substring(0,16)
    Write-Host ('  {0,-30} {1,8} B  {2}  sha256={3}...' -f $f, $i.Length, $i.LastWriteTime, $h)
  } else { Write-Host ('  {0,-30} MISSING' -f $f) -ForegroundColor Yellow }
}

Write-Host ''
Write-Host '==== 2. Boot entries (bcdedit /enum firmware) ====' -ForegroundColor Cyan
bcdedit /enum firmware 2>&1 | Out-String -Width 200

$log = Join-Path ($esp + '\') '40hx_log.txt'
Write-Host ''
Write-Host '==== 3. 40hx_log.txt ====' -ForegroundColor Cyan
if (Test-Path $log) {
  $i = Get-Item $log
  Write-Host ('  last write: ' + $i.LastWriteTime + '   size: ' + $i.Length + ' B')
  Write-Host '  ---- lines about rebar / placer / aperture ----'
  $hit = @(Get-Content -LiteralPath $log | Select-String -Pattern 'rebar|placer|aperture|BAR1|revert|skipped|abort|verify|WPR2|IMEM')
  if ($hit.Count -gt 0) { $hit | ForEach-Object { '  ' + $_.Line } }
  else { Write-Host '  (no [rebar] line at all -> this boot did NOT run the ReBAR firmware)' -ForegroundColor Yellow }
  Write-Host '  ---- last 30 lines ----'
  Get-Content -LiteralPath $log -Tail 30 | ForEach-Object { '  ' + $_ }
} else {
  Write-Host '  40hx_log.txt not found -> the unlock firmware did not run this boot.' -ForegroundColor Yellow
}

if ($mounted) { mountvol $mounted /D 2>&1 | Out-Null; Write-Host ''; Write-Host ('[*] ESP unmounted (' + $mounted + ')') -ForegroundColor Cyan }
Write-Host ''
Write-Host 'Read-only tool: nothing was written to ESP or NVRAM.' -ForegroundColor Green
exit 0
