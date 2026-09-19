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
- 症状：解锁后 nvlddmkm 不认卡 → Code 43 / 黑屏；或卡起不来。
- 根因：解锁态要求 `EnableGpuFirmware=1`；Above 4G Decoding 是本平台头号失败原因。
- 处理：`HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\EnableGpuFirmware = 1`；BIOS 里 Above 4G Decoding = Enabled。

## B. 引导项相关的

### B1. 部分主板忽略 `bcdedit` 写的固件启动项
- 症状：用 `bcdedit /copy {bootmgr}` + `{fwbootmgr} displayorder /addfirst` 建了 "40HX Unlock"，但开机不跑解锁；`bcdedit /enum firmware` 里只多出重复的 `{bootmgr}`。
- 根因：技嘉/AMI 固件不会真的在 NVRAM 里生成对应的 `Boot####` 项。
- 处理：三选一 —— ① BIOS 里把第一启动项设为该项；② 设为**硬盘本身**（走 `\EFI\Boot\bootx64.efi` 兜底，该文件已替换为解锁固件）；③ 自己写 NVRAM `Boot####`（见 C1）。

### B2. 读/写固件变量报 err=1314
- 根因：进程未启用 `SeSystemEnvironmentPrivilege`。
- 处理：管理员令牌 + `OpenProcessToken` → `LookupPrivilegeValue("SeSystemEnvironmentPrivilege")` → `AdjustTokenPrivileges`，读写都要。现成实现：`scripts/nvram_chk.ps1`（读）、`scripts/nvram_write.ps1`（写）。注意 `AdjustTokenPrivileges` 返回 true 不等于成功（要查 `GetLastError` 是否 1300/ERROR_NOT_ALL_ASSIGNED）；`GetFirmwareEnvironmentVariableW` 返回 0 + err=203 表示"变量为空/不存在"，err=1314 才是权限问题。

### B3. 写引导项把自己写死
- 处理：写入前**备份全部 `Boot####` 与 `BootOrder`**（本仓库 `payload/nvram-backup-20260911/` 就是一份样本）；
- 新项先只设 `BootNext=<新编号>` 做**一次性试跑**（失败断电重开即恢复，最安全），验证成功后才写 `BootOrder`；
- **`Boot####` 编号随机器不同**，本机实际是 `BootOrder = 0005, 0003, 0002`（`Boot0005` = `40HX Unlock`），而仓库里历史脚本 `nvram_bootorder.ps1` 里硬编码的 `0003` 是早期版本 —— 用前先按 `nvram_chk.ps1` 的实际编号改。

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

## D. 杂项

### D1. 幽灵设备实例
- `Get-PnpDevice` 里可能出现同 ID 但 `present=False / Problem=0x2D`（CM_PROB_DEVICE_NOT_CONNECTED）的历史实例，不影响功能。清理：`pnputil /remove-device "<instanceid>"`（脚本 `scripts/ghost-clean.ps1`，会先 `reg export` 备份 Enum 键）。

### D2. PowerShell 脚本的编码坑（自己写脚本时）
- 用工具写 `.ps1` 若为 **UTF-8 无 BOM**，Windows PowerShell 5.1 会按 GBK 解析 → 中文串拆坏引号，报"字符串缺少终止符"。
- 处理：写完后补 BOM（`EF BB BF`）再 `[Parser]::ParseFile` 校验；或脚本里避免中文。

### D3. 提权方式
- 本机用户属 Administrators 且 `ConsentPromptBehaviorAdmin=0`，可用 `Start-Process ... -Verb RunAs -Wait` 静默提权（无弹窗）。

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
