$ErrorActionPreference='Continue'
$log='D:\40hx-unlock\step9_final.txt'
if (Test-Path $log) { Remove-Item $log -Force }
function W($s){ ($s | Out-String) | Out-File -FilePath $log -Append -Encoding utf8 }
$DST="$env:ProgramData\CMP40HXGen2\windows"
$DRV="$env:ProgramData\CMP40HXGen2\drivers"
$SYS="$env:SystemRoot\System32\drivers"
W ("=== 最终化: 部署包装 + ESP 兜底源 + 破坏性测试 " + (Get-Date) + " ===")

# 1) 包装脚本就位
Copy-Item 'D:\40hx-unlock\RunPostBind.cmd' (Join-Path $DST 'RunPostBind.cmd') -Force
W ("  RunPostBind 更新: " + (Get-Item (Join-Path $DST 'RunPostBind.cmd')).LastWriteTime)
# 2) 普通源
Copy-Item 'D:\40hx-unlock\drv\ThrottleStop.sys' $DRV -Force
Copy-Item 'D:\40hx-unlock\drv\WinRing0x64.sys' $DRV -Force
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\40HXUnlock\drivers' | Out-Null
Copy-Item 'D:\40hx-unlock\drv\ThrottleStop.sys' 'C:\ProgramData\40HXUnlock\drivers' -Force
Copy-Item 'D:\40hx-unlock\drv\WinRing0x64.sys' 'C:\ProgramData\40HXUnlock\drivers' -Force
# 3) ESP 兜底源
mountvol Y: /s | Out-Null
if (-not (Test-Path 'Y:\')) { W "!! ESP 挂载失败" } else {
  New-Item -ItemType Directory -Force -Path 'Y:\EFI\40HX\drv' | Out-Null
  Copy-Item 'D:\40hx-unlock\drv\ThrottleStop.sys' 'Y:\EFI\40HX\drv' -Force
  Copy-Item 'D:\40hx-unlock\drv\WinRing0x64.sys' 'Y:\EFI\40HX\drv' -Force
  W ("  ESP 兜底源: " + ((Get-ChildItem 'Y:\EFI\40HX\drv' | Select-Object -ExpandProperty Name) -join ', '))
  mountvol Y: /d | Out-Null
}
# 4) 破坏性测试: 删服务+文件, 并且把普通源改名, 只留 ESP 源
W "--- 破坏: 删服务+驱动文件; 临时藏起普通源 ---"
foreach ($s in @('ThrottleStop','WinRing0_1_2_0')) { sc.exe stop $s 2>&1 | Out-Null; sc.exe delete $s 2>&1 | Out-Null }
foreach ($f in @('ThrottleStop.sys','WinRing0x64.sys')) { Remove-Item (Join-Path $SYS $f) -Force -ErrorAction SilentlyContinue }
Rename-Item 'D:\40hx-unlock\drv' 'drv_hidden' -ErrorAction SilentlyContinue
Rename-Item $DRV 'drivers_hidden' -ErrorAction SilentlyContinue
Rename-Item 'C:\ProgramData\40HXUnlock\drivers' 'drivers_hidden' -ErrorAction SilentlyContinue
Rename-Item 'D:\40hx-unlock\onlyefi-v0.1.1\windows\drivers' 'drivers_hidden' -ErrorAction SilentlyContinue
W "--- 跑 RunPostBind (只应靠 ESP 兜底自愈) ---"
$p = Start-Process -FilePath "$env:ComSpec" -ArgumentList '/d','/c',"`"$DST\RunPostBind.cmd`"" -Wait -PassThru -NoNewWindow
W ("  退出码 = " + $p.ExitCode)
W "--- postbind.log ---"
W (Get-Content (Join-Path $DST 'logs\postbind.log') -Raw -ErrorAction SilentlyContinue)
W "--- 还原普通源 ---"
Rename-Item 'D:\40hx-unlock\drv_hidden' 'drv' -ErrorAction SilentlyContinue
Rename-Item "$DRV`_hidden" 'drivers' -ErrorAction SilentlyContinue
Rename-Item 'C:\ProgramData\40HXUnlock\drivers_hidden' 'drivers' -ErrorAction SilentlyContinue
Rename-Item 'D:\40hx-unlock\onlyefi-v0.1.1\windows\drivers_hidden' 'drivers' -ErrorAction SilentlyContinue
W ("  还原后 D:\40hx-unlock\drv: " + ((Get-ChildItem 'D:\40hx-unlock\drv' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '))
W "step9 done"
