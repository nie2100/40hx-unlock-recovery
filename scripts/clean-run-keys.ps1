$log = 'D:\40hx-unlock\parked-run-keys.txt'
$o = New-Object System.Collections.ArrayList
function W($s) { [void]$o.Add([string]$s) }
W "=== HKCU Run cleanup $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
$key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$run = Get-ItemProperty $key -ErrorAction SilentlyContinue
foreach ($n in @('40HXGen2', '40HXGen2_bak', '40HXGen2_v32_bak')) {
  $v = (Get-ItemProperty -Path $key -Name $n -ErrorAction SilentlyContinue).$n
  if ($v) {
    W ("found  {0} = {1}" -f $n, $v)
    Remove-ItemProperty -Path $key -Name $n -ErrorAction Stop
    W ("  -> removed (a Run value still executes no matter its name, so parking is not 'off')")
  } else { W ("absent {0}" -f $n) }
}
W ""
W "=== HKCU Run after cleanup ==="
$run2 = Get-ItemProperty $key -ErrorAction SilentlyContinue
$run2.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { W ("  {0} = {1}" -f $_.Name, $_.Value) }
$o -join "`n" | Set-Content $log -Encoding UTF8
