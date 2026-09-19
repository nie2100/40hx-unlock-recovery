$ErrorActionPreference='Continue'
$log='D:\40hx-unlock\step5_ts.txt'
if (Test-Path $log) { Remove-Item $log -Force }
function W($s){ ($s | Out-String) | Out-File -FilePath $log -Append -Encoding utf8 }
$pkg='D:\40hx-unlock\onlyefi-v0.1.1\windows'
$bak='C:\ProgramData\40HXUnlock\drivers'
W ("=== 用厂商备份源补 ThrottleStop + 原子跑 helper " + (Get-Date) + " ===")
$ts="$env:SystemRoot\System32\drivers\ThrottleStop.sys"
$wr="$env:SystemRoot\System32\drivers\WinRing0x64.sys"
$srcTS=Join-Path $bak 'ThrottleStop.sys'
$srcWR=Join-Path $bak 'WinRing0x64.sys'
W ("源: TS=" + (Test-Path $srcTS) + " WR=" + (Test-Path $srcWR))
foreach ($f in @($srcTS,$srcWR)) { if (Test-Path $f) { W ("  " + (Split-Path $f -Leaf) + " size=" + (Get-Item $f).Length + " sha256=" + (Get-FileHash $f -Algorithm SHA256).Hash.Substring(0,16)) } }
# 同时把包内缺失的 ThrottleStop 补回去(供后续 Install_Auto 用)
if ((Test-Path $srcTS) -and -not (Test-Path (Join-Path $pkg 'drivers\ThrottleStop.sys'))) { Copy-Item $srcTS (Join-Path $pkg 'drivers\ThrottleStop.sys') -Force; W "  包内 drivers\ThrottleStop.sys 已补" }

Copy-Item $srcTS $ts -Force
Copy-Item $srcWR $wr -Force
Start-Sleep -Milliseconds 300
W ("复制后: TS=" + (Test-Path $ts) + " WR=" + (Test-Path $wr))

foreach ($s in @(@('ThrottleStop','ThrottleStop.sys'),@('WinRing0_1_2_0','WinRing0x64.sys'))) {
  sc.exe query $s[0] | Out-Null
  if ($LASTEXITCODE -ne 0) { W ((sc.exe create $s[0] 'type=' 'kernel' 'start=' 'demand' 'binPath=' "\SystemRoot\System32\drivers\$($s[1])" 2>&1 | Out-String)) }
}
sc.exe start ThrottleStop 2>&1 | Out-Null
sc.exe start WinRing0_1_2_0 2>&1 | Out-Null
Start-Sleep -Seconds 2
W ((sc.exe query ThrottleStop 2>&1 | Select-String STATE | Out-String))
W ((sc.exe query WinRing0_1_2_0 2>&1 | Select-String STATE | Out-String))
W ("起服务后文件: TS=" + (Test-Path $ts) + " WR=" + (Test-Path $wr))

W "`n--- CMP40HXGen2.exe 输出 ---"
$out = & (Join-Path $pkg 'CMP40HXGen2.exe') 2>&1 | Out-String
$rc = $LASTEXITCODE
W $out
W ("=== 退出码 = " + $rc + "  (0 = PASS 物理 Gen2 x16) ===")
W ((& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current --format=csv 2>&1 | Out-String))
W ((Get-Item 'C:\ProgramData\Huorong\Sysdiag\QuarantineEx.db' -ErrorAction SilentlyContinue | Select-Object LastWriteTime | Out-String))
W "step5 done"
