$ErrorActionPreference='Continue'
$log='D:\40hx-unlock\install_onlyefi.txt'
if (Test-Path $log) { Remove-Item $log -Force }
function W($s){ ($s | Out-String) | Out-File -FilePath $log -Append -Encoding utf8 }
W ("=== 安装 CMP40HX-Unlock-OnlyEFI v0.1.1 的 EFI " + (Get-Date) + " ===")

$theirEFI = 'D:\40hx-unlock\onlyefi-v0.1.1\EFI\40HXUNLK.EFI'
$theirHash = (Get-FileHash $theirEFI -Algorithm SHA256).Hash
W ("他们的 EFI: sha256=" + $theirHash + " size=" + (Get-Item $theirEFI).Length + " (应为 1E9CA43FAB3D5CE8…)")

# 0) 关掉厂商版 Gen2 自启(测试期间只让他们的 helper 动寄存器)
W "--- 禁用厂商版 Gen2 自启 ---"
W ((schtasks /change /tn "40HX PCIe Gen2 Bring-up" /disable 2>&1 | Out-String))
$rk='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$v=(Get-ItemProperty -Path $rk -Name '40HXGen2' -ErrorAction SilentlyContinue).'40HXGen2'
if ($v) { Set-ItemProperty -Path $rk -Name '40HXGen2_bak' -Value $v; Remove-ItemProperty -Path $rk -Name '40HXGen2' -ErrorAction SilentlyContinue; W "  Run 键已改名为 40HXGen2_bak" }

# 1) 备份当前 ESP 上的 EFI
$bk='D:\40hx-unlock\efi_backup_v3.1.2'
New-Item -ItemType Directory -Force -Path $bk | Out-Null
mountvol Y: /s | Out-Null
if (-not (Test-Path 'Y:\')) { W "!! ESP 挂载失败"; exit }
foreach ($p in @('\EFI\40HX\40HXUNLK.EFI','\EFI\Boot\bootx64.efi')) {
  $t='Y:'+$p
  if (Test-Path $t) {
    $h=(Get-FileHash $t -Algorithm SHA256).Hash
    Copy-Item $t (Join-Path $bk (($p -replace '[\\]','_')+'.v312')) -Force
    W ("  备份 " + $p + " (sha256=" + $h.Substring(0,16) + "…)")
  }
  Copy-Item $theirEFI $t -Force
  $h2=(Get-FileHash $t -Algorithm SHA256).Hash
  W ("  写入 " + $p + " -> sha256=" + $h2.Substring(0,16) + "… 一致=" + ($h2 -eq $theirHash))
}
W ((Get-ChildItem -Force 'Y:\EFI\40HX','Y:\EFI\Boot' | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize | Out-String))
mountvol Y: /d | Out-Null

W "--- 策略键(保持不回退) ---"
W ((Get-ItemProperty 'HKLM:\SOFTWARE\40HXUnlock' | Select-Object Gen2AutoHard,Gen2PnpFallback | Out-String))
W "--- 任务 ---"
W ((schtasks /query /fo LIST 2>&1 | Select-String -Pattern '40HX' | Out-String))
W "install_onlyefi done"
