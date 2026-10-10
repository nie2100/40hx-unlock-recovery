# ============================================================
#  判断 Gen2 上不去是不是延长线的问题（只读！不写任何寄存器/不改设置）
#  用法：双击 判断延长线.cmd，或直接跑本脚本
#  原理：把“延长线/信号完整性”与“寄存器/固件”两类原因用四条独立证据分开：
#    ① 链路速率（GPU/根端口寄存器的 Gen 位）② 数据链路层是否激活（LNKSTA bit13 DLLLA）
#    ③ PCIe 已更正/致命错误计数（WHEA-Logger 事件，按端口统计）④ 宽度是否为 x16
#  做法：**先带延长线跑一次**，再**把卡直插主板 x16 跑一次**，把两份报告对比即可定性。
# ============================================================
$ErrorActionPreference='Continue'
$desk=[Environment]::GetFolderPath('Desktop'); if(-not $desk){ $desk='C:\Users\Public\Desktop' }
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$out=Join-Path $desk ('40HX-延长线判定-' + $stamp + '.txt')
$sb=New-Object System.Text.StringBuilder
function W { param([string]$s='') [void]$sb.AppendLine($s) }
function WB { param([string]$s='') Write-Host $s; [void]$sb.AppendLine($s) }
$here = if($PSScriptRoot){ $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# 本脚本位于「工具-测试与修复\」下 → 向上找包根（内含 payload\windows 的那一层）
if(-not (Test-Path (Join-Path $here 'payload\windows'))){
  $p2 = $here
  for($i=0; $i -lt 3; $i++){
    $p2 = Split-Path -Parent $p2
    if(-not $p2){ break }
    if(Test-Path (Join-Path $p2 'payload\windows')){ $here = $p2; break }
  }
}
$tool = Join-Path $here 'payload\windows\40hx-retrain-inpout.ps1'

WB '============================================================'
WB ' 40HX：Gen2 上不去 —— 是不是延长线？（只读判定）'
WB (' 时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   机器: ' + $env:COMPUTERNAME)
WB '============================================================'
WB ''
WB '【怎么用】带延长线跑一次 → 把卡直插主板 x16 再跑一次 → 对比两份报告的 ①②③④ 四项。'
WB ''

# ---------- 基础信息 ----------
WB '==== 0) 显卡 / 驱动 ===='
$smi="$env:SystemRoot\System32\nvidia-smi.exe"
if(Test-Path $smi){
  W ('  ' + ((& $smi --query-gpu=name,vbios_version,driver_version,pci.bus_id --format=csv,noheader 2>&1 | Out-String).Trim()))
} else { W '  没有 nvidia-smi' }
try {
  foreach($d in @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match '40HX' })){
    W ('  设备: ' + $d.FriendlyName + '   状态=' + $d.Status + '   问题码=' + $d.Problem + '   实例=' + $d.InstanceId)
  }
} catch {}

# ---------- ① ② ④ 寄存器级（调用已验证的只读工具，不带 -Apply = 全程不写）----------
WB ''
WB '==== ① ② ④ 链路寄存器（只读）===='
$lines=@()
# 2026-10-01b（第三方审查）：只读工具要管理员才能加载驱动（非管理员会 exit 1/13），
#   以前只打印返回码就继续下结论 → 显式提示。
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  WB '  [!!] 当前不是管理员：下面的链路寄存器大概率读不到（工具返回码会非 0）。'
  WB '       请右键 → 以管理员身份运行 判断延长线.cmd，再跑一次。'
}
if(Test-Path $tool){
  WB '  （正在用只读模式跑一次链路读取，约 5~20 秒；它不会写任何寄存器）'
  $raw = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool 2>&1 | Out-String)
  $rc = $LASTEXITCODE
  $lines = @($raw -split "`r?`n")
  W ('  只读工具返回码: ' + $rc + '   （0=读取正常；3=WinRing0 起不来，寄存器读不到，请看下面第③项）')
  foreach($k in @('detect:','using GPU','PCIe cap','pre   :','GPU final','ROOT final','TLS\(LNKCTL2\)','GPU LNKCAP','体检缺口','GUARD','plan  :')){
    foreach($l in @($lines | Where-Object { $_ -match $k })){ W ('  ' + $l.Trim()) }
  }
  # 解读
  $pre = @($lines | Where-Object { $_ -match 'pre   :' }) | Select-Object -First 1
  if($pre){
    if($pre -match 'GPU LNKSTA=0x([0-9A-Fa-f]{4}).*?Gen(\d+) x(\d+).*?ROOT LNKSTA=0x([0-9A-Fa-f]{4}).*?Gen(\d+) x(\d+)'){
      $gSta=[convert]::ToInt32($matches[1],16); $gGen=[int]$matches[2]; $gW=[int]$matches[3]
      $rSta=[convert]::ToInt32($matches[4],16); $rGen=[int]$matches[5]; $rW=[int]$matches[6]
      W ''
      W '  --- 解读 ---'
      W ('  GPU  速率 Gen' + $gGen + ' / 宽度 x' + $gW + '；ROOT 速率 Gen' + $rGen + ' / 宽度 x' + $rW)
      # 判定只看**根端口**的 DLLLA(bit13)：Gen2 时代的老卡（如 TU106）在端点侧根本不实现这一位，恒为 0，
      # 拿它判“链路没好”会误报（本脚本第一版就这么错过一次，被本机满血机对照组抓到）
      $rDllla = if((($rSta -shr 13) -band 1) -eq 1){'1(已激活)'}else{'0(未激活!)'}
      W ('  根端口 DLLLA(bit13)= ' + $rDllla + '   期望 1；GPU 侧 bit13=' + $(if((($gSta -shr 13) -band 1) -eq 1){'1'}else{'0（老卡端点侧不实现此位，正常，忽略）'}))
      if((($rSta -shr 13) -band 1) -eq 0){
        W '  >>> 根端口 DLLLA=0 → 链路没完全训练好，这是**信号完整性不良（延长线/接触/供电）**的典型特征'
      }
      if((($gSta -shr 11) -band 1) -eq 1 -or (($rSta -shr 11) -band 1) -eq 1){ W '  >>> 有一端 Link Training(bit11) 仍在进行 → 链路刚刚/正在反复重训' }
      if((($gSta -shr 10) -band 1) -eq 1 -or (($rSta -shr 10) -band 1) -eq 1){ W '  >>> 出现 Link Training Error(bit10) → 训练失败过（信号质量问题实锤之一）' }
      if($gGen -lt 2 -or $rGen -lt 2){ W '  >>> 当前仍是 Gen1' } else { W '  >>> 当前已是 Gen2' }
      if($gW -ne 16 -or $rW -ne 16){ W ('  >>> 宽度不是 x16（当前 x' + $gW + '/x' + $rW + '）—— 也常见于延长线（尤其 x1/x4 转接）') }
    }
  }
} else { W ('  找不到只读工具: ' + $tool) }

# ---------- ③ AER/WHEA 错误计数（关键判据，纯读事件日志）----------
WB ''
WB '==== ③ PCIe 错误计数（WHEA-Logger 事件，按端口统计；这是最有力的判据）===='
try {
  $ev = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=(Get-Date).AddDays(-14)} -ErrorAction SilentlyContinue)
  if(-not $ev){ W '  最近 14 天没有 WHEA-Logger 事件（好事：说明没在报硬件错误）' }
  else {
    $stat=@{}
    foreach($e in $ev){
      $m = ($e.Message -replace "\s+",' ')
      $bdf = '未知'
      if($m -match '主总线:\s*设备:\s*函数:\s*(0x[0-9a-fA-F]+):\s*(0x[0-9a-fA-F]+):\s*(0x[0-9a-fA-F]+)'){ $bdf = $matches[1] + ':' + $matches[2] + ':' + $matches[3] }
      $comp = '未知'
      if($m -match '组件:\s*(.*?)\s*错误源:'){ $comp = $matches[1] }
      $key = $comp + '  端口 ' + $bdf
      if(-not $stat.ContainsKey($key)){ $stat[$key]=@{n=0; ids=@{}} }
      $stat[$key].n++
      if(-not $stat[$key].ids.ContainsKey($e.Id)){ $stat[$key].ids[$e.Id]=0 }
      $stat[$key].ids[$e.Id]++
    }
    foreach($k in ($stat.Keys | Sort-Object)){
      $ids = ($stat[$k].ids.GetEnumerator() | ForEach-Object { 'ID' + $_.Key + 'x' + $_.Value }) -join ' '
      W ('  ' + $k + '   共 ' + $stat[$k].n + ' 次   (' + $ids + ')')
    }
    W ''
    W ('  最近一条: ' + (@($ev | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')))
    W '  说明：ID17 = 已更正的硬件错误（可恢复，但数量持续增长 = 链路信号质量差）；ID1/18/19/20 = 更严重'
    $hit = @($stat.Keys | Where-Object { $_ -match '0x0:0x1:0x0' -or $_ -match '0x1:0x0:0x0' })
    if($hit.Count -gt 0){
      W '  >>> 有事件指向 40HX 所在端口（00:01.0）或显卡本身（01:00.0）→ **强烈指向延长线/链路信号完整性**'
    } else {
      W '  >>> 没有事件指向 40HX 的端口/显卡 → 链路本身没在报错，Gen2 上不去更可能是“寄存器/固件/预埋”那一类原因'
    }
  }
} catch { W ('  读取事件失败: ' + $_.Exception.Message) }

# ---------- 结论 ----------
WB ''
WB '==== ★ 重要：如果上面①的返回码=3（WinRing0 起不来）===='
WB '  那本判定**得不出结论** —— 因为在这台机器上 Gen2 从没被启用过（解锁固件的 Gen2 预埋没做），'
WB '  无论插不插延长线，链路都会停在 Gen1、带宽都会是 Gen1 量级。'
WB '  这时请改用下面两个“不需要本工具”的办法：'
WB '   A) 换一张普通显卡插同一条延长线：别的卡能稳定跑到它的最高速率 → 线基本没问题；别的卡也掉速/报错 → 线有问题'
WB '   B) 弄清 WinRing0 为什么起不来（见 排查指引/给客户的说明），解决了它，本判定才有效'
WB ''
WB '==== 结论怎么下（对比两次运行）===='
WB '  把“带延长线”和“直插主板”两份报告放一起看：'
WB '    A. 直插后 Gen2 落地（①/② 里 Gen=2 且 DLLLA=1），延长线时一直是 Gen1  → **定性：延长线（链路不支持 5GT/s）**'
WB '    B. 延长线时 ③ 里 40HX 端口有已更正错误且在增长，直插后为 0        → **同样是延长线**'
WB '    C. 直插后依然 Gen1、③ 里也没有错误                            → 不是线的问题，回到寄存器/固件/EFI 预埋那条线'
WB '    D. 两边宽度都不是 x16（x1/x4）                                 → 转接线类型不对（x1 矿卡转接），必须换 x16 线或直插'
WB ''
WB '  补充：带宽实测（状态自检.bat）也可以交叉验证一遍：Gen1 ≈ 3.1~3.4 GB/s，Gen2 ≈ 5.8~6.7 GB/s。'
WB ''
WB '  注意：不要为了“强行 Gen2”去反复跑写寄存器（-Apply）；延长线不达标时强行重训只会增加链路报错。'
WB ''
WB ('结果已存: ' + $out)
$sb.ToString() | Out-File -Encoding utf8 $out
WB '（把桌面这份报告发回来即可）'
