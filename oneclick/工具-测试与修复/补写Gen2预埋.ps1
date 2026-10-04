# ============================================================
#  40HX Gen2 预埋补写（一键；先 dry-run 给你看，再真写）
#  用途：解锁固件（EFI）本该在开机时把 Gen2 前提值写进 GPU 内部寄存器，
#        但某些机器/批次它自己 abort 了（ESP 日志里 [efi-b] abort: baseline mismatch），
#        结果 GPU 只报 Gen1 能力 → Windows 侧再怎么重训都到不了 Gen2。
#        本工具就在 Windows 侧把这几个值补上（与厂商 EFI 写的目标值一致）：
#          XVE_OVR = 0x00000006 / CYA_0 = 0x068731B3 / PL_LINK_RATE = 0x00220036 / 两端 TLS = 2
#        然后重训、复读校验。
#  安全：写之前**先把原值落盘**（C:\Temp\40hx-prime-backup.txt，可按里面的说明回写）；
#        写的是 GPU 内部寄存器，极小概率花屏/不亮 → 完全关机（不是重启）即可恢复。
#        默认先跑 dry-run（不写任何 GPU 寄存器，只会生成原值备份文件 C:\Temp\40hx-prime-backup.txt），你确认后才真写。
#  用法：双击 工具-测试与修复\补写Gen2预埋.cmd
#        只想看要写什么、不写：双击后选 N，或命令行 -DryOnly
# ============================================================
param([switch]$Yes, [switch]$DryOnly, [switch]$NoWait)
$ErrorActionPreference = 'Continue'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$__adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $__adm) {
  $__self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
  $extra = @()
  if ($Yes) { $extra += '-Yes' }
  if ($DryOnly) { $extra += '-DryOnly' }
  Write-Host '需要管理员权限，正在自动提权（如果弹出“用户帐户控制”，请点“是”）...' -ForegroundColor Yellow
  Write-Host '提示：推荐直接双击 补写Gen2预埋.cmd（那个窗口会一直留着让你看结果）。' -ForegroundColor Gray
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList ((@('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $__self + '"')) + $extra)) -Verb RunAs -Wait -PassThru -ErrorAction Stop
  # 2026-10-05：提权那一步所在的窗口不要一闪就没（客户反馈过"闪退"）——留一行结果 + 等按键
  if (-not $NoWait) {
    try {
      Write-Host ('提权那一步已结束（退出码 ' + $p.ExitCode + '）。报告在桌面：40HX-Gen2补写预埋-*.txt') -ForegroundColor Gray
      $null = Read-Host '按回车关闭本窗口'
    } catch { }
  }
  exit $p.ExitCode
}
$wantVer = '20261004e'
$src = Join-Path (Split-Path -Parent $here) 'payload\windows\40hx-retrain-inpout.ps1'
$dst = "$env:ProgramData\CMP40HXGen2\windows\40hx-retrain-inpout.ps1"
$desk = [Environment]::GetFolderPath('Desktop'); if (-not $desk) { $desk = 'C:\Users\Public\Desktop' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# 2026-10-05 (review low-4): the retrain tool always writes windows\logs\retrain-last.log - a dry-run must
#   NOT destroy the evidence of the last real run, so keep a copy and put it back afterwards.
$lastLog = Join-Path "$env:ProgramData\CMP40HXGen2" 'windows\logs\retrain-last.log'
$keepLog = $null
if (Test-Path -LiteralPath $lastLog) { try { $keepLog = Get-Content -LiteralPath $lastLog -Raw -ErrorAction Stop } catch { $keepLog = $null } }
$sum = Join-Path $desk ('40HX-Gen2补写预埋-' + $stamp + '.txt')
$out = New-Object System.Collections.ArrayList
function T { param([string]$t,[string]$c='Gray') Write-Host $t -ForegroundColor $c; [void]$out.Add($t) }
function Save { $out | Out-File -Encoding utf8 $sum }
T '============================================================' 'Cyan'
T '  40HX Gen2 预埋补写（EFI 没预埋时的 Windows 侧兜底）' 'Cyan'
T '============================================================' 'Cyan'
T ('时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# 1) 工具就位（版本门禁 + 哈希比对）
$toolsrc = $null
if (Test-Path $src) {
  try {
    $txt = Get-Content -LiteralPath $src -Raw -ErrorAction Stop
    if ($txt -match ('TOOL_VER = ' + [char]39 + [regex]::Escape($wantVer) + [char]39)) { $toolsrc = $src }
    else { T ('  [X] 包内工具不是这一版（应含 TOOL_VER = ' + $wantVer + '）—— 请重新解压一份包') 'Red'; Save; exit 1 }
  } catch { T ('  [X] 读不了包内工具: ' + $_.Exception.Message) 'Red'; Save; exit 1 }
}
if ($toolsrc) {
  $h1 = (Get-FileHash -LiteralPath $toolsrc -Algorithm SHA256).Hash
  $h2 = if (Test-Path $dst) { (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash } else { '' }
  if ($h1 -ne $h2) {
    T '  [1/3] 就地更新 Gen2 工具到 C:\ProgramData\CMP40HXGen2\windows'
    try { Copy-Item -LiteralPath $toolsrc -Destination $dst -Force -ErrorAction Stop; T '        已更新' 'Green' }
    catch { T ('  [X] 更新失败: ' + $_.Exception.Message + '（先关掉其它正在跑的本包工具，再试）') 'Red'; Save; exit 1 }
  } else { T '  [1/3] 机器上的工具已是最新（哈希一致，跳过拷贝）' }
} elseif (Test-Path $dst) {
  # 2026-10-05（审查 M4）：包内没带工具时，也必须校验机器上已装的那份版本，否则版本门禁等于被绕过
  $txtInst = ''
  try { $txtInst = Get-Content -LiteralPath $dst -Raw -ErrorAction Stop } catch { }
  if ($txtInst -match ('TOOL_VER = ' + [char]39 + [regex]::Escape($wantVer) + [char]39)) {
    T '  [1/3] 包里没带工具；机器上已装的那份版本正确（' + $wantVer + '）' 'Yellow'
  } else {
    T ('  [X] 包里没带工具，机器上已装的那份也不是 ' + $wantVer + ' —— 先双击 一键安装.cmd 更新工具，再跑本工具') 'Red'
    Save; exit 1
  }
} else {
  T '  [X] 找不到 40hx-retrain-inpout.ps1（包里和 ProgramData 里都没有）—— 先跑一次 一键安装.cmd' 'Red'; Save; exit 1
}
T ('  工具: ' + $dst)

function Run-Tool([switch]$DoApply) {
  # 2026-10-05（审查 L3 说明）：dry-run 也带 -AllowPrime —— 这不是"允许写"，而是让工具进入"补写分支"的
  #   **预演**（只打印 `[dry run] ...`，真正落寄存器还需要 -Apply）。不带它，dry-run 只会打印"默认不自动补写"，看不到要写什么。
  $args2 = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $dst, '-AllowPrime')
  if ($DoApply) { $args2 += '-Apply' }
  $raw = Join-Path $env:TEMP ('40hx-prime-' + $stamp + $(if ($DoApply) { '-apply' } else { '-dry' }) + '.txt')
  & powershell.exe @args2 2>&1 | Tee-Object -FilePath $raw | ForEach-Object { Write-Host $_; [void]$out.Add([string]$_) }
  return [pscustomobject]@{ RC = $LASTEXITCODE; Raw = $(if (Test-Path $raw) { (Get-Content -LiteralPath $raw -Raw -ErrorAction SilentlyContinue) } else { '' }) }
}

# 2) dry-run：不写任何寄存器，只看要写什么
T ''
T '  [2/3] 试跑（dry-run，不写任何寄存器；只显示"会写什么"）' 'Cyan'
$r1 = Run-Tool
$dryLines = @(($r1.Raw -split "`r?`n") | Where-Object { $_ -match 'dry run|已是目标值|缺口|PRIMER_GAPS|GUARD|体检缺口' })
if (-not ($r1.Raw -match 'PRIMER_GAPS')) { T '  [X] 没看到工具输出（可能被杀软拦/没提权成功）—— 把本报告发回来' 'Red'; Save; exit 1 }
if ($r1.Raw -match 'PRIMER_GAPS = none') {
  T '  >>> 这台机器的 Gen2 前提值已经预埋好了，**不需要补写**。' 'Green'
  T '      如果 Gen2 还是没到，请把 logs\retrain-last.log 发回来。' 'Green'
  Save; exit 0
}
T '  这台机器缺的预埋项（工具报的缺口）：'
foreach ($l in @(($r1.Raw -split "`r?`n") | Where-Object { $_ -match '体检缺口|PRIMER_GAPS|XVE_OVR|CYA_0|PL_LINK_RATE|VSEC_DEVICE|GPU LNKCAP|TLS\(LNKCTL2\)' })) { T ('    ' + $l.Trim()) }
T ''
T '  将要补写的内容（dry-run 原文；写之前会把原值存到 C:\Temp\40hx-prime-backup.txt）:'
foreach ($l in $dryLines) { T ('    ' + $l.Trim()) }

if ($DryOnly) {
  # 把 dry-run 自己那份日志另存，然后把上一次真跑的 retrain-last.log 放回去
  if (Test-Path -LiteralPath $lastLog) {
    try { Copy-Item -LiteralPath $lastLog -Destination (Join-Path (Split-Path -Parent $lastLog) ('retrain-dryrun-' + $stamp + '.log')) -Force -ErrorAction Stop } catch { }
    if ($null -ne $keepLog) { try { Set-Content -LiteralPath $lastLog -Value $keepLog -Encoding UTF8 -ErrorAction Stop } catch { } }
    else { Remove-Item -LiteralPath $lastLog -Force -ErrorAction SilentlyContinue }
    T '  （本次是 dry-run：工具自己那份日志已另存为 logs\retrain-dryrun-*.log，上一次真跑的 retrain-last.log 已保留）' 'Gray'
  }
  T ''; T '  （-DryOnly：到此为止，没写任何 GPU 寄存器；只生成了原值备份文件）' 'Yellow'; Save; exit 0
}
$go = $Yes
if (-not $go) {
  T ''
  Write-Host '  真要补写吗？补写会动 GPU 内部寄存器（极小概率花屏/不亮，完全关机能恢复）。输入 Y 继续，其它键取消: ' -ForegroundColor Yellow -NoNewline
  $k = Read-Host
  $go = ($k -eq 'Y' -or $k -eq 'y')
}
if (-not $go) { T '  已取消（没有写任何寄存器）' 'Yellow'; Save; exit 0 }

# 3) 真写 + 重训
T ''
T '  [3/3] 补写 + 重训（现在会写寄存器）' 'Cyan'
$r2 = Run-Tool -DoApply
$ok = (($r2.RC -eq 0) -and ($r2.Raw -match 'PASS:\s*(already\s+)?physical Gen2 x16'))
T ''
T ('  工具返回码: ' + $r2.RC + '   （0=Gen2 到位  10=链路没到 Gen2  11=基线不认识  3=WinRing0 起不来  12=驱动没就绪  13=inpoutx64 没加载）')
T ''
T '  结论：'
if ($ok) {
  T '    [OK] Gen2 已经到位（日志里有 PASS: physical Gen2 x16）' 'Green'
  T '    说明这台机器就是缺 EFI 预埋 —— 补上就到了。' 'Green'
  T '    注意：这些内部寄存器是**易失**的，重启/关机后会回到 EFI 预埋的状态；' 'Yellow'
  T '    想让每次开机都自动落地，请把 40HX-Gen2补写预埋-*.txt + logs\retrain-last.log 发回来（我们要看 ESP 日志后修固件）。' 'Yellow'
} else {
  T '    [!!] 这次还是没到 Gen2 —— 说明光补这几项不够（这台机器的 EFI 门禁/平台还有别的差异）。' 'Yellow'
  T '    请把桌面上这两个文件发回来：' 'Yellow'
  T ('      ' + $sum)
  T '      C:\ProgramData\CMP40HXGen2\windows\logs\retrain-last.log'
  T '    （算力解锁不受影响；这些寄存器本来就是易失的）' 'Yellow'
}
T ''
T ('  报告已存: ' + $sum)
Save
if ($ok) { exit 0 } else { exit 1 }
