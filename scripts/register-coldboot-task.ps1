$ErrorActionPreference = 'Stop'
$repo = 'D:\40hx-unlock'
$script = "$repo\coldboot-report.ps1"
$name = '40HX ColdBoot Verify'

Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

$trig = New-ScheduledTaskTrigger -AtStartup
$trig.Delay = 'PT3M'

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

Register-ScheduledTask -TaskName $name -Action $action -Trigger $trig -Principal $principal -Settings $settings -Force | Out-Null

$log = 'D:\40hx-unlock\coldboot-task-registered.txt'
$o = @()
$o += "=== registered $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
$t = Get-ScheduledTask -TaskName $name
$o += ("Name    : " + $t.TaskName)
$o += ("State   : " + $t.State + "  Enabled=" + $t.Settings.Enabled)
$o += ("Action  : " + ($t.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }))
$o += ("Trigger : " + ($t.Triggers | ForEach-Object { $_.CimClass.CimClassName + ' delay=' + $_.Delay }))
$o += ("RunAs   : " + $t.Principal.UserId + ' / ' + $t.Principal.RunLevel)
$o += ("Script  : " + $script + "  exists=" + (Test-Path $script))
$o -join "`n" | Set-Content 'D:\40hx-unlock\coldboot-task-registered.txt' -Encoding UTF8
