# ============================================================
#  40HX 一键修复 Gen2（双击 一键修复Gen2.cmd 即可，不需要输任何命令）
#  做四件事：
#   1) 把新版 Gen2 工具就地更新到 C:\ProgramData\CMP40HXGen2\windows（按哈希比对，一样就跳过）
#   2) 跑一次：只读体检 → 写 LINK_CONFIG_0 / PRIV_MISC_1 → 根端口重训 x2 → GPU 侧兜底重训 x2 → 复读校验
#      注意：**不会**自动补写“解锁固件该预埋的 Gen2 前提值”（要显式 -AllowPrime，见 工具-测试与修复\补写Gen2预埋.cmd）
#   3) 把关键结果 + 完整日志复制到桌面，方便直接发回
#   4) 屏幕上给出结论（成功/失败 + 下一步）
#  全程不停 ACE-BOOT、不复位显卡、不写 ESP/固件。
# ============================================================
$ErrorActionPreference = 'Continue'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# ---- 自己提权（双击 .ps1 或 .cmd 都能用，不需要用户输任何命令）----
$__adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $__adm) {
  $__self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
  Write-Host '需要管理员权限，正在自动提权（如果弹出“用户帐户控制”，请点“是”）...' -ForegroundColor Yellow
  try {
    # 2026-10-01b（第三方审查 H4）：等待提权进程结束并把退出码原样传出去；UAC 被取消要报错
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $__self + '"')) -Verb RunAs -Wait -PassThru -ErrorAction Stop
    exit $p.ExitCode
  } catch {
    Write-Host ('自动提权失败/被取消：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '请右键本文件 → 使用 PowerShell 运行（或右键 一键修复Gen2.cmd → 以管理员身份运行）。按回车退出。'
    Read-Host | Out-Null
    exit 1
  }
}
$src  = Join-Path $here 'payload\windows\40hx-retrain-inpout.ps1'
$dst  = "$env:ProgramData\CMP40HXGen2\windows\40hx-retrain-inpout.ps1"
# 2026-10-02：新工具把完整读数写 retrain-last.log（每次覆盖，不再无限增长）；老机器上可能还有老的追加日志
$rlog = "$env:ProgramData\CMP40HXGen2\windows\logs\retrain-last.log"
$rlogOld = "$env:ProgramData\CMP40HXGen2\windows\logs\retrain-inpout.log"
$wantVer = '20261004e'  # 必须与 payload 里工具的 TOOL_VER 一致（工具版本门禁 20261004d：LC0 族掩码放宽 + ROOT LNKCAP 读数 + PRIMER_GAPS 标记）
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk) { $desk = 'C:\Users\Public\Desktop' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sum = Join-Path $desk ('40HX-Gen2修复结果-' + $stamp + '.txt')
$fail = 0
$out = New-Object System.Collections.ArrayList
function T { param([string]$t, [string]$c = 'Gray') Write-Host $t -ForegroundColor $c; [void]$out.Add($t) }

T '============================================================' 'Cyan'
T '  40HX 一键修复 PCIe Gen2 （全自动，不需要输命令）' 'Cyan'
T '============================================================' 'Cyan'
T ''
T ('时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
T ('包目录: ' + $here)

# ---------- 0) 环境 ----------
T ''
T '[0/4] 环境检查' 'Cyan'
$adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
T ('  管理员权限   : ' + $adm)
if (-not $adm) { T '  [X] 请右键本脚本 → 以管理员身份运行（或直接双击 一键修复Gen2.cmd，它会自己提权）' 'Red'; $fail++ }
$smi = "$env:SystemRoot\System32\nvidia-smi.exe"
if (Test-Path $smi) { T ('  显卡/驱动    : ' + ((& $smi --query-gpu=name,vbios_version,driver_version --format=csv,noheader 2>&1 | Out-String).Trim())) } else { T '  [X] 找不到 nvidia-smi（驱动没装好？）' 'Red'; $fail++ }
if (Test-Path $src) { T '  包内新工具   : 找到' } else { T ('  [X] 包内缺少 payload\windows\40hx-retrain-inpout.ps1（本文件要放在包目录里跑）: ' + $src) 'Red'; $fail++ }
if ($fail -gt 0) { T ''; T '前置条件不满足，先解决上面的 [X] 再跑。' 'Red'; $out | Out-File -Encoding utf8 $sum; Write-Host ('结果已存: ' + $sum); exit 1 }

# ---------- 1) 更新工具 ----------
T ''
T '[1/4] 就地更新 Gen2 工具' 'Cyan'
$srcSha = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLower()
if (-not (Select-String -LiteralPath $src -Pattern ('TOOL_VER = ' + [char]39 + $wantVer + [char]39) -Quiet)) { T ('  [X] 包内工具不是这一版（应含 TOOL_VER = ' + $wantVer + '）—— 重新解压一份包') 'Red'; $out | Out-File -Encoding utf8 $sum; exit 1 }
T ('  包内工具 sha256 : ' + $srcSha)
$curSha = ''
if (Test-Path $dst) { $curSha = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower() }
T ('  机器上现有      : ' + $(if ($curSha) { $curSha } else { '（不存在）' }))
if ($curSha -eq $srcSha) { T '  -> 哈希一致，跳过拷贝' }
else {
  Copy-Item -LiteralPath $src -Destination $dst -Force
  $newSha = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower()
  T ('  更新后          : ' + $newSha)
  if ($newSha -ne $srcSha) { T '  [X] 拷贝后哈希不一致（被杀软拦了？）' 'Red'; $out | Out-File -Encoding utf8 $sum; exit 1 }
  T '  [OK] 工具已更新' 'Green'
}

# ---------- 2) 跑一次 ----------
T ''
T '[2/4] 现在跑一次（体检 + 写策略寄存器 + 重训；不会补写 GPU 内部预埋寄存器）' 'Cyan'
T '  （ACE-BOOT 全程不停；显卡不会被复位，显存/算力不受影响；不写 GPU 内部预埋寄存器）'
$st = (sc.exe query WinRing0_1_2_0 2>&1 | Out-String)
T ('  运行前 WinRing0 状态: ' + ([regex]::Match($st, 'STATE\s*:\s*\d+\s+\S+').Value))
T '  （下面会实时刷日志；最多 2~3 分钟。若超过 3 分钟一行都不动，按 Ctrl+C 关掉，然后完全关机再开机再来一次）'
T '  提示：驱动那几步在“等驱动落定/重试”时会有 10~20 秒一行都不动，那是正常的，别关窗口。' 'Gray'
T '        日志里出现「复用已在运行的实例」= 机器上本来就有一份同款驱动，工具直接拿它用（更省事，不是报错）。' 'Gray'
$rawLog = Join-Path $env:TEMP ('40hx-gen2-run-' + $stamp + '.txt')
# 2026-10-05（审查 M2）：先删掉旧文件 → 跑完若文件不存在或没有工具 banner，就说明"工具这次根本没跑起来"，
#   绝不能用 $LASTEXITCODE 的残留 0 + 上次的 retrain-last.log 里的 PASS 报成功（那是假成功）。
if (Test-Path $rawLog) { Remove-Item -LiteralPath $rawLog -Force -ErrorAction SilentlyContinue }
# 用 Tee 边跑边显示：旧写法把子进程输出全缓冲了，客户会以为卡死
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dst -Apply 2>&1 | Tee-Object -FilePath $rawLog | ForEach-Object {
  Write-Host $_
  [void]$out.Add([string]$_)
}
$rc = $LASTEXITCODE
$runOut = if (Test-Path $rawLog) { (Get-Content -LiteralPath $rawLog -Raw -ErrorAction SilentlyContinue) } else { '' }
$ranThisRound = (($runOut -match '====\s+40HX Gen2 retrain') -and ($runOut.Length -gt 200))
if (-not $ranThisRound) { T '  [X] 工具这次没有真正跑起来（控制台没有它的输出）—— 通常是杀软拦了 powershell/脚本，或包不完整；本次不算成功。' 'Red' }
T ('  工具返回码: ' + $rc + '   （0=Gen2 到位  10=链路没到 Gen2  11=基线不认识  3=WinRing0 起不来  12=驱动没就绪  13=inpoutx64 驱动没加载起来）')

# ---------- 3) 汇总 ----------
T ''
T '[3/4] 结果汇总' 'Cyan'
$keys = @()
if (-not (Test-Path $rlog) -and (Test-Path $rlogOld)) { $rlog = $rlogOld }   # 老机器兜底
if (Test-Path $rlog) {
  $tail = @(Get-Content -LiteralPath $rlog -Encoding UTF8)
  # 只取最后一次运行的块
  $idx = -1
  for ($i = $tail.Count - 1; $i -ge 0; $i--) { if ($tail[$i] -match '====\s+40HX Gen2 retrain') { $idx = $i; break } }
  if ($idx -ge 0) { $keys = $tail[$idx..($tail.Count - 1)] }
}
$show = @($keys | Where-Object { $_ -match 'ver=|vbios/driver|guard 全量体检|XVE_OVR|CYA_0|PL_LINK_RATE|VSEC_DEVICE|SS1 |GPU LNKCAP|TLS\(LNKCTL2\)|体检缺口|自动补写|已补|-> 0x|GUARD|plan  :|pre   :|already at target|writeOk|ROOT[12] SET_ONLY|GPU[12] SET_ONLY|post  :|重训后|final|cleanup|PASS|FAIL|EXIT' })
foreach ($l in $show) { Write-Host ('   ' + $l.Trim()); [void]$out.Add('   ' + $l.Trim()) }
# 2026-10-01b（审查 H3）：工具的幂等输出是 "PASS: already physical Gen2 x16; no writes needed."，
#   只认旧文案会把"已经到位"误报成失败。
# 2026-10-02（第三方审查 H + 本机实测踩到）：**必须同时**认工具退出码与日志 PASS。
#   只认日志会读到"上一次运行留下的 PASS"（工具这次根本没写成/写了一半就退）→ 报假成功。
#   工具语义：退出码 0 = 本次已验证 Gen2 到位（含幂等 already），非 0 一律不算成功。
# 2026-10-05（审查 M2/L6）：判据改成"本次输出文件"里的 banner + PASS + 退出码三者同时成立，
#   不再用 $keys（它可能来自上次运行留下的 retrain-last.log，或被日志瘦身影响）。
$gen2ok = ($ranThisRound -and ($rc -eq 0) -and ($runOut -match 'PASS:\s*(already\s+)?physical Gen2 x16'))
if (-not $gen2ok) { T ('  判定依据: 工具返回码=' + $rc + $(if ($rc -ne 0) { '（非 0 = 本次没成功，不看日志里的历史 PASS）' } else { '' })) 'Yellow' }
$gapLine = @($keys | Where-Object { $_ -match '体检缺口' }) | Select-Object -First 1
if ($gapLine) {
  T ('  ' + $gapLine.Trim()) 'Yellow'
  # 2026-10-05（客户机实测）：缺口 = 解锁固件（EFI）该预埋的 Gen2 前提值没写进去；
  #   这台机器上再跑多少次本工具都到不了 Gen2，必须补写（显式 -AllowPrime）或让 EFI 重跑预埋。
  if ($gapLine -notmatch '（无') {
    T '  >>> 这台机器的 Gen2 前提值没被解锁固件预埋（缺口见上）—— 再跑本工具也不会到 Gen2。' 'Yellow'
    T '      下一步（二选一）：' 'Yellow'
    T '       ① 重跑 一键安装.cmd 让解锁固件在 EFI 阶段重新预埋 → 完全关机再开机 → 再跑本工具；' 'Yellow'
    T '       ② 若开机后缺口还在（固件自己 abort / 换了平台批次）→ 双击 工具-测试与修复\补写Gen2预埋.cmd（先把原值落盘再补写）。' 'Yellow'
  }
}

T ''
T '  当前链路（nvidia-smi 报告值；这类解锁卡常把 current 报成 1，别被它吓到 —— 以工具日志里的 pre/final 寄存器实测为准）:'
if (Test-Path $smi) { $ls = (& $smi --query-gpu=pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current --format=csv,noheader 2>&1 | Out-String).Trim(); T ('    ' + $ls); [void]$out.Add('    ' + $ls) }

# ---------- 4) 结论 + 桌面留档 ----------
T ''
T '[4/4] 结论' 'Cyan'
if ($gen2ok) {
  T '  [OK] 这次 Gen2 已经到位（日志里有 PASS: physical Gen2 x16）' 'Green'
  T '  下一步：完全关机再开机（开始菜单→关机，最好拔电 10 秒）固化状态；' 'Green'
  T '          开机后双击 状态自检.bat，看到“全绿 -- WDDM + PCIe Gen2 + 算力满血”即完成。' 'Green'
} else {
  T '  [!!] 这次没能升到 Gen2（详见下面的日志关键行）' 'Yellow'
  if ($rc -eq 3) {
    T '  原因：WinRing0 用不了（驱动文件被杀软/“易受攻击驱动”策略清理，或服务卡在 STOP_PENDING）' 'Yellow'
    T '        本版工具会自动回落到 ECAM（不需要 WinRing0）；两条路都不可用时日志里会有一行 backend: ...' 'Yellow'
  }
  if ($rc -eq 13) {
    T '  原因：inpoutx64 驱动（新路径用来写显卡寄存器的那一个）这次没能加载起来。' 'Yellow'
    T '        新版工具对常见的三种情况会自己处理：① 机器上已经有一份同款实例 → 直接复用（日志里是「复用已在运行的实例」）' 'Yellow'
    T '        ② 上一次没卸干净（STOP_PENDING）→ 自动等它落定再重试  ③ 真被拦 → 日志末尾会打印「驱动加载失败现场」' 'Yellow'
    T '  怎么处理（按顺序）：' 'Yellow'
    T '   1) 看桌面 retrain-last.log 里那行“inpoutx64T start try … : [SC] StartService 失败 N”：' 'Yellow'
    T '        577 = 签名/内核隔离（内存完整性）拦 → 关掉“内核隔离”后【完全关机】再开机；' 'Yellow'
    T '        5   = 杀软主动拦 → 把 C:\Windows\System32\drivers\inpoutx64.sys、inpoutx64.dll，' 'Yellow'
    T '              以及 C:\ProgramData\CMP40HXGen2、C:\ProgramData\40HXUnlock 两个目录加进杀软信任区；' 'Yellow'
    T '        183 = 已有同款实例（新版会自动复用；若还报这个，完全关机再开机）；' 'Yellow'
    T '        2   = 驱动文件被杀软删了 → 用包里的“一键安装.cmd -Mode Repair”补文件。' 'Yellow'
    T '   2) 完全关机再开机（不是重启），再双击本文件跑一次；' 'Yellow'
    T '   3) 还不行：把 40HX-Gen2修复结果-*.txt + 桌面 retrain-last.log 一起发回（末尾“驱动加载失败现场”里有事件日志/杀软/文件哈希）。' 'Yellow'
  }
  T '  下一步（按顺序，不用输命令）：' 'Yellow'
  T '   a) 完全关机再开机一次（开始菜单→关机，不是重启！这一步就是为了清掉 WinRing0 停在 STOP_PENDING 的残留），再双击本文件跑一次；' 'Yellow'
  T '   b) 若还是失败：把桌面上的这两个文件发回来 —— 40HX-Gen2修复结果-*.txt 和 retrain 完整日志' 'Yellow'
}
# 日志与汇总落盘到桌面
try {
  if (Test-Path $rlog) { Copy-Item -LiteralPath $rlog -Destination (Join-Path $desk 'retrain-last.log') -Force }
  T ''
  T ('  汇总已存: ' + $sum) 'Cyan'
  T '  （桌面上还会有 retrain-last.log 完整日志）' 'Cyan'
} catch { T ('  [!!] 写桌面失败: ' + $_.Exception.Message) 'Yellow' }
$out | Out-File -Encoding utf8 $sum
# 2026-10-02（第三方审查 H）：没修好必须以**非 0**退出 —— 否则 .cmd 会打印 [OK] 修复脚本跑完了（退出码 0），
#   客户会以为修好了（工具返回 10/11/12/13/3 时以前就是这么骗人的）。
if (-not $gen2ok) {
  Write-Host ''
  Write-Host '没修好：退出码 = 1（上面是失败原因）' -ForegroundColor Yellow
  exit 1
}
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
