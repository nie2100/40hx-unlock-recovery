# 03 — 坑清单与历史踩坑记录

每条的格式：**症状 → 根因 → 处理**。

## A. 会直接让功能失效的

### A1. 跑厂商安装器会静默覆盖 ESP 上的解锁 EFI
- 症状：`C:\ProgramData\CMP40HXGen2\windows\logs\last.log` 每轮 `ERROR: validated post-driver baseline not reached. Refusing writes.` + `EXIT=14`，Gen2 永不落地（算力还是好的）。
- 根因：厂商安装器把 `\EFI\40HX\40HXUNLK.EFI` 与 `\EFI\Boot\bootx64.efi` 换成厂商 EFI（MD5 `A2D47F4C…`）。厂商 EFI 不会做 OnlyEFI 那组 Gen2 预埋（实测读回 `LNKCAP=0x00453D01`、`LNKCAP2=0x2`、`GPU TLS=1`，且它的 `40hx_log.txt` 里没有任何 TLS/gen2 行），Windows helper 的守卫因此永远不通过。
- 处理：**试厂商包之前先备份这两个 EFI**，试完用 `scripts/restore-onlyefi.ps1` 写回 OnlyEFI 版本并复核 sha256 `1e9ca43fab3d5ce851e8fcd09dc9be63282fbf3ce3828c3dbcdcbb21cf7ce1c7`。

### A2. 算力与 Gen2 在走"硬回退"的板子上互斥
- 症状：Gen2 拿到了，但算力解锁没了（SS0 回零/假读数），有时显卡直接 Code 43（Problem 0x2B）。
- 根因：厂商方案的 Stage2 硬回退 = Root Link Disable → 写 TLS → 重训 → **`Disable-PnpDevice` / `Enable-PnpDevice` 复位显卡**（源码 `gen2PnpRecover40HX()` 只要做过 LD 就无条件执行）。显卡一被复位，SS0 解锁态（易失寄存器/SEC2）就清零。厂商 README 自己也承认"或 GPU 被重置过"。
- 处理：本平台不要走厂商方案。用 OnlyEFI（不复位设备）。若已经在硬回退状态且显卡 Code 43：**热重启无效，必须完全关机后再开机**（冷启动）。

### A3. 火绒（或其他杀软）会在驱动加载后清场
- 症状：某次开机起，`postbind.log` 报 `[SC] OpenService 失败 1060` + `FATAL: ThrottleStop service did not start`（exit 30），该次开机停在 Gen1。
- 根因：`ThrottleStop.sys` / `WinRing0x64.sys` 是 BYOVD 驱动，火绒会在加载后被隔离（`System32\drivers` 下文件消失、服务被删；隔离区多出无扩展名文件）。实测把驱动复制到未信任目录后 **10 秒内**即被删除。
- 处理：
  1. 在杀软信任区加两个文件（`C:\Windows\System32\drivers\ThrottleStop.sys`、`WinRing0x64.sys`）+ 两个目录（`C:\ProgramData\CMP40HXGen2`、解锁工作目录）；
  2. 已内建多源自愈：`RunPostBind.cmd` 每轮从普通目录补驱动，兜底源放 **ESP `\EFI\40HX\drv\`**（杀软不扫 EFI 分区），并在服务缺失时 `sc create` 重建（厂商 `AutoRetrain.cmd` 只 `start` 不 `create`）。

### A4. 别在验证前跑厂商 `40HXCheck.exe`
- 症状：之后 helper 报 `cannot open \\.\ThrottleStop`（退出码 10）。
- 根因：`40HXCheck.exe` 是"临时拉起驱动、测完即卸"，跑完会把 `System32\drivers` 里的两个 .sys 清掉。
- 处理：踩了就重拷驱动（或跑一次 `RunPostBind.cmd` 让自愈补回来）。要读 SS0 用 `CMP40HXGen2.exe` / 它的日志。

### A5. GSP 关闭 / Above 4G Decoding 关闭
- 症状：解锁后 nvlddmkm 不认卡 → **开机黑屏 1~2 分钟 + 设备管理器里 40HX 变代码 43**；或卡起不来。
- 根因：解锁态要求 `EnableGpuFirmware=1`；Above 4G Decoding 是本平台头号失败原因。
- 处理（**2026-09-30 更正：本文档此处原先写的注册表路径是错的**）：
  - 开关要写在**显示类子键**：`HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\<000X>` 下的
    `EnableGpuFirmware = 1`（DWORD）；`<000X>` 取 `MatchingDeviceId` 含 `ven_10de&dev_1f0b` 的那个子键（本机是 `\0001`）。
    实测 `HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters` 里**没有也无效**（写在那里驱动不读；整棵树搜 `EnableGpuFirmware` = 0 匹配）。
  - **判据只认一条**：`nvidia-smi -q` 的 `GSP Firmware Version` 行 —— 显示**版本号 = 已启用**，显示 **`N/A` = 没启用**
    （NVIDIA 官方文档原话：显示版本号代表已启用，`N/A` 代表未启用）。
    ⚠ **别把 `N/A` 当成“已开启”**：`oneclick/` 2026-09-29 及以前的版本正是这么误判的（`(\S+)` 把 `N/A` 也匹配上），
    于是从不写开关 → 客户机上装完必然「重启黑屏 + 代码 43」。2026-09-30 已修（见 A8）。
  - 写完必须**完全关机再开机**（不是“重启”——重启清不掉显卡残留状态），再复跑 `-Mode Verify` 复核：
    结论要有 `GSP 固件 : PASS (版本号)` + `40HX 设备 : OK（没有代码 43）`。
  - BIOS 里 Above 4G Decoding = Enabled。

### A8. 客户机「装完重启黑屏 1~2 分钟 + 设备管理器代码 43」（2026-09-30 定位并修复）
- 主因就是 A5：GSP 从没被真正打开（判据把 `nvidia-smi` 的 `N/A` 当“已开启”，且开关写在了无效位置）。
- `oneclick/` 的修复（同日提交）：GSP 判定改三态（`N/A`/空/非版本号 = 未启用）、开关写显示类子键、
  显卡/根端口改为**自动探测**（`01:00.0`/`00:01.0` 只是兜底，逐个候选校验 `10DE:1F0B` 与根端口的 PCI-to-PCI 类码，探测不到拒写并 `exit 11`）、
  策略键 `Gen2AutoHard/Gen2PnpFallback=0` **无条件写**、厂商自启按“名字或命令行含 40HX”全扫禁用、ESP 挂载点用 volume GUID 与系统盘 ESP 比对、
  交付文案改「必须完全关机（不是重启）」。
- 现场取证 + 一键修复：`oneclick/诊断包-20260930/`（`一键诊断.cmd` 只读收集 → 桌面报告；`修复-GSP.cmd` 写开关）。
  只读报告开头直接给判据：GSP 状态 / 显卡实际 BDF 与父根端口 / 本次开机解锁固件是否执行 / 开机任务结果。

### A6. 腾讯 ACE（ACE-BOOT）拦 Gen2 驱动的映像加载
> 2026-09-28 起，定位与停/恢复由 `oneclick/payload/windows/ACE-Toggle.ps1` 完成：按驱动 `ImagePath` 含 `AntiCheatExpert` 定位（换目录/改服务名都不受影响），
> 托盘按可执行文件路径定位，恢复时按记录还原**原始启动类型**。细节与验证见 `docs/06-ace-boot.md` 第 9 节。
- 症状：开机后 ACE 弹「检测到与游戏可能存在兼容问题的软件程序加载：`C:\Windows\System32\drivers\ThrottleStop.sys`」；
  该次开机任务 `EXIT=30`（`last.log` = `[SC] StartService 失败 31` + `FATAL: ThrottleStop service did not start`），Gen2 停在 Gen1；
  **但 ESP `40hx_log.txt` 仍有 `*** UNLOCKED ***`** —— 算力正常，只是 Windows 侧落地失败，别误判成整机解锁崩了。
- 根因：ACE「反作弊预启动模式」的引导期内核驱动 `ACE-BOOT.sys`（`SYSTEM_START`）在映像加载阶段拒载 `ThrottleStop.sys`
  （SC 31 = ERROR_GEN_FAILURE）。**只拦 `ThrottleStop.sys`，同目录 `WinRing0x64.sys` 不受影响**。
  已排除系统 WDAC 易受攻击驱动列表（`VulnerableDriverBlocklistEnable=0`）。
- 处理：**`sc stop ACE-BOOT` 会永久卡 `STOP_PENDING`（用户态 `ACE-Tray.exe` 持有它）→ 必须先 `taskkill /IM ACE-Tray.exe /F`**，
  再 `sc stop` 立即 STOPPED。重训成功后 `sc config ACE-BOOT start= system` + `sc start ACE-BOOT` 恢复反作弊，
  **Gen2 是链路寄存器状态，不会被撤销**。已自动化进 `RunPostBind.cmd`。完整实测与误判陷阱见 `docs/06-ace-boot.md`。
  排查顺序：先看 ESP 固件日志 + `last.log`，**不要**在排查前跑厂商 `40HXCheck.exe`（它会删驱动和服务）。

### A7. ACE 弹「初始化失败」：停 ACE-BOOT 的窗口撞上登录时启动的托盘（2026-09-28）

- **症状**：算力 + Gen2 都是好的（`40hx_log.txt` 有 `UNLOCKED`、开机任务 `EXIT=0`），却弹 ACE 初始化失败。
- **原因**：`ACE-Tray.exe` 由 HKLM Run 在登录时拉起一次；若落在「停 ACE-BOOT → 恢复」的几秒窗口内启动，
  托盘初始化时 ACE-BOOT 不在 → 失败，且 Run 不会重试。
- **判据**：托盘 `CreationDate` ∈ [postbind.log 的「已停止」,「已恢复运行」]；或用 explorer 登录时刻与窗口重叠判定
  （后者在托盘已被重启过时仍有效）。
- **修**：`ACE-Toggle.ps1 -Action HealTray`（开机任务里已自动调用，见 `docs/06` 第 10 节）。
- **别做**：重装解锁包、重跑厂商安装器（后者还会覆盖 ESP 上的 OnlyEFI 固件，见 A1）。

## B. 引导项相关的

### B1. 部分主板忽略 `bcdedit` 写的固件启动项

- 症状：用 `bcdedit /copy {bootmgr}` + `{fwbootmgr} displayorder /addfirst` 建了 "40HX Unlock"，但开机不跑解锁；`bcdedit /enum firmware` 里只多出重复的 `{bootmgr}`。
- 根因：技嘉/AMI 固件不会真的在 NVRAM 里生成对应的 `Boot####` 项。
- 处理：三选一 —— ① BIOS 里把第一启动项设为该项；② 设为**硬盘本身**（走 `\EFI\Boot\bootx64.efi` 兜底，该文件已替换为解锁固件）；③ 自己写 NVRAM `Boot####`（构造细节见 **B4**）。

### B2. 读/写固件变量报 err=1314
- 根因：进程未启用 `SeSystemEnvironmentPrivilege`。
- 处理：管理员令牌 + `OpenProcessToken` → `LookupPrivilegeValue("SeSystemEnvironmentPrivilege")` → `AdjustTokenPrivileges`，读写都要。现成实现：`scripts/nvram_chk.ps1`（读）、`scripts/nvram_write.ps1`（写）。注意 `AdjustTokenPrivileges` 返回 true 不等于成功（要查 `GetLastError` 是否 1300/ERROR_NOT_ALL_ASSIGNED）；`GetFirmwareEnvironmentVariableW` 返回 0 + err=203 表示"变量为空/不存在"，err=1314 才是权限问题。

### B3. 写引导项把自己写死
- 处理：写入前**备份全部 `Boot####` 与 `BootOrder`**（本仓库 `payload/nvram-backup-20260911/` 就是一份样本）；
- 新项先只设 `BootNext=<新编号>` 做**一次性试跑**（失败断电重开即恢复，最安全），验证成功后才写 `BootOrder`；
- **`Boot####` 编号随机器不同**，本机实际是 `BootOrder = 0005, 0003, 0002`（`Boot0005` = `40HX Unlock`），而仓库里历史脚本 `nvram_bootorder.ps1` 里硬编码的 `0003` 是早期版本 —— 用前先按 `nvram_chk.ps1` 的实际编号改。

### B4. 自建 `Boot####` 的 HardDrive 设备路径节点：末两字节**不是**保留位（2026-09-28）
`EFI_LOAD_OPTION` 的 HardDrive 设备路径节点固定 **42 字节**：

```
4B 头(0x04,0x01,0x00,0x00) + 4B 分区号 + 8B 起始 LBA + 8B 扇区数 + 16B 分区 GUID
+ 1B MBRType + 1B SignatureType
```

末两字节必须按介质填：**GPT → `MBRType=0x02` + `SignatureType=0x02`（GUID 签名）**。按"保留位"写 `00-00` 在自家机器上可能侥幸能用，换机器就会不被采纳/启动不了。
踩到的经过：自检把构造出的节点与固件里**正在使用**的 `Boot0003`/`Boot0005` 逐字节比对时发现末两字节不一致 → 改 `02-02` 后完全一致。

**同时**：别拿现成启动项当模板。本机 NVRAM 里名为 "Windows Boot Manager" 的两条是**过期项**（分区 GUID 与现场 ESP 不符、甚至没有 FilePath 节点）。
正确做法是从现场 ESP 分区取参数（`Get-Partition` 的 `PartitionNumber`/`Offset`/`Size` + 分区 GPT GUID）现构造。

### B5. ESP 已挂在别的盘符时，`mountvol <新字母>: /S` 直接报“参数错误”（2026-09-28）
不是"换个字母"而是直接失败（`mountvol` 报 `参数错误`/`系统找不到指定的文件`）→ 安装脚本会误报 `ESP 挂载失败`。
正确顺序：**先扫现有盘符**找已经挂载出来的 ESP（判据 `\EFI\Boot` 或 `\EFI\Microsoft` 存在），找不到再尝试空盘符挂载。
（`oneclick/Install-40HXUnlock.ps1` 的 `Mount-Esp` 已按此实现，并把 `mountvol` 的原话一起打进日志。）

### B6. 验证自己构造的启动项固件收不收 —— 安全的做法（2026-09-28）
别去动正在用的那一条。用**同款构造算法**写一个临时项（如 `Boot0000`），然后：

```
bcdedit /enum firmware      :: 应立刻多出一条带 description / device partition / path 的条目
```

看到它被枚举出来（实测 `path \EFI\40HX\40HXUNLK.EFI`、`device partition=\Device\HarddiskVolume2`）就说明固件的确采纳了这种构造；随后删掉它并复核 `BootOrder` 与正在用的那条**逐字节未变**。
可选数据（description 段）留空是被接受的 —— 不需要照抄别人条目里的 136 字节 optional data。

## C. 容易误判的读数

### C1. `nvidia-smi` 的 `pcie.link.gen.current` 不等于真实链路
- 症状：明明已落地 Gen2，`nvidia-smi` 显示 `1`。
- 根因：空闲/纯计算负载不产生 PCIe 流量时动态降速，实测满载也可能显示 1。
- 处理：只认 ① helper 的 `GPU final: Gen2 x16 LNKSTA=0x1102` / `ROOT final: 0xF102`；② 带宽工具标注 `(Gen2 x16)` 且 ≈ 5.7–6.2 GB/s。

### C2. `SS0=0` 或 `0xFFFFFFFF` 是假读数
- 出现在硬回退复位后显卡 Code 43 / BAR0 读回全 FF 的状态下，不代表真的锁定；先冷启动让卡回来再读。

### C3. OpenCL 基准里跑的是哪块卡
- 工具（厂商 `release\OpenCL.exe`）会把机器上所有 GPU 依次跑一遍：`Device ID 0` = 40HX（FP32 ≈ 8.3 TFLOPs/s），再往后是核显（≈ 0.54 TFLOPs/s）。别看错段；`schtasks /ru SYSTEM` 会话里跑还会枚举成核显为 Device 0。

### C4. 驱动"用完即卸"后读不到 SS0 属正常
- 终态就该如此。要现场读，跑一次 helper（它会按需起服务）。

### C5. 判据别写死一种 PASS 文案（2026-09-28）
helper 有**两条成功路径**，文案不同：

```
PASS: physical Gen2 x16 reached           ← 本次真的做了重训
PASS: already physical Gen2 x16; no writes needed.   ← 幂等：本来就已经是 Gen2
```

只匹配 `PASS: physical Gen2 x16` 的判据会把**正常的幂等成功**误判成 FAIL（本机第一版 `-Mode Verify` 就误判过一次）。
正确写法：正则 `PASS:\s*(already\s+)?physical Gen2 x16`。`scripts/coldboot-report.ps1` 里同款写法已一并修正。

顺带一个 .NET 正则坑：`(?m)$` 匹配位置停在 `\n` **之前**，所以对 CRLF 文件做行尾锚定的替换（`^...do \($`）永远匹配不上，
要用 lookahead `(?=\r?$)`；同一坑也适用于 `^` 与 `\r` 相邻的各种改写脚本。

## D. 杂项

### D1. 幽灵设备实例
- `Get-PnpDevice` 里可能出现同 ID 但 `present=False / Problem=0x2D`（CM_PROB_DEVICE_NOT_CONNECTED）的历史实例，不影响功能。清理：`pnputil /remove-device "<instanceid>"`（脚本 `scripts/ghost-clean.ps1`，会先 `reg export` 备份 Enum 键）。

### D2. PowerShell 脚本的编码坑（自己写脚本时）
- 用工具写 `.ps1` 若为 **UTF-8 无 BOM**，Windows PowerShell 5.1 会按 GBK 解析 → 中文串拆坏引号，报"字符串缺少终止符"。
- 处理：写完后补 BOM（`EF BB BF`）再 `[Parser]::ParseFile` 校验；或脚本里避免中文。

### D3. 提权方式
- 本机用户属 Administrators 且 `ConsentPromptBehaviorAdmin=0`，可用 `Start-Process ... -Verb RunAs -Wait` 静默提权（无弹窗）。

### D4. 改 `.cmd` / 写 `.ps1` 时的编码与命名坑（2026-09-28）
- **`.cmd` 的编码不能假设**：上游 `RunPostBind.cmd` 是 **UTF-8**，本机在用的那份也是 UTF-8；当 GBK 读回写会把中文注释改坏（反之亦然）。
  改之前先探测（BOM → 严格 UTF-8 → GBK 依次试），**并按原编码写回**。
- **PowerShell 函数/变量名大小写不敏感**：`$l` 与 `$L` 是同一个变量；`RV` 是内置别名 `Remove-Variable`。自动化脚本里别用单字母/短名（实测因此让一个探针脚本 exit 1 且不写输出）。
- **WSL 侧调 `powershell.exe` 偶发失败**：`UtilAcceptVsock: accept4 failed 110` → 启动失败/退出码 1，重试 2~3 次即可；
  提权进程创建的文件 WSL 侧删不掉（Permission denied），要用提权 PowerShell 或先 `Stop-Process` 掉占用它的进程。
- **一键 `.cmd` 提权后必须跳过二次确认**：否则新窗口卡在 `set /p` 等按键（没人能按）。用标记参数（如 `elevated`）区分两条路径；
  测试带 `pause` 的 `.cmd` 用 `cmd /c "x.cmd < NUL"` 提权跑 + 输出重定向到文件再读。

### D5. 调外部脚本时别让两边同时写同一个日志文件（2026-09-28）
`.cmd` 里 `powershell -File x.ps1 >>"%LOG%" 2>&1` 时，cmd **自己**持有 `%LOG%` 的写句柄；被调脚本里再 `Add-Content` 同一个文件会报
`文件正由另一进程使用`，日志里刷一片报错（实测 19:34 那次）。
两种正确写法：① 调用处**不传**日志路径，让脚本把输出打到标准输出、由 `>>` 落盘（当前 `RunPostBind.cmd` 采用）；
② 脚本自己写日志、调用处就不重定向。脚本内再包一层 try/catch 回退到标准输出，双保险。

### D6. 在 `$ErrorActionPreference='Stop'` 的 PowerShell 里调原生命令会直接终止脚本（2026-09-28）

- PowerShell 5.1：外部程序（`schtasks.exe` / `sc.exe` / `mountvol` / `nvidia-smi`）往 **stderr** 写字会产生
  `NativeCommandError`，**即使写成 `... 2>&1 | Out-Null` 也照样终止脚本**。
- 现场后果：全新机器首次安装时开机任务还不存在，`Install-40HXUnlock.ps1` 的 `schtasks /delete`（869 行）吐 stderr
  → 安装中断在「开机任务 + 厂商自启收尾」，用户看到一片 `NativeCommandError`。
  本机当初没炸，只是因为任务早已存在（旧任务来自 9/11）。
- 实测对照：`schtasks /run|delete <不存在的任务>` → 抛；`sc.exe query <不存在的服务>` → **不抛**（错误走 stdout）。
- 修法（最小侵入、命令与输出文本不变）：所有原生调用统一包一层
  `function Invoke-Native { param([scriptblock]$Code) $p=$ErrorActionPreference; $ErrorActionPreference='Continue'; try { & $Code } finally { $ErrorActionPreference=$p } }`
  删除型再加「先 `Get-ScheduledTask` 判断存在」。回归：`-Mode Check` 0 项失败、查询文本照旧可解析。

### D7. `.cmd` 里不要写中文注释（2026-09-28）

- 文件存成 UTF-8 而 cmd 按 GBK 代码页解析 → 中文 `rem` 行被当成命令，每次 `call :label` 都报
  「'…' 不是内部或外部命令，也不是可运行的程序」。
- **它只打到控制台、不写进 `postbind.log`**（放日志的重定向只作用于那一行 `powershell` 调用；
  任务计划本身把 stdout/stderr 丢掉），所以长期没人发现 —— 排查 `postbind.log` 是找不到的。
- 处理：`RunPostBind.cmd` 已改成**纯 ASCII**（纯 ASCII 文件对任何代码页都安全）。

## 历史时间线（本机）

| 时间 | 事件 |
|---|---|
| 2026-09-11 上午 | 厂商工具 v3.1.2 路线：算力解锁成功，Gen2 只能靠 Stage2 硬回退落地 → 每次开机算力被清，确认两者互斥；改策略键 `Gen2AutoHard=0`/`Gen2PnpFallback=0` 保护算力 |
| 2026-09-11 11:14 | 换用 OnlyEFI v0.1.1 EFI（写入 ESP 两个位置，哈希校验）；自写 NVRAM 引导项 |
| 2026-09-11 11:20 | 首次拿到 `PASS: physical Gen2 x16` + `SS0=0x88888888` 两全；随后火绒隔离驱动、服务被删，补多源自愈包装 |
| 2026-09-11 16:52 | 重启端到端验证通过（开机 22s 后任务自动跑完，`EXIT=0`）；基准：FP32 8.33 TFLOPs/s、PCIe 双向 6.16 GB/s |
| 2026-09-19 深夜 | 复测厂商 v3.2：retrain-only 6 轮全败，`-gen2 -hard` 拿到 Gen2 但算力被清 + 显卡 Code 43（热重启无效，只能完全关机）；确认 v3.2 新特性对本机无用 |
| 2026-09-20 00:06 | `restore-onlyefi.ps1` 一键回滚：写回 OnlyEFI EFI（哈希校验）、禁用两个厂商任务、清 HKCU Run 里的 `40HXGen2` 残留键、策略键归零 |
| 2026-09-20 00:09:44 | **冷启动**；00:09:30 固件日志 `UNLOCKED` + `NO-RETRAIN`；00:10:10 开机任务 `EXIT=0` + `PASS: physical Gen2 x16 reached`（守卫 `SS0=0x88888888`）→ 端到端两全确认 |
| 2026-09-20 00:13 | 一次性冷启动验证任务出报告：算力 PASS / Gen2 PASS；顺手清掉一个 `Problem=0x2D` 幽灵设备实例 |
| 2026-09-22 20:43 | 该次开机固件日志 `UNLOCKED` + `NO-RETRAIN`（算力与 Gen2 预埋都正常），但 Windows 侧任务 `EXIT=30` —— 首次遇到 ACE 拦截 |
| 2026-09-22 20:49 | 现场诊断：`ThrottleStop` 服务 STOPPED + `WIN32_EXIT_CODE 31`；WDAC 列表已关；ESP EFI 哈希仍是 OnlyEFI `1e9ca43f…`；`ACE-Tray.exe` 在跑 |
| 2026-09-22 20:50 | 只 `sc stop ACE-BOOT` → **卡 STOP_PENDING**，任务仍 `EXIT=30`（厂商文档没写这一步） |
| 2026-09-22 20:51 | **`taskkill ACE-Tray.exe` → `sc stop` → 立刻 STOPPED → `sc start ThrottleStop` = exitcode 0** → 定位成功 |
| 2026-09-22 21:03 / 21:04 | A/B 双验证：ACE-BOOT 停止态直接跑任务 `EXIT=0`；ACE-BOOT 运行态由脚本自动"杀托盘→停→重训→恢复" 也 `EXIT=0` + `PASS: already physical Gen2 x16` |
| 2026-09-22 21:07 | 任务 `lastResult=0`；ACE-BOOT 已恢复 `STATE=RUNNING` / `START_TYPE=SYSTEM_START` → 「反作弊正常 + Gen2 已解锁」并存成立 |
| 2026-09-22 22:08 | **真·开机（BootTrigger）验证**：托盘未启动，无需杀进程，`sc stop` 直接成功 → `EXIT=0`（开机自动路径无需人工） |
| 2026-09-22 22:40 | 稳态复跑：`ACE: ACE-BOOT running - temporary stop…` → `stopped` → `EXIT=0` → `ACE: ACE-BOOT restored (SYSTEM_START)` |
| 2026-09-23 00:20 | 把 ACE 全套结论、含 ACE 处理的 `RunPostBind.cmd`、状态自检 `.bat`、原始证据归档进本仓库（`docs/06-ace-boot.md`） |
| 2026-09-23 01:08 | 状态自检脚本升级为 6 步：新增第 4 步**实测算力验证**（内嵌 PTX kernel：SM 数 / FP32 / FP16 / FP16-TC / 显存带宽，判据 SM≥34、FP32≥7.0、FP16≥13.0、TC≥40.0 TFLOPS、显存≥330 GB/s），结论改为三态 `全绿 -- WDDM + PCIe Gen2 + 算力满血` |
| 2026-09-28 18:24~18:42 | 自写的一键安装脚本（`oneclick/Install-40HXUnlock.ps1`）落地：Check 体检 EXIT=0；实测发现 NVRAM 里两条 "Windows Boot Manager" 是**过期项**（分区 GUID 与现场 ESP 不符、无 FilePath 节点）→ 改为从现场 ESP 分区现构造启动项 |
| 2026-09-28 18:44 | `-Mode SelfTest` 首次跑就查出**设备路径节点末两字节**写错（应为 `MBRType=0x02`+`SignatureType=0x02`）；改后与固件里在用的 `Boot0003` **逐字节一致** |
| 2026-09-28 18:49 | 固件接受度探针：用同款算法写临时 `Boot0000` → `bcdedit /enum firmware` 立刻枚举出该条目（`path \EFI\40HX\40HXUNLK.EFI`）；删除后 `BootOrder`/`Boot0005` 逐字节未变 |
| 2026-09-28 18:53 | 安装脚本在 ESP 已被挂到 `Y:` 时报 `ESP 挂载失败` → 定位为 `mountvol <新字母>: /S` 在 ESP 已挂载时会直接报错；改为"先扫已挂载的 ESP" |
| 2026-09-28 18:56 | `-Mode Verify` 双 PASS：固件日志 `*** UNLOCKED (SS0=0x88888888 SS1=0x8) ***` + helper `PASS: already physical Gen2 x16` → 「两全达成」 |
| 2026-09-28 18:57 | `一键安装.cmd`（提权后不再二次询问）端到端跑通：`安装退出码 = 0`；幂等 Install 连跑 4 次均 EXIT=0 |
| 2026-09-28 19:09 | 补「报错指引」：失败自动打印退出码含义/日志路径/体检命令/`排查指引.md`/回滚命令；故意不带 `-Yes` 跑 Uninstall 验证（退出码 2），Check/SelfTest 回归仍 EXIT=0 |
| 2026-09-28 19:20 | 把整包归档进仓库 `oneclick/`（不含 logs/backup/state），README 增加一键入口章节，docs/03 增补 B4~B6、C5、D4 |
| 2026-09-28 23:00~24:00 | 装机后 ACE 弹「初始化失败」→ 定位为「停窗撞上登录启动托盘」；`ACE-Toggle.ps1` 增 `HealTray` + `On` 记 `ResumedAt`，`RunPostBind.cmd` 加自愈调用并改纯 ASCII；`Install-40HXUnlock.ps1` 修掉 EAP=Stop 下原生命令的 NativeCommandError（D6）；新增 `oneclick/ACE排查/` 与 `oneclick/hotfix-20260928/` |
| 2026-09-28 19:20~19:40 | ACE 处理加固成 `ACE-Toggle.ps1`（路径定位 + 原启动类型还原 + 其它反作弊提示）；7 个模拟用例 + 真机 Off/On + `-Mode Install -RunNow` 端到端 `EXIT=0`；修掉 `postbind.log` 句柄冲突导致的日志报错 |
| 2026-09-29 09:06 | 找到 ACE **不拦**的物理内存驱动 `inpoutx64`（Red Fox UK 签名）：`ACE-BOOT` + `ACE-Tray` 全程运行时 GPU BAR0 9 个寄存器读写 **9/9 MATCH** → Gen2 重训可以不停反作弊 |
| 2026-09-29 11:34 | **真机开机首跑首选路径 PASS**：`NewPath EXIT=0` + `PASS: Gen2 reached on the new path - ACE-BOOT was never stopped`；`GUARD=PASS SS0=0x88888888`、`GPU LNKSTA=0x1102 / ROOT=0xF102`；`ACE-BOOT` 全程 `SYSTEM_START/RUNNING`、托盘 PID 未变、`inpoutx64T` 用完即删（证据 `evidence/boot-20260929/`） |
| 2026-09-29 11:2x | 装机实测抓到两个**假失败**：① `RunPostBind.cmd` 的自愈源重写判断在本机路径已是目标值时假报失败并让退出码变 1；② 驱动的 10 秒存活检查把 `inpoutx64.dll` 也拿到 `System32\drivers` 找（它本来就不该在那儿）→ 假报"被杀软隔离"。两处都已修，修完 `Check` 0 失败 / `Repair` 0 失败 / `Verify` 0 失败 0 提示 |
| 2026-09-29 11:4x | `oneclick/ACE排查/` 采集器升级（第 5b 节判据 + ACE 驱动文件版本行），并在真机实跑一遍（报告 16,642 B）；判据正则做了正反两向样本验证 |

