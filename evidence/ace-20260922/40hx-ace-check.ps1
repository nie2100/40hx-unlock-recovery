Start-Transcript -Path C:\Temp\40hx-ace-check.txt -Force | Out-Null
$ErrorActionPreference = 'Continue'
function Say($t){ Write-Output $t }

Say "=== [1] ThrottleStop service state / start test ==="
& sc.exe query ThrottleStop 2>&1 | Out-String
$o = & sc.exe start ThrottleStop 2>&1 | Out-String
Say $o
Say ("sc start exitcode=" + $LASTEXITCODE)

Say "=== [2] Vulnerable driver blocklist (MS WDAC) ==="
$k='HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'
if (Test-Path $k) { Get-ItemProperty $k | Select-Object * -ExcludeProperty PS* | Format-List | Out-String } else { Say "no CI\Config" }

Say "=== [3] mount ESP and read 40hx_log.txt ==="
$mv = & mountvol 2>&1 | Out-String
if ($mv -notmatch 'Y:') { & mountvol Y: /s 2>&1 | Out-String | Write-Output }
Start-Sleep -Seconds 1
$f='Y:\40hx_log.txt'
if (Test-Path $f) {
  Say ("ESP log lastwrite=" + (Get-Item $f).LastWriteTime)
  Get-Content $f -Tail 40 | ForEach-Object { Say $_ }
} else { Say "40hx_log.txt NOT FOUND" }
Say "--- ESP 40HX dir ---"
Get-ChildItem 'Y:\EFI\40HX' -Recurse -ErrorAction SilentlyContinue | Select FullName,Length,LastWriteTime | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
Say "--- ESP driver fallback sources ---"
Get-ChildItem 'Y:\EFI\40HX\drv' -ErrorAction SilentlyContinue | Select Name,Length,LastWriteTime | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

Say "=== [4] EFI hashes (onlyefi check) ==="
foreach ($p in 'Y:\EFI\40HX\40HXUNLK.EFI','Y:\EFI\Boot\bootx64.efi') {
  if (Test-Path $p) { $h=(Get-FileHash $p -Algorithm SHA256).Hash; Say "$p  $h  " } else { Say "$p MISSING" }
}
& mountvol Y: /d 2>&1 | Out-String | Write-Output

Say "=== [5] scheduled tasks 40HX ==="
Get-ScheduledTask | Where-Object { $_.TaskName -match '40HX|Gen2|Retrain|ColdBoot' } | Select TaskName,State | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

Say "=== [6] ACE / game presence ==="
Get-ChildItem 'C:\Program Files\AntiCheatExpert\InGame' -ErrorAction SilentlyContinue | Select Name,Length,LastWriteTime | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
Get-Process | Where-Object { $_.ProcessName -match 'ACE|SGuard|Tencent|Game' } | Select ProcessName,Id,Path | Format-Table -AutoSize | Out-String -Width 250 | Write-Output
