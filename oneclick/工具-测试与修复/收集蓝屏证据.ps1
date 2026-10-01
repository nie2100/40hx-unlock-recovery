# ============================================================
#  40HX 蓝屏取证（双击 收集蓝屏证据.cmd 即可，只读不改任何设置）
#  收集：① BugCheck 事件（含 0x124 的 4 个参数）② WHEA-Logger 事件（指名错误源）
#        ③ minidump 清单 ④ 40HX 当前 PCIe 链路状态 ⑤ 是否有 PCIe 错误计数
#  结果写到桌面：40HX-蓝屏证据-<时间>.txt
# ============================================================
$ErrorActionPreference='Continue'
$desk=[Environment]::GetFolderPath('Desktop')
if(-not $desk){ $desk='C:\Users\Public\Desktop' }
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$out=Join-Path $desk ('40HX-蓝屏证据-' + $stamp + '.txt')
$sb=New-Object System.Text.StringBuilder
function W { param([string]$s='') [void]$sb.AppendLine($s) }
function WB { param([string]$s='') Write-Host $s; [void]$sb.AppendLine($s) }

WB '============================================================'
WB ' 40HX 蓝屏取证（只读）'
WB (' 时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
WB (' 机器: ' + $env:COMPUTERNAME)
WB '============================================================'
W ''
W '==== 1) BugCheck 事件（蓝屏代码 + 4 个参数）===='
try {
  $bc = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'} -MaxEvents 10 -ErrorAction SilentlyContinue
  if(-not $bc){ $bc = Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001} -MaxEvents 10 -ErrorAction SilentlyContinue }
  if($bc){ foreach($e in $bc){ W ('  [' + $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') + '] ' + ($e.Message -replace "\s+",' ')) } }
  else { W '  （没有找到 BugCheck 事件；若蓝屏发生在固件阶段可能没记录）' }
} catch { W ('  读取失败: ' + $_.Exception.Message) }
W ''
W '==== 2) WHEA-Logger 事件（会指名错误源：PCIe 根端口 / 总线设备功能号）===='
try {
  $wh = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'} -MaxEvents 25 -ErrorAction SilentlyContinue
  if($wh){
    foreach($e in $wh){
      W ('  [' + $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') + '] ID=' + $e.Id + ' 级别=' + $e.LevelDisplayName)
      W ('      ' + (($e.Message -replace "\s+",' ')).Trim())
      # 错误记录的关键字段常在事件数据里（消息体里没有）
      try {
        if($e.Properties -and $e.Properties.Count -gt 0){
          $vals=@()
          for($i=0;$i -lt [Math]::Min(8,$e.Properties.Count);$i++){
            $pv=$e.Properties[$i].Value
            if($pv -ne $null){ $vals += ('[' + $i + ']' + ([string]$pv)) }
          }
          if($vals.Count -gt 0){ W ('      数据: ' + (($vals -join '  ') -replace "\s+",' ')) }
        }
      } catch { }
    }
  } else { W '  （没有 WHEA-Logger 事件）' }
} catch { W ('  读取失败: ' + $_.Exception.Message) }
W ''
W '==== 3) minidump 清单 ===='
try {
  $dumps = @(Get-ChildItem 'C:\Windows\Minidump' -Filter '*.dmp' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 12)
  if($dumps){ foreach($d in $dumps){ W ('  ' + $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $d.Name + '  ' + [int]($d.Length/1024) + ' KB') } }
  else { W '  （C:\Windows\Minidump 里没有 dmp）' }
  $mem = Get-Item 'C:\Windows\MEMORY.DMP' -ErrorAction SilentlyContinue
  if($mem){ W ('  另有完整转储 C:\Windows\MEMORY.DMP  ' + $mem.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + '  ' + [int]($mem.Length/1MB) + ' MB') }
  W ''
  W '  （分析用：把 Minidump 里最新那个 .dmp 发回来即可；WinDbg 里 !analyze -v + !errrec 能指出错误源）'
  W ('  当前转储设置: ' + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -ErrorAction SilentlyContinue).CrashDumpEnabled + ' (0=无 1=完整 2=内核 3=小 7=自动)')
} catch { W ('  读取失败: ' + $_.Exception.Message) }
W ''
W '==== 4) 40HX 当前 PCIe 链路状态 ===='
$smi="$env:SystemRoot\System32\nvidia-smi.exe"
if(Test-Path $smi){
  W ('  ' + ((& $smi --query-gpu=name,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv 2>&1 | Out-String).Trim() -replace "\r?\n", ' | '))
} else { W '  没有 nvidia-smi' }
try {
  $d = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match '40HX|NVIDIA' }
  foreach($x in $d){ W ('  设备: ' + $x.FriendlyName + '  状态=' + $x.Status + '  问题码=' + $x.Problem) }
} catch {}
W ''
W '==== 5) PCIe 端口错误计数（有 AER 计数说明链路在报错）===='
try {
  $ev = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-PnP'} -MaxEvents 15 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'PCI|错误|error' }
  if($ev){ foreach($e in $ev){ W ('  [' + $e.TimeCreated.ToString('MM-dd HH:mm:ss') + '] ' + ($e.Message -replace "\s+",' ')) } } else { W '  （无 Kernel-PnP 相关错误）' }
} catch {}
W ''
W '==== 6) 机器/固件 ===='
try {
  $cs = Get-CimInstance Win32_ComputerSystem
  $bb = Get-CimInstance Win32_BaseBoard
  $bios = Get-CimInstance Win32_BIOS
  W ('  主板: ' + $bb.Manufacturer + ' ' + $bb.Product)
  W ('  BIOS: ' + $bios.SMBIOSBIOSVersion + '  ' + $bios.ReleaseDate)
  W ('  型号: ' + $cs.Manufacturer + ' ' + $cs.Model)
  W ('  Windows: ' + (Get-CimInstance Win32_OperatingSystem).Version + '  Build ' + (Get-CimInstance Win32_OperatingSystem).BuildNumber)
} catch {}
W ''
W '==== 7) 驱动拦截源排查（Gen2 驱动加载不了时看这一节）===='
try {
  $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Name 'VulnerableDriverBlocklistEnable' -ErrorAction SilentlyContinue).VulnerableDriverBlocklistEnable
  W ('  [易受攻击驱动阻止列表] VulnerableDriverBlocklistEnable = ' + $(if($v -eq $null){'<未设置，默认按开处理>'}else{$v}) + '   （0=关；要关需重启）')
  $s = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
  W ('  [智能应用控制 SAC] VerifiedAndReputablePolicyState = ' + $(if($s -eq $null){'<未设置>'}else{$s}) + '   （0=已关 / 1=开启 / 2=评估中；关掉后要重装系统才能再开）')
  $h = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled
  $vb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -ErrorAction SilentlyContinue).EnableVirtualizationBasedSecurity
  W ('  [内存完整性 HVCI] 注册表 Enabled = ' + $(if($h -eq $null){'<未设置>'}else{$h}) + '   VBS EnableVirtualizationBasedSecurity = ' + $(if($vb -eq $null){'<未设置>'}else{$vb}) + '   （0=关）')
  try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    W ('  [VBS 运行状态] VirtualizationBasedSecurityStatus=' + $dg.VirtualizationBasedSecurityStatus + '  SecurityServicesRunning=' + (($dg.SecurityServicesRunning) -join ',') + '  SecurityServicesConfigured=' + (($dg.SecurityServicesConfigured) -join ',') + '   （1=已启用运行；SecurityServicesRunning 里 2=HVCI）')
  } catch { }
  W '  [ACE-BOOT 反作弊]（厂商说明：它会拦 Gen2 驱动）:'
  $ace = (sc.exe qc ACE-BOOT 2>&1 | Out-String)
  if($ace -match 'SERVICE_NAME'){ W ('    ' + (([regex]::Match($ace,'START_TYPE\s*:\s*\d+\s+\S+').Value)) + '   当前状态: ' + (([regex]::Match((sc.exe query ACE-BOOT 2>&1 | Out-String),'STATE\s*:\s*\d+\s+\S+').Value))) }
  else { W '    （没有 ACE-BOOT 服务）' }
  W '  [代码完整性策略日志]（会直接写出是哪个策略拦了哪个驱动）:'
  try {
    $ci = @(Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 15 -ErrorAction SilentlyContinue)
    if($ci){ foreach($e in $ci){ W ('    [' + $e.TimeCreated.ToString('MM-dd HH:mm:ss') + '] ID=' + $e.Id + ' ' + (($e.Message -replace "\s+",' ')).Trim()) } }
    else { W '    （没有代码完整性事件 → 说明不是 WDAC/CI 策略在拦）' }
  } catch { W ('    读取失败（可能日志未启用）: ' + $_.Exception.Message) }
  W '  [WinRing0 服务现状] :'
  W ('    ' + ((sc.exe qc WinRing0_1_2_0 2>&1 | Out-String) -replace "`r?`n",' | '))
  W ('    ' + ((sc.exe query WinRing0_1_2_0 2>&1 | Out-String) -replace "`r?`n",' | '))
} catch { W ('  读取失败: ' + $_.Exception.Message) }
W ''
WB ('结果已存: ' + $out)
$sb.ToString() | Out-File -Encoding utf8 $out
