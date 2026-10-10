<#
  回滚-安全加固.ps1 —— 把本包 2026-10-01b 做的两项安全加固退回去
    ① 目录权限：从 C:\ProgramData\CMP40HXGen2\logs\acl-backup-*\ 的备份恢复（只动 4 个已知目录；绝不带 /T）
    ② 驱动源：把 *.b64 解回裸 .sys/.dll（逐个 SHA256 校验，校验不过就拒绝写出）
  只改这两类，不碰引导 / ESP / 服务 / ACE / 注册表。
  退出码：0 = 全部成功（或本来就没有要回滚的）；1 = 有项目没成功（详见输出与日志）
  用法：双击 回滚-安全加固.cmd（自己提权）
#>
$ErrorActionPreference = 'Continue'
$adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm) { Write-Host '需要管理员权限，请右键 → 以管理员身份运行。按回车退出。'; Read-Host | Out-Null; exit 1 }

$fail = 0
function T($s, $c = 'Gray') { Write-Host $s -ForegroundColor $c }
function OK($s) { T ('  [OK] ' + $s) 'Green' }
function NG($s) { T ('  [!!] ' + $s) 'Yellow'; $script:fail++ }

T '=== 回滚安全加固（2026-10-01b） ===' 'Cyan'
T ('时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ---- ① 目录权限：用已知目录 + 备份文件名反查（不解析备份文件内容，避免编码/格式差异）----
T ''
T '[1/2] 目录权限（从 logs\acl-backup-* 恢复）' 'Cyan'
$logDir = 'C:\ProgramData\CMP40HXGen2\logs'
$dirs = @('C:\ProgramData\CMP40HXGen2', 'C:\ProgramData\CMP40HXGen2\drivers', 'C:\ProgramData\40HXUnlock', 'C:\ProgramData\40HXUnlock\drivers')
$baks = @()
if (Test-Path -LiteralPath $logDir) { $baks = @(Get-ChildItem -LiteralPath $logDir -Directory -Filter 'acl-backup-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending) }
if ($baks.Count -eq 0) {
  T '  没找到 ACL 备份 → 不改动任何 ACL（不猜、不重置；避免把目录改成谁都读不了）' 'Yellow'
  # 2026-10-01b（第三方审查）：什么都没恢复也算失败 —— 否则脚本会打印"回滚完成"并 exit 0（假成功）
  T '     → 这份机器的 ACL 加固**没有**被回滚（没有任何备份）；如果你确实想恢复继承，见下面的手工命令' 'Yellow'
  $script:fail++
} else {
  T ('  用备份目录: ' + $baks[0].FullName)
  foreach ($t in $dirs) {
    if (-not (Test-Path -LiteralPath $t)) { continue }
    $bakFile = Join-Path $baks[0].FullName ((($t -replace '[\\:]', '_')) + '.acl.txt')
    if (-not (Test-Path -LiteralPath $bakFile)) { NG ('没找到 ' + $t + ' 的备份（' + (Split-Path -Leaf $bakFile) + '）→ 跳过') ; continue }
    $r = (icacls $t /restore $bakFile 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) { OK ('已恢复 ' + $t) } else { NG ('恢复失败 ' + $t + ' -> ' + ($r -replace "`r?`n", ' ').Trim()) }
  }
  T '  提示：确实想让它回到"Windows 默认（继承，普通用户可写）"就手工跑：icacls "<目录>" /inheritance:e /T /C' 'Gray'
  T '        （注意：那等于放弃这层加固 —— 普通用户又能替换里面的 .sys）' 'Gray'
}

# ---- ② 驱动源：.b64 解回裸文件（逐个校验 SHA256）----
T ''
T '[2/2] 驱动源恢复成裸文件（带 SHA256 校验）' 'Cyan'
$hash = @{
  'WinRing0x64.sys'  = '11bd2c9f9e2397c9a16e0990e4ed2cf0679498fe0fd418a3dfdac60b5c160ee5'
  'inpoutx64.sys'    = 'f8965fdce668692c3785afa3559159f9a18287bc0d53abb21902895a8ecf221b'
  'inpoutx64.dll'    = '5f27ed4d5cd58a1ee23deeb802e09e73f3a1d884ce2135f6e827f67b171269e7'
  'ThrottleStop.sys' = '16f83f056177c4ec24c7e99d01ca9d9d6713bd0497eeedb777a3ffefa99c97f0'
}
$names = @('WinRing0x64.sys', 'inpoutx64.sys', 'inpoutx64.dll')
$wrote = 0
foreach ($d in @('C:\ProgramData\CMP40HXGen2\drivers', 'C:\ProgramData\40HXUnlock\drivers')) {
  if (-not (Test-Path -LiteralPath $d)) { continue }
  foreach ($f in $names) {
    $b64 = Join-Path $d ($f + '.b64')
    $raw = Join-Path $d $f
    if (-not (Test-Path -LiteralPath $b64)) { continue }
    if (Test-Path -LiteralPath $raw) { continue }   # 裸文件已在，不用动
    try {
      $bin = [Convert]::FromBase64String(((Get-Content -LiteralPath $b64 -Raw) -replace '[\r\n\s]', ''))
      $h = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bin)) -replace '-', '').ToLower()
      if ($h -ne $hash[$f]) { NG ($b64 + ' 内容哈希不符（期望 ' + $hash[$f].Substring(0, 16) + '… 实际 ' + $h.Substring(0, 16) + '…）→ 不写出'); continue }
      $tmp = $raw + '.tmp'
      [IO.File]::WriteAllBytes($tmp, $bin)
      Move-Item -LiteralPath $tmp -Destination $raw -Force -ErrorAction Stop
      OK ('已写回裸文件 ' + $raw + '（' + $bin.Length + ' B，sha256 校验通过）'); $wrote++
    } catch { NG ($raw + ' 写回失败: ' + $_.Exception.Message) }
  }
}
if ($wrote -eq 0) { T '  没有需要写回的（裸文件本来就在，或源目录里没有 .b64）' }

T ''
if ($fail -eq 0) { T '回滚完成。建议再跑一次 一键安装.cmd → 修复，并重启验证 Gen2。' 'Green'; exit 0 }
T ('回滚没完全成功：' + $fail + ' 项失败（见上面的 [!!] 行）。把这段输出拍给经销商。') 'Yellow'
exit 1
