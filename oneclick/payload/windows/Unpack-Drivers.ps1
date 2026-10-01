<#
  Unpack-Drivers.ps1 —— 把 base64 文本形态的驱动/库解码落地（幂等 + SHA256 校验 + 只写必要的目标）
  为什么要有它：
    源目录（C:\ProgramData\CMP40HXGen2\drivers / C:\ProgramData\40HXUnlock\drivers）里现在只放 *.b64 文本，
    好处有两条：① 杀软不会把 base64 文本当成 BYOVD 驱动秒删（自愈源更可靠）
              ② 磁盘上不留一份"能被 SCM 直接加载"的签名驱动副本（缩小被利用的面）
    需要驱动时（开机自愈/一键修复Gen2）由本脚本解码到 System32\drivers 等真正要被加载的位置。
  用法：
    -All                     补齐新路径需要的三个文件（WinRing0x64.sys / inpoutx64.sys / inpoutx64.dll）
    -Name <文件名>           只补指定文件（可多个）
    -Quiet                   不打印到控制台，只写日志
  退出码：0 = 目标都到位；1 = 有文件没补上（日志里写明原因）
  绝不删除任何东西，绝不改服务/注册表；只做"缺了就补"。
#>
param([string[]]$Name = @(), [switch]$All, [switch]$Quiet)

$ErrorActionPreference = 'Continue'
$LOG    = 'C:\ProgramData\CMP40HXGen2\windows\logs\unpack-drivers.log'
$logDir = Split-Path -Parent $LOG
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
function W($s) {
  $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $s)
  try { Add-Content -LiteralPath $LOG -Value $line -Encoding utf8 -ErrorAction SilentlyContinue } catch { }
  if (-not $Quiet) { Write-Host $line }
}

$FILES = @(
  @{ Name = 'WinRing0x64.sys' ; Sha = '11bd2c9f9e2397c9a16e0990e4ed2cf0679498fe0fd418a3dfdac60b5c160ee5' ; Dest = @('C:\Windows\System32\drivers') },
  @{ Name = 'inpoutx64.sys'   ; Sha = 'f8965fdce668692c3785afa3559159f9a18287bc0d53abb21902895a8ecf221b' ; Dest = @('C:\Windows\System32\drivers') },
  @{ Name = 'inpoutx64.dll'   ; Sha = '5f27ed4d5cd58a1ee23deeb802e09e73f3a1d884ce2135f6e827f67b171269e7' ; Dest = @('C:\ProgramData\CMP40HXGen2\drivers') },
  @{ Name = 'ThrottleStop.sys'; Sha = '16f83f056177c4ec24c7e99d01ca9d9d6713bd0497eeedb777a3ffefa99c97f0' ; Dest = @('C:\Windows\System32\drivers') }
)
# 源目录优先级：本包自愈目录 → 厂商目录 → 厂商 cand2（都是"先找裸文件 / 再找 .b64"）
$SRCDIRS = @('C:\ProgramData\CMP40HXGen2\drivers', 'C:\ProgramData\40HXUnlock\drivers', 'C:\ProgramData\40HXUnlock\cand2')

function Sha256Of([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return '' }
  try { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() } catch { return '' }
}
function Write-Bin([string]$destPath, [byte[]]$bin) {
  # 2026-10-01b（第三方审查）：先写临时文件再原子替换。
  #   开机任务（onstart）与登录补跑任务（onlogon +60s）可能并发调用本脚本，
  #   直接 WriteAllBytes 到目标文件可能被对方看到"写了一半的驱动"（加载坏驱动会蓝屏）。
  # 每个进程用独立的临时名（onstart 与 onlogon+60s 可能同时跑）
  $tmp = $destPath + '.tmp-' + $PID
  try {
    $dir = Split-Path -Parent $destPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllBytes($tmp, $bin)
    Move-Item -LiteralPath $tmp -Destination $destPath -Force -ErrorAction Stop
    return $true
  } catch {
    try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
    W ('  写不进去（被占用/杀软拦）: ' + $destPath + ' -> ' + $_.Exception.Message)
    return $false
  }
}
function Get-FromSources([string]$fileName, [string]$wantSha, [string]$destPath) {
  # ① 源目录里的同名裸文件（老版本机器上还是这种形态）
  foreach ($d in $SRCDIRS) {
    $raw = Join-Path $d $fileName
    if ((Test-Path -LiteralPath $raw) -and ((Sha256Of $raw) -eq $wantSha)) {
      # 2026-10-01b（第三方审查）：裸文件分支也要原子写（原来直接 Copy-Item，并发时可能被读到半截）
      try {
        if (Write-Bin $destPath ([IO.File]::ReadAllBytes($raw))) { return ('裸文件拷贝(原子) <- ' + $raw) }
      } catch { W ('  拷贝失败: ' + $raw + ' -> ' + $_.Exception.Message) }
    }
  }
  # ② 源目录里的 base64 文本
  foreach ($d in $SRCDIRS) {
    $b64 = Join-Path $d ($fileName + '.b64')
    if (Test-Path -LiteralPath $b64) {
      try {
        $txt = (Get-Content -LiteralPath $b64 -Raw) -replace '[\r\n\s]', ''
        $bin = [Convert]::FromBase64String($txt)
      } catch { W ('  b64 解码失败: ' + $b64 + ' -> ' + $_.Exception.Message); continue }
      $h = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bin)) -replace '-', '').ToLower()
      if ($h -ne $wantSha) { W ('  b64 内容哈希不符，跳过: ' + $b64 + ' (' + $h.Substring(0, 16) + '…)'); continue }
      if (Write-Bin $destPath $bin) { return ('b64 解码 <- ' + $b64) }
    }
  }
  return ''
}

$todo = @()
if ($All) { $todo = @($FILES | Where-Object { $_.Name -ne 'ThrottleStop.sys' }) }
elseif ($Name.Count -gt 0) { $todo = @($FILES | Where-Object { $Name -contains $_.Name }) }
if ($todo.Count -eq 0) { W 'nothing to do（没给 -All 也没给 -Name，直接退出，什么都没改）'; exit 0 }

W ('=== unpack start  All=' + [bool]$All + '  Name=' + ($Name -join ',') + ' ===')
$bad = 0
foreach ($f in $todo) {
  foreach ($dst in $f.Dest) {
    $target = Join-Path $dst $f.Name
    if ((Sha256Of $target) -eq $f.Sha) { W ('already ok : ' + $target); continue }
    $how = Get-FromSources $f.Name $f.Sha $target
    if ($how -eq '') { W ('FAILED     : ' + $target + '（源目录里既没有裸文件也没有可用的 ' + $f.Name + '.b64）'); $bad++ ; continue }
    $now = Sha256Of $target
    if ($now -eq $f.Sha) { W ('OK         : ' + $target + '  (' + $how + ')') }
    else {
      # 2026-10-01b（审查 H2）：$now 可能是空串（读不到/被占用）→ 原来直接 .Substring 会抛异常，
      #   而 EAP=Continue 只打印、$bad++ 不执行 → 上层把"没补齐"当成成功（exit 0）。
      $pfx = 'READ-FAILED/empty'
      if ($now -and $now.Length -ge 16) { $pfx = $now.Substring(0, 16) + '…' }
      W ('MISMATCH   : ' + $target + '  sha=' + $pfx)
      $bad++
    }
  }
}
W ('=== unpack end  failed=' + $bad + ' ===')
if ($bad -gt 0) { exit 1 }
exit 0
