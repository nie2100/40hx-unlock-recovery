# 就地更新 Gen2 工具并立刻跑一次（给现场用；只动一个 .ps1 文件，不碰驱动/ESP/固件）
# 用法：把这个文件放在 40hx-oneclick-2026093xx 包目录里，右键“使用 PowerShell 运行”，或用同目录的 .cmd
$ErrorActionPreference = 'Continue'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$src  = Join-Path $here 'payload\windows\40hx-retrain-inpout.ps1'
$dst  = "$env:ProgramData\CMP40HXGen2\windows\40hx-retrain-inpout.ps1"
$log  = "$env:ProgramData\CMP40HXGen2\windows\logs\retrain-inpout.log"
$want = 'd4261d3db1e974c60cb22f3d7fce849cbbafa9f654a40377dd5a8f037ed49372'   # 新版工具的 sha256（用于自证拷对了）

function Line { param([string]$s) Write-Host $s }
Line '=============================================================='
Line ' 就地更新 Gen2 工具并立刻跑一次（不重启、不动 ESP/固件/驱动）'
Line '=============================================================='
if (-not (Test-Path $src)) { Line ('[X] 找不到新版工具: ' + $src); Line '  请确认本文件就在包目录里（和 Install-40HXUnlock.ps1 同一层）'; exit 1 }
$srcSha = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLower()
Line ('包内工具 sha256 : ' + $srcSha)
if ($srcSha -ne $want) { Line ('[X] 包内工具不是这一版（期望 ' + $want + '）—— 包里少文件或被改过，重新解压一份'); exit 1 }
Line '  [OK] 包内工具版本正确'
$curSha = ''
if (Test-Path $dst) { $curSha = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower() }
Line ('机器上现有工具  : ' + $(if ($curSha) { $curSha } else { '（不存在）' }))
if ($curSha -eq $want) { Line '  -> 已经是同一版，跳过拷贝' } else {
  Copy-Item -LiteralPath $src -Destination $dst -Force
  $newSha = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower()
  Line ('更新后          : ' + $newSha)
  if ($newSha -ne $want) { Line '[X] 拷贝后哈希不对，请手工覆盖一次'; exit 1 }
  Line '  [OK] 工具已更新（这台机器上原来的还是旧版：只认 .04 基线，所以一直 GUARD = FAIL）'
}
Line ''
Line '---- 现在跑一次（-Apply，会写 Gen2 目标值 + 重训；ACE-BOOT 全程不停）----'
$st = (sc.exe query WinRing0_1_2_0 2>&1 | Out-String)
Line ('运行前 WinRing0 状态: ' + [regex]::Match($st, 'STATE\s*:\s*\d+\s+\S+').Value)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dst -Apply
Line ('运行后返回码: ' + $LASTEXITCODE + '   （0=Gen2 到位；10=链路没到 Gen2；11=基线不认识（理论不该再出现）；3=WinRing0 起不来；12=驱动没就绪）')
Line ''
Line '---- 这次运行的关键行 ----'
if (Test-Path $log) {
  $tail = Get-Content -LiteralPath $log -Encoding UTF8 | Select-Object -Last 60
  @($tail | Where-Object { $_ -match 'vbios/driver|start type|detect:|using GPU|ready=|BAR0 \(validated\)|BOOT0 |LINK_CONFIG_0 = |PRIV_MISC_1   = |SS0 |GUARD|plan  :|writeOk|readback|already at target|SET_ONLY|final|cleanup|FATAL|PASS|EXIT' }) | ForEach-Object { Line ('   ' + $_.Trim()) }
} else { Line '   (没找到日志文件)' }
Line ''
Line '---- 这次之后的链路速率（参考）----'
$smi = "$env:SystemRoot\System32\nvidia-smi.exe"
if (Test-Path $smi) { & $smi --query-gpu=pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current --format=csv,noheader }
Line ''
Line '【怎么看结果】日志里要看到（这台卡的期望值）：'
Line '   GUARD = PASS'
Line '   plan  : LINK_CONFIG_0 0x800C5800 -> 0x80085800 (Gen2 bit18=0)   PRIV_MISC_1 0xE0B40500 -> 0xE0B42500 (Gen2 bit13=1)'
Line '   LINK_CONFIG_0 … writeOk=True  readback=0x80085800'
Line '   PRIV_MISC_1   0xE0B40500 -> 0xE0B42500  writeOk=True  readback=0xE0B42500'
Line '   GPU final : Gen2 x16 … / ROOT final: Gen2 x16 …'
Line '【若 WinRing0 起不来（返回码 3 / 一直 STOP_PENDING）】完全关机再开机一次，再跑本脚本即可。'
Line ''
Line '请把上面整屏输出 + retrain-inpout.log 发回来。'
