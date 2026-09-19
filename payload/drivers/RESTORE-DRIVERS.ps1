# RESTORE-DRIVERS.ps1 -- restore the two BYOVD drivers from the base64 backups in this folder.
# 为什么要 base64：ThrottleStop.sys 会被杀软从"非信任路径"秒删（实测复制到临时目录后 10 秒内消失），
# 所以仓库里以文本形式备份；本脚本负责还原成二进制并放到位。
# 用法（管理员 PowerShell）：  powershell -ExecutionPolicy Bypass -File RESTORE-DRIVERS.ps1
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$targets = @("$env:SystemRoot\System32\drivers", "$env:ProgramData\CMP40HXGen2\drivers")
foreach ($t in $targets) { New-Item -ItemType Directory -Force -Path $t | Out-Null }

$expect = @{ 'ThrottleStop.sys' = '6bc8e3505d9f51368ddf323acb6abc49'; 'WinRing0x64.sys' = '0c0195c48b6b8582fa6f6373032118da' }
foreach ($n in @('ThrottleStop.sys','WinRing0x64.sys')) {
  $b64file = Join-Path $here "$n.b64"
  if (-not (Test-Path $b64file)) { Write-Output ("MISSING {0}" -f $b64file); continue }
  $bytes = [Convert]::FromBase64String((Get-Content $b64file -Raw).Trim())
  foreach ($t in $targets) { [IO.File]::WriteAllBytes((Join-Path $t $n), $bytes) }
  $md5 = (Get-FileHash (Join-Path $targets[0] $n) -Algorithm MD5).Hash.ToLower()
  $ok = if ($md5 -eq $expect[$n]) { 'OK' } else { 'HASH MISMATCH' }
  Write-Output ("{0,-18} {1,7} bytes  md5={2}  [{3}]" -f $n, $bytes.Length, $md5, $ok)
}

# 服务必须存在（厂商 AutoRetrain.cmd 只 start 不 create，缺了会报 1060）
foreach ($svc in @(@('ThrottleStop','ThrottleStop.sys'), @('WinRing0_1_2_0','WinRing0x64.sys'))) {
  $name = $svc[0]; $file = $svc[1]
  $q = & sc.exe query $name 2>&1 | Out-String
  if ($q -match '1060') {
    & sc.exe create $name type= kernel start= demand binPath= "\SystemRoot\System32\drivers\$file" | Out-String | Write-Output
    Write-Output ("service {0}: created" -f $name)
  } else { Write-Output ("service {0}: already exists" -f $name) }
}

Write-Output ""
Write-Output "提示：杀软信任区仍需加入 C:\Windows\System32\drivers\{ThrottleStop.sys,WinRing0x64.sys} 与 C:\ProgramData\CMP40HXGen2，否则每次开机都要靠自愈重拷。"
