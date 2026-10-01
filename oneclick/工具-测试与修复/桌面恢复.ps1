# ============================================================
#  外壳（桌面/explorer）恢复 + 诊断 —— 桌面没加载时用
#  用法（桌面不可用时）：任务管理器 → 文件 → 运行新任务 → 浏览到本脚本 → 勾选"以系统管理权限创建"
#   桌面恢复.cmd                → 只读诊断（并尝试把 explorer 拉起来）
#   桌面恢复.cmd /fix           → 修复：拉起 explorer + 修正 Winlogon Shell + 必要时重启 ACE 组件
#   桌面恢复.cmd /disableace    → 临时停用腾讯 ACE（拿回桌面最有效的一招；之后在游戏里"修复"即可恢复）
#   桌面恢复.cmd /restoreautorun→ 还原我们清理掉的 Run 自启项（万一删错）
#  报告同时写到 桌面 + C:\40HX-外壳诊断-*.txt（桌面出不来时就去 C 盘根找）
# ============================================================
param([switch]$Fix, [switch]$DisableAce, [switch]$RestoreAutorun)
$ErrorActionPreference='Continue'
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
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sb = New-Object System.Text.StringBuilder
function W  { param([string]$s='') [void]$sb.AppendLine($s) }
function WB { param([string]$s='') Write-Host $s; [void]$sb.AppendLine($s) }
function Save {
  $txt = $sb.ToString()
  foreach($p in @("C:\40HX-外壳诊断-$stamp.txt", (Join-Path ([Environment]::GetFolderPath('Desktop')) "40HX-外壳诊断-$stamp.txt"))){
    try { $txt | Out-File -Encoding utf8 $p } catch {}
  }
}
function Is-Admin { $id=[Security.Principal.WindowsIdentity]::GetCurrent(); (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Get-SvcByPath {
  param([string]$Pattern)
  $out=@()
  foreach($k in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)){
    try { $ip=(Get-ItemProperty -LiteralPath $k.PSPath -Name ImagePath -ErrorAction Stop).ImagePath
      if('' + $ip -match $Pattern){ $pr=Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        $out += [pscustomobject]@{ Name=$k.PSChildName; ImagePath=$ip; Start=$pr.Start } } } catch {}
  }
  ,@($out)
}

WB '============================================================'
WB ' 40HX：桌面/外壳（explorer）恢复 + 诊断'
WB (' 时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   机器: ' + $env:COMPUTERNAME + '   管理员: ' + (Is-Admin))
WB '============================================================'
WB ''

WB '==== 1) 外壳（explorer）现状 ===='
$exp = @(Get-Process explorer -ErrorAction SilentlyContinue)
if($exp.Count -eq 0){ WB '  ★ 没有 explorer.exe 进程 —— 这就是"桌面没加载"的直接原因' }
else { foreach($e in $exp){ WB ('  explorer.exe PID=' + $e.Id + '  启动于 ' + $e.StartTime) } }
$sh = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue)
WB ('  Winlogon Shell    = [' + $sh.Shell + ']      （必须是 explorer.exe）')
WB ('  Winlogon Userinit = [' + $sh.Userinit + ']')
if($sh.Shell -and $sh.Shell -notmatch 'explorer\.exe'){ WB '  ★ Shell 值异常 —— 这是桌面不加载的经典原因，用 /fix 修' }
WB ''

WB '==== 2) 腾讯 ACE 组件现状 ===='
$ace = @(Get-SvcByPath 'AntiCheatExpert|ACE-BOOT|ACE-GAME|SGuard|ACE-Core|ACE-CORE|ACE-SSC')
if($ace.Count -eq 0){ WB '  （注册表里没找到 ACE 服务）' }
else { foreach($a in $ace){ WB ('  ' + $a.Name + '  Start=' + $a.Start + '  → ' + $a.ImagePath) } }
$aceBoot=(sc.exe query ACE-BOOT 2>&1 | Out-String)
WB ('  ACE-BOOT: ' + (([regex]::Match($aceBoot,'STATE\s*:\s*\d+\s+\S+').Value)))
$trays=@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(ACE-Tray|ACE-ADVT|SGuard|AntiCheat)' })
WB ('  ACE 托盘进程: ' + $trays.Count + $(if($trays.Count){'  (' + (($trays | ForEach-Object { $_.ProcessName + '#' + $_.Id }) -join ', ') + ')'}else{''}))
WB ''

WB '==== 3) 我们改过的东西（可回滚点）===='
$bkLogs = @(Get-ChildItem "$env:ProgramData\CMP40HXGen2\windows\logs" -Filter 'autostart-removed-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if($bkLogs.Count -eq 0){ WB '  没有清理过 Run 自启项的记录' }
else { foreach($b in $bkLogs){ WB ('  自启项留档: ' + $b.FullName); (Get-Content $b.FullName -Encoding UTF8) | ForEach-Object { WB ('    ' + $_) } } }
$dd = "$env:ProgramData\CMP40HXGen2\drivers-disabled"
if(Test-Path $dd){ WB ('  ThrottleStop 备份目录: ' + $dd); Get-ChildItem $dd -Recurse -File | ForEach-Object { WB ('    ' + $_.FullName) } }
else { WB '  （没有 drivers-disabled 备份目录）' }
$pb = "$env:ProgramData\CMP40HXGen2\windows\logs\postbind.log"
if(Test-Path $pb){ WB '  最近一次开机任务日志（末尾 12 行）:'; Get-Content $pb -Tail 12 -Encoding UTF8 | ForEach-Object { WB ('    ' + ($_ -replace '\s+',' ').Trim()) } }
WB ''

WB '==== 4) 相关事件（近 1 天 explorer/ACE/服务崩溃）===='
$found=0
try {
  $ev = @(Get-WinEvent -FilterHashtable @{LogName=@('System','Application'); StartTime=(Get-Date).AddDays(-1)} -MaxEvents 400 -ErrorAction SilentlyContinue)
  foreach($e in $ev){
    $m='' + $e.Message
    if($e.ProviderName -match 'Application Error|Application Hang|AntiCheat|ACE|SGuard' -or $m -match 'explorer\.exe|AntiCheat|ACE-'){
      $found++
      if($found -le 20){ WB ('  [' + $e.TimeCreated.ToString('MM-dd HH:mm:ss') + '] ' + $e.LevelDisplayName + ' ' + $e.ProviderName + ' ID=' + $e.Id + ' :: ' + (($m -replace '\s+',' ').Trim().Substring(0,[Math]::Min(150,($m -replace '\s+',' ').Trim().Length)))) }
    }
  }
} catch { WB ('  读取失败: ' + $_.Exception.Message) }
if($found -eq 0){ WB '  （没有相关事件）' } else { WB ('  共 ' + $found + ' 条') }
WB ''

# ---------------- 动作 ----------------
if($RestoreAutorun){
  WB '==== 5) 还原被清理的 Run 自启项 ===='
  if($bkLogs.Count -eq 0){ WB '  没有留档可还原' }
  elseif(-not (Is-Admin)){ WB '  [X] 需要管理员（HKLM 项）' }
  else {
    foreach($b in $bkLogs){
      foreach($line in @(Get-Content $b.FullName -Encoding UTF8)){
        $mm=[regex]::Match($line,'^(HKCU|HKLM):\\(.+?) \| ([^=]+) = (.*)$')
        if($mm.Success){
          $root=if($mm.Groups[1].Value -eq 'HKCU'){'HKCU:'}else{'HKLM:'}
          $path=$root + '\' + $mm.Groups[2].Value
          try { Set-ItemProperty -LiteralPath $path -Name $mm.Groups[3].Value.Trim() -Value $mm.Groups[4].Value -ErrorAction Stop; WB ('  已还原: ' + $path + ' → ' + $mm.Groups[3].Value) } catch { WB ('  [X] 还原失败: ' + $line) }
        }
      }
    }
  }
  WB ''
}

if($DisableAce){
  WB '==== 临时停用腾讯 ACE（拿回桌面）===='
  if(-not (Is-Admin)){ WB '  [X] 需要管理员' }
  else {
    foreach($n in @('ACE-BOOT')){
      & sc.exe config $n start= disabled 2>&1 | ForEach-Object { WB ('  ' + $_) }
      & sc.exe stop $n 2>&1 | ForEach-Object { WB ('  ' + $_) }
    }
    foreach($t in @(Get-Process ACE-Tray,ACE-ADVT,SGuard -ErrorAction SilentlyContinue)){ try { Stop-Process -Id $t.Id -Force -ErrorAction Stop; WB ('  已结束 ' + $t.ProcessName + ' PID=' + $t.Id) } catch {} }
    WB '  → 之后请在游戏客户端里点「修复 / 重新安装」让游戏重新部署 ACE（或让 ACE 安装器自修）'
  }
  WB ''
}

if($Fix){
  WB '==== 修复动作 ===='
  if(-not (Is-Admin)){
    WB '  需要管理员 → 正在请求提权（会弹 UAC，请点“是”）...'
    Save
    try { Start-Process powershell -Verb RunAs -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Fix'); WB '  提权窗口已结束' } catch { WB ('  [X] 提权失败: ' + $_.Exception.Message) }
    Save; exit 0
  }
  # 4.1 Winlogon Shell
  if($sh.Shell -and $sh.Shell -notmatch 'explorer\.exe'){
    try { Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name Shell -Value 'explorer.exe' -ErrorAction Stop; WB '  [OK] 已把 Winlogon Shell 改回 explorer.exe' } catch { WB ('  [X] Shell 修正失败: ' + $_.Exception.Message) }
  } else { WB '  Winlogon Shell 正常，无需修改' }
  # 4.2 拉起 explorer
  if(@(Get-Process explorer -ErrorAction SilentlyContinue).Count -eq 0){
    try { Start-Process explorer.exe; WB '  已尝试启动 explorer.exe（若仍无桌面，见下一条）' } catch { WB ('  [X] 启动 explorer 失败: ' + $_.Exception.Message) }
  } else { WB '  explorer 已在运行' }
  # 4.3 ACE 组件若没在跑，拉起来（ACE-BOOT 状态错位时 shell 可能被拖住）
  foreach($n in @('ACE-BOOT')){
    $q=(sc.exe query $n 2>&1 | Out-String)
    if($q -match 'STOPPED'){ & sc.exe start $n 2>&1 | ForEach-Object { WB ('  ' + $_) } }
  }
  WB '  建议：重启一次（第二次重启通常能让 ACE 预启动模式与用户态对齐）'
  WB '  若重启后仍无桌面：先跑 桌面恢复.cmd /disableace 拿回桌面，再在游戏客户端里修复 ACE'
}
WB ''
Save
WB ('报告已写: C:\40HX-外壳诊断-' + $stamp + '.txt  （以及桌面同名文件，若桌面可用）')
if(-not $env:NO_PAUSE){ if($Host.Name -eq 'ConsoleHost'){ Write-Host ''; Read-Host '按回车退出' } }
