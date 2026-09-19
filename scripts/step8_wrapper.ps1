$ErrorActionPreference='Continue'
$log='D:\40hx-unlock\step8_wrapper.txt'
if (Test-Path $log) { Remove-Item $log -Force }
function W($s){ ($s | Out-String) | Out-File -FilePath $log -Append -Encoding utf8 }
$DST="$env:ProgramData\CMP40HXGen2\windows"
$DRV="$env:ProgramData\CMP40HXGen2\drivers"
if (-not (Test-Path $DRV)) { New-Item -ItemType Directory -Force -Path $DRV | Out-Null }
W ("=== 部署新的 RunPostBind + 直跑测试 " + (Get-Date) + " ===")
Copy-Item 'D:\40hx-unlock\RunPostBind.cmd' (Join-Path $DST 'RunPostBind.cmd') -Force
W ("  RunPostBind.cmd 已更新 = " + (Get-Item (Join-Path $DST 'RunPostBind.cmd')).LastWriteTime)
foreach ($n in @('ThrottleStop.sys','WinRing0x64.sys')) { Copy-Item (Join-Path 'D:\40hx-unlock\drv' $n) (Join-Path $DRV $n) -Force }
W ("  自愈源2: " + ((Get-ChildItem $DRV -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '))
# 模拟开机: 先删掉 System32 驱动和服务, 看包装脚本能否自愈
W "--- 故意破坏: 删服务 + 删文件(模拟火绒清理) ---"
foreach ($s in @('ThrottleStop','WinRing0_1_2_0')) { sc.exe stop $s 2>&1 | Out-Null; sc.exe delete $s 2>&1 | Out-Null }
foreach ($f in @('ThrottleStop.sys','WinRing0x64.sys')) { Remove-Item "$env:SystemRoot\System32\drivers\$f" -Force -ErrorAction SilentlyContinue }
$q = (sc.exe query ThrottleStop 2>&1 | Out-String)
if ($q -match '1060') { $svcState = 'absent' } else { $svcState = 'present' }
W ("  删除后: 文件=" + ((Get-ChildItem "$env:SystemRoot\System32\drivers" -ErrorAction SilentlyContinue | Where-Object {$_.Name -match 'ThrottleStop|WinRing'} | Select-Object -ExpandProperty Name) -join ',') + " ; 服务=" + $svcState)
W "--- 跑 RunPostBind.cmd ---"
$p = Start-Process -FilePath "$env:ComSpec" -ArgumentList '/d','/c',"`"$DST\RunPostBind.cmd`"" -Wait -PassThru -NoNewWindow
W ("  RunPostBind 退出码 = " + $p.ExitCode)
W "--- postbind.log ---"
W (Get-Content (Join-Path $DST 'logs\postbind.log') -Raw -ErrorAction SilentlyContinue)
W "--- last.log (AutoRetrain) 尾 ---"
W ((Get-Content (Join-Path $DST 'logs\last.log') -Raw -ErrorAction SilentlyContinue))
W ((& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=pcie.link.gen.current,pcie.link.gen.max --format=csv 2>&1 | Out-String))
W "step8 done"
