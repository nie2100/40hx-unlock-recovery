$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\Temp\40hx-autotest.txt -Force | Out-Null
function Say($t){ Write-Output $t }
function Log($p,$n){ Say ("--- " + $p + " ---"); Get-Content $p -Tail $n -ErrorAction SilentlyContinue | ForEach-Object { Say $_ } }

Say '=== before: ACE-Tray pid / ACE-BOOT / log mtime ==='
Say ("ACE-Tray pid: " + ((Get-Process ACE-Tray -ErrorAction SilentlyContinue | Select-Object -First 1).Id))
& sc.exe query ACE-BOOT 2>&1 | Select-String 'STATE' | ForEach-Object { Say $_.ToString() }
$f='C:\ProgramData\CMP40HXGen2\windows\logs\postbind.log'
Say ("postbind.log mtime: " + (Get-Item $f).LastWriteTime)

Say '=== run task ==='
& schtasks.exe /run /tn "CMP40HX Gen2 PostBind" 2>&1 | Out-String | Write-Output
$deadline=(Get-Date).AddSeconds(240)
do { Start-Sleep -Seconds 5; $st=(Get-ScheduledTask -TaskName 'CMP40HX Gen2 PostBind').State } while ($st -eq 'Running' -and (Get-Date) -lt $deadline)
$info = Get-ScheduledTaskInfo -TaskName 'CMP40HX Gen2 PostBind'
Say ("state=" + $st + " lastRun=" + $info.LastRunTime + " lastResult=" + $info.LastTaskResult)
Say ("postbind.log mtime now: " + (Get-Item $f).LastWriteTime)
Log $f 22
Log 'C:\ProgramData\CMP40HXGen2\windows\logs\last.log' 12

Say '=== after: ACE-Tray pid / ACE-BOOT / driver ==='
Say ("ACE-Tray pid: " + ((Get-Process ACE-Tray -ErrorAction SilentlyContinue | Select-Object -First 1).Id))
& sc.exe query ACE-BOOT 2>&1 | Select-String 'STATE' | ForEach-Object { Say $_.ToString() }
& sc.exe qc ACE-BOOT 2>&1 | Select-String 'START_TYPE' | ForEach-Object { Say $_.ToString() }
& sc.exe query ThrottleStop 2>&1 | Select-String 'STATE' | ForEach-Object { Say $_.ToString() }
Stop-Transcript | Out-Null
