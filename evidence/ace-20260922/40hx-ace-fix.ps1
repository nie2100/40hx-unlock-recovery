$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\Temp\40hx-ace-fix.txt -Force | Out-Null
function Say($t){ Write-Output $t }

Say '=== [0] enumerate 40HX tasks (elevated) ==='
$tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '40HX|Gen2|Retrain|PostBind|ColdBoot' }
$tasks | Select-Object TaskPath, TaskName, State | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
foreach ($t in $tasks) { $t.Actions | ForEach-Object { Say ("  action[" + $t.TaskPath + $t.TaskName + "]: " + $_.Execute + " " + $_.Arguments) } }

Say '=== [A] ACE-BOOT before ==='
& sc.exe qc ACE-BOOT 2>&1 | Out-String | Write-Output
& sc.exe query ACE-BOOT 2>&1 | Out-String | Write-Output

Say '=== [B] stop ACE-BOOT (temporary) ==='
$out = & sc.exe stop ACE-BOOT 2>&1 | Out-String
Say $out
Say ("stop exitcode=" + $LASTEXITCODE)
Start-Sleep -Seconds 4
& sc.exe query ACE-BOOT 2>&1 | Out-String | Write-Output

Say '=== [C] run the boot task now ==='
$target = $tasks | Where-Object { $_.TaskName -match 'PostBind' } | Select-Object -First 1
if ($target) {
  $full = $target.TaskPath + $target.TaskName
  Say ("running task: " + $full)
  & schtasks.exe /run /tn $full 2>&1 | Out-String | Write-Output
  $deadline = (Get-Date).AddSeconds(200)
  do { Start-Sleep -Seconds 5; $st = (Get-ScheduledTask -TaskPath $target.TaskPath -TaskName $target.TaskName).State } while ($st -eq 'Running' -and (Get-Date) -lt $deadline)
  $info = Get-ScheduledTaskInfo -TaskPath $target.TaskPath -TaskName $target.TaskName
  Say ("task state=" + $st + " lastRun=" + $info.LastRunTime + " lastResult=" + $info.LastTaskResult)
} else {
  Say 'PostBind task not found -> running RunPostBind.cmd directly'
  & cmd.exe /c 'C:\ProgramData\CMP40HXGen2\windows\RunPostBind.cmd' 2>&1 | Out-String | Write-Output
  Say ("RunPostBind exitcode=" + $LASTEXITCODE)
}

Say '=== [D] last.log ==='
Get-Content 'C:\ProgramData\CMP40HXGen2\windows\logs\last.log' -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Say $_ }
Say '=== [E] postbind.log tail ==='
Get-Content 'C:\ProgramData\CMP40HXGen2\windows\logs\postbind.log' -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Say $_ }

Say '=== [F] ACE-BOOT after (left stopped pending decision) ==='
& sc.exe query ACE-BOOT 2>&1 | Out-String | Write-Output
Say '=== [G] ThrottleStop svc state ==='
& sc.exe query ThrottleStop 2>&1 | Out-String | Write-Output
Stop-Transcript | Out-Null
