# ============================================================
#  用另一张显卡测延长线（只读）——  客户机箱塞不下 40HX 时用这个
#  用法：把 1060 装上延长线 → 双击本脚本 → 空载读一次；再跑 5~10 分钟游戏/烤机 → 再双击读一次
#  判据：满载时 1060 跑到 Gen3 x16（该主板插槽最高）且无 WHEA 报错 = 延长线没问题
# ============================================================
$ErrorActionPreference='Continue'
$desk=[Environment]::GetFolderPath('Desktop'); if(-not $desk){ $desk='C:\Users\Public\Desktop' }
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$out=Join-Path $desk ('延长线测试-别的显卡-' + $stamp + '.txt')
$sb=New-Object System.Text.StringBuilder
function W { param([string]$s='') Write-Host $s; [void]$sb.AppendLine($s) }
W '============================================================'
W ' 用另一张显卡测延长线（只读）'
W (' 时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   机器: ' + $env:COMPUTERNAME)
W '============================================================'
W ''
W '==== 0) 所有显示设备 ===='
try {
  foreach($d in @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' })){
    W ('  ' + $d.FriendlyName + '   状态=' + $d.Status + '   问题码=' + $d.Problem)
    W ('      位置: ' + ((Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data))
    W ('      实例: ' + $d.InstanceId)
  }
} catch { W ('  枚举失败: ' + $_.Exception.Message) }
W ''
W '==== 1) 显卡链路速率/宽度（nvidia-smi；普通卡这两个值可靠）===='
$smi="$env:SystemRoot\System32\nvidia-smi.exe"
if(Test-Path $smi){
  $q=(& $smi --query-gpu=name,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv 2>&1 | Out-String).Trim()
  W ('  ' + ($q -replace "\r?\n", "`n  "))
  W ''
  W '  代号含义: name,  pci.bus_id,  gen.current, gen.max,  width.current, width.max'
  W '  --- 判读 ---'
  $rows=@($q -split "`r?`n" | Where-Object { $_ -match ',' -and $_ -notmatch 'name,' })
  foreach($r in $rows){
    $f=$r -split ','
    if($f.Count -ge 6){
      $nm=$f[0].Trim(); $gc=$f[2].Trim(); $gm=$f[3].Trim(); $wc=$f[4].Trim(); $wm=$f[5].Trim()
      if($nm -match '1060|1050|1650|1660|2060|2070|2080|30[0-9]0|40[0-9]0'){
        W ('  [' + $nm + '] 当前 Gen' + $gc + ' / 最大 Gen' + $gm + '，宽度 x' + $wc + ' / 最大 x' + $wm)
        if([int]$gc -ge 3 -and [int]$wc -eq 16){ W '    >>> 这张普通卡跑到了 Gen3 x16 → **延长线本身没问题**（能承载 8GT/s）' }
        elseif([int]$gc -le 1 -or [int]$wc -lt 16){ W '    >>> 这张普通卡也只到 Gen' + $gc + ' / x' + $wc + ' → **延长线（或插槽/BIOS 设置）有问题**' }
      }
    }
  }
  W ''
  W '  注意：这里必须**在跑游戏/烤机等负载时**再测一次 —— GPU 空闲时链路会自己降到 Gen1（省电），空载读到的 Gen1 不代表解锁失败。'
} else { W '  没有 nvidia-smi（没装 NVIDIA 驱动？）' }
W ''
W '==== 2) PCIe 链路省电（ASPM）当前设置 ===='
try {
  $pq = (powercfg /q SCHEME_CURRENT SUB_PCIEXPRESS 2>&1 | Out-String)
  $m=[regex]::Matches($pq,'0x[0-9a-fA-F]{8}')
  if($m.Count -ge 1){ W ('  当前生效值(第一个 0x… 是交流电设置): ' + ($m | Select-Object -First 3 | ForEach-Object { $_.Value }) -join '  ') }
  W '  0=关闭省电（推荐，避免空闲降速误判） / 1=中等 / 2=最大省电'
  W '  想关掉（管理员 CMD）:'
  W '    powercfg -setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0'
  W '    powercfg -setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0'
  W '    powercfg -setactive SCHEME_CURRENT'
} catch { W ('  读取失败: ' + $_.Exception.Message) }
W ''
W '==== 3) PCIe 硬件错误计数（WHEA-Logger，14 天）===='
try {
  $ev = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=(Get-Date).AddDays(-14)} -ErrorAction SilentlyContinue)
  if(-not $ev){ W '  14 天内没有 WHEA 事件 → 链路没在报错（好）' }
  else {
    $stat=@{}
    foreach($e in $ev){
      $m=($e.Message -replace "\s+",' '); $bdf='未知'
      if($m -match '主总线:\s*设备:\s*函数:\s*(0x[0-9a-fA-F]+):\s*(0x[0-9a-fA-F]+):\s*(0x[0-9a-fA-F]+)'){ $bdf=$matches[1]+':'+$matches[2]+':'+$matches[3] }
      $comp='未知'; if($m -match '组件:\s*(.*?)\s*错误源:'){ $comp=$matches[1] }
      $k=$comp+' 端口 '+$bdf; if(-not $stat.ContainsKey($k)){ $stat[$k]=0 }; $stat[$k]++
    }
    foreach($k in ($stat.Keys | Sort-Object)){ W ('  ' + $k + '   ' + $stat[$k] + ' 次') }
    W '  >>> 有 WHEA 事件（尤其 ID17 已更正错误）且在增长 → 延长线信号质量差'
  }
} catch { W ('  读取失败: ' + $_.Exception.Message) }
W ''
W '==== 判据 ===='
W '  A. 1060 满载 Gen3 x16、无 WHEA 事件  → **延长线没问题**，40HX 的 Gen1 属于“固件/驱动策略”那条线'
W '  B. 1060 也只到 Gen1 或 x1/x4、或报 WHEA 错误 → **延长线（或插槽/BIOS 设置）有问题**'
W '  C. 1060 满载 Gen3 x16 但仍有 WHEA 事件 → 线能用但在报错，换线为上'
W ''
W '  测试前务必确认：BIOS 里该 x16 插槽速率是 **Auto（或 Gen3/Auto）**，不要锁在 Gen1 —— 否则这张卡也会显示 Gen1，结论会错。'
W ''
W ('结果已存: ' + $out)
$sb.ToString() | Out-File -Encoding utf8 $out
