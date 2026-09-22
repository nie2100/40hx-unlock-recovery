$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\Temp\40hx-ace-stop2.txt -Force | Out-Null
function Say($t){ Write-Output $t }

Say '=== [1] current ACE-BOOT state (was STOP_PENDING) ==='
& sc.exe query ACE-BOOT 2>&1 | Out-String | Write-Output

Say '=== [2] kill ACE-Tray.exe (same as tray right-click -> Exit) ==='
Get-Process ACE-Tray -ErrorAction SilentlyContinue | ForEach-Object { Say ("killing pid " + $_.Id) ; & taskkill.exe /PID $_.Id /F 2>&1 | Out-String | Write-Output }
Start-Sleep -Seconds 5
Get-Process | Where-Object { $_.ProcessName -match 'ACE|SGuard' } | Select-Object ProcessName,Id | Format-Table -AutoSize | Out-String | Write-Output

Say '=== [3] re-issue stop ACE-BOOT ==='
& sc.exe stop ACE-BOOT 2>&1 | Out-String | Write-Output
foreach ($i in 1..6) {
  Start-Sleep -Seconds 5
  $q = & sc.exe query ACE-BOOT 2>&1 | Out-String
  $state = ([regex]::Match($q, 'STATE\s+:\s+\d+\s+(\S+)')).Groups[1].Value
  Say ("t+" + ($i*5) + "s STATE=" + $state)
}

Say '=== [4] try loading ThrottleStop driver ==='
& sc.exe start ThrottleStop 2>&1 | Out-String | Write-Output
Say ("start exitcode=" + $LASTEXITCODE)
& sc.exe query ThrottleStop 2>&1 | Out-String | Write-Output
Stop-Transcript | Out-Null
