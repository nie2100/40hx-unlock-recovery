# ============================================================
#  安全模式下修复“开机就蓝屏”（只做三件事：改名工具 / 删开机任务 / 清残留服务）
#  用法：在**安全模式**里双击 安全模式-修复.cmd
#  原理：2026-09-30 的事故是——早期版本把带“盲扫物理地址”的工具装进了
#        C:\ProgramData\CMP40HXGen2\windows，而开机任务 CMP40HX Gen2 PostBind 每次开机都去跑它
#        → 每次开机触发平台致命错误(WHEA_UNCORRECTABLE_ERROR)。
#        安全模式不跑这类开机任务，所以安全模式能进 —— 本脚本就是把那个工具和任务拿掉。
# ============================================================
$ErrorActionPreference='Continue'
$desk=[Environment]::GetFolderPath('Desktop'); if(-not $desk){ $desk='C:\Users\Public\Desktop' }
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$out=Join-Path $desk ('40HX-安全模式修复-' + $stamp + '.txt')
$sb=New-Object System.Text.StringBuilder
function W { param([string]$s='') Write-Host $s; [void]$sb.AppendLine($s) }
$win='C:\ProgramData\CMP40HXGen2\windows'
W '============================================================'
W ' 安全模式修复：让“开机不再跑带盲扫的工具”'
W (' 时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  机器: ' + $env:COMPUTERNAME)
W '============================================================'
W ''
W '==== 1) 把会引发问题的脚本改名（.bad 后缀 = 失效但保留证据）===='
$names=@('40hx-retrain-inpout.ps1','RunPostBind.cmd','AutoRetrain.cmd','Status.cmd')
if(Test-Path $win){
  foreach($n in $names){
    $p=Join-Path $win $n
    if(Test-Path $p){
      try { Rename-Item -LiteralPath $p -NewName ($n + '.bad') -Force -ErrorAction Stop; W ('  [OK] 改名: ' + $p + ' -> ' + $n + '.bad') }
      catch { W ('  [X] 改名失败 ' + $p + ': ' + $_.Exception.Message) }
    } else { W ('  - 不存在（跳过）: ' + $p) }
  }
  # 顺带把整个目录打个清单，方便事后核对
  W '  --- 目录现状 ---'
  try { foreach($f in @(Get-ChildItem $win -File -ErrorAction SilentlyContinue)){ W ('    ' + $f.Name + '  ' + $f.Length + ' B') } } catch {}
} else { W ('  [X] 目录不存在: ' + $win + '（说明本机没装过我们的开机任务）') }
W ''
W '==== 2) 删除开机任务 ===='
$tasks=@()
try { $tasks=@(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'CMP40HX|40HX' }) } catch {}
if($tasks.Count -gt 0){
  foreach($t in $tasks){
    W ('  找到任务: ' + $t.TaskName + '  状态=' + $t.State + '  路径=' + $t.TaskPath)
    try { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop; W '  [OK] 已删除' }
    catch { W ('  [X] 删除失败（任务计划服务可能没在安全模式启动）: ' + $_.Exception.Message); W '      → 第 1 步已改掉工具名，任务跑起来也找不到脚本，同样不再蓝屏' }
  }
} else {
  W '  没有找到相关任务（或任务计划服务未启动）。第 1 步已足够。'
  W '  可稍后在正常系统里用 任务计划程序(taskschd.msc) 找 CMP40HX 相关项删除。'
}
W ''
W '==== 3) 清掉工具留下的临时服务（不影响解锁）===='
foreach($svc in @('inpoutx64T','WinRing0_1_2_1')){
  $q=(sc.exe query $svc 2>&1 | Out-String)
  if($q -match 'SERVICE_NAME'){ sc.exe stop $svc 2>&1 | Out-Null; Start-Sleep -Milliseconds 500; sc.exe delete $svc 2>&1 | Out-Null; W ('  [OK] 已删除服务 ' + $svc) }
  else { W ('  - 服务不存在（跳过）: ' + $svc) }
}
$wr=(sc.exe query WinRing0_1_2_0 2>&1 | Out-String)
if($wr -match 'SERVICE_NAME'){
  sc.exe config WinRing0_1_2_0 start= demand 2>&1 | Out-Null
  W '  - WinRing0_1_2_0 保留（启动类型设为 demand，不会开机自动加载）'
}
W ''
W '==== 4) 解锁状态检查（跟本问题无关，仅确认没被影响）===='
$esp=''
try { $esp = (Get-CimInstance -ClassName Win32_Volume -Filter 'Label="ESP"' -ErrorAction SilentlyContinue | Select-Object -First 1) } catch {}
W '  算力解锁由 ESP 上的解锁固件在开机时完成，本次修复**没有改动** ESP/固件/显存，也不会影响它。'
W ''
W '==== 下一步 ===='
W '  1) 直接正常重启（不是安全模式）→ 现在应该能正常进系统'
W '  2) 进系统后先双击 i 包里的 收集蓝屏证据.cmd，把桌面报告发回来（留证据）'
W '  3) 再决定要不要用 i 包重新部署（i 版工具已删除盲扫 + 加物理地址硬护栏）'
W ''
W ('结果已存: ' + $out)
$sb.ToString() | Out-File -Encoding utf8 $out
