#Requires -Version 5.1
<#
  修复-GSP.ps1（2026-09-30）
  =====================================================================
  只干一件事：给 CMP 40HX 的显示类注册表子键写上 EnableGpuFirmware=1（开启 GSP 固件）。
  为什么要它：GSP 没开时，解锁固件把算力解开后 nvlddmkm 认不了这张卡
             → 开机黑屏一段时间 + 设备管理器里 40HX 变成"代码 43"。
             厂商 README 的要求也是"驱动 正常无 Code43，GSP 启用"。
  写在哪：HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\<000X>
          （匹配 MatchingDeviceId 含 ven_10de&dev_1f0b 的那一个子键；本机正常机器上就是这里）
          注意：写 HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters 是没用的（驱动不读那里）。
  可逆：删掉该值就回到原样，脚本最后会打印删除命令。
  不改别的任何东西；不碰驱动文件、服务、EFI、引导项。
#>
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(936) } catch { }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host '================= CMP 40HX GSP 修复 =================' -ForegroundColor Cyan
if (-not $admin) {
  Write-Host '需要管理员权限：右键"以管理员身份运行"本脚本，或双击 修复-GSP.cmd' -ForegroundColor Red
  exit 2
}

# 当前 GSP 状态（nvidia-smi）
$smi = "$env:SystemRoot\System32\nvidia-smi.exe"
if (Test-Path $smi) {
  $q = (& $smi -q 2>&1 | Out-String)
  $m = [regex]::Match($q, '(?im)^\s*GSP Firmware Version\s*:\s*(.+?)\s*$')
  if ($m.Success) { Write-Host ('当前 nvidia-smi GSP 行: ' + $m.Value.Trim()) } else { Write-Host '当前 nvidia-smi 里没有 GSP 行（可能没装驱动）' }
  if ($m.Success -and $m.Groups[1].Value.Trim() -notmatch '^(N/?A|-+)$') {
    Write-Host 'GSP 已经是开启状态（显示的是版本号）。如果还黑屏/43，请把情况发回来，别重复跑本脚本。' -ForegroundColor Green
  }
} else { Write-Host '找不到 nvidia-smi.exe（先装 NVIDIA 驱动）' -ForegroundColor Yellow }

$cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$targets = @()
foreach ($sub in (Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
  $mid = [string](Get-ItemProperty $sub.PSPath -Name MatchingDeviceId -ErrorAction SilentlyContinue).MatchingDeviceId
  $dd  = [string](Get-ItemProperty $sub.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
  if ($mid -match '(?i)ven_10de&dev_1f0b' -or $dd -match 'CMP 40HX') { $targets += $sub }
}
if ($targets.Count -eq 0) {
  Write-Host '没找到 CMP 40HX 的显示类子键（DEV_1F0B）。先确认驱动装上了、设备管理器里能看到这张卡，再跑一次。' -ForegroundColor Red
  Write-Host ('子键根: ' + $cls)
  exit 1
}
foreach ($t in $targets) {
  $dd = (Get-ItemProperty $t.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
  $mid = (Get-ItemProperty $t.PSPath -Name MatchingDeviceId -ErrorAction SilentlyContinue).MatchingDeviceId
  $before = (Get-ItemProperty $t.PSPath -Name EnableGpuFirmware -ErrorAction SilentlyContinue).EnableGpuFirmware
  Write-Host ''
  Write-Host ('目标子键 : ' + $t.PSChildName + '   DriverDesc=' + $dd)
  Write-Host ('MatchingDeviceId : ' + $mid)
  Write-Host ('修改前 EnableGpuFirmware = ' + $(if ($null -eq $before) { '<不存在>' } else { $before }))
  if ($before -eq 1) { Write-Host '已经是 1，无需修改。' -ForegroundColor Green; continue }
  New-ItemProperty -Path $t.PSPath -Name 'EnableGpuFirmware' -PropertyType DWord -Value 1 -Force | Out-Null
  $after = (Get-ItemProperty $t.PSPath -Name EnableGpuFirmware -ErrorAction SilentlyContinue).EnableGpuFirmware
  if ($after -eq 1) { Write-Host '修改后 EnableGpuFirmware = 1  （写入成功并回读通过）' -ForegroundColor Green }
  else { Write-Host ('写入失败，回读 = ' + $after) -ForegroundColor Red }
}
Write-Host ''
Write-Host '================= 接下来必须这么做 =================' -ForegroundColor Yellow
Write-Host ' 1) 完全关机：开始菜单 → 关机（不是"重启"！重启不会清干净显卡状态）' -ForegroundColor Yellow
Write-Host '    最好关机后拔掉电源线等 10 秒再插上（笔记本拔电+长按电源键 5 秒）' -ForegroundColor Yellow
Write-Host ' 2) 开机 → 等进系统 → 再跑一次 一键诊断.cmd' -ForegroundColor Yellow
Write-Host '    看到"判据 A：GSP 已启用（显示的是版本号）"才算好；' -ForegroundColor Yellow
Write-Host '    再看第 2 节里 40HX 的 [OK] / Problem=0（不再是 43）' -ForegroundColor Yellow
Write-Host ' 3) 然后双击 状态自检.bat 看最终结论' -ForegroundColor Yellow
Write-Host ''
Write-Host '想还原（删掉刚写的值）就用这条命令（管理员 PowerShell）：' -ForegroundColor Gray
foreach ($t in $targets) { Write-Host ('  Remove-ItemProperty -Path "' + ($t.PSPath -replace '^Microsoft\.PowerShell\.Core\\', '') + '" -Name EnableGpuFirmware') -ForegroundColor Gray }
Write-Host ''
