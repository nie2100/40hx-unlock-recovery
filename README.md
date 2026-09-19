# CMP 40HX 解锁状态恢复手册（本机实测版）

> 目的：重装 Windows / 换盘 / 清 CMOS 之后，照本文把 **算力解锁 + PCIe Gen2 x16 两全** 的状态恢复回来，不必重新摸索。
> 最近一次端到端验证：**2026-09-20 00:09 冷启动 PASS** —— EFI 日志 `*** UNLOCKED (SS0=0x88888888 SS1=0x8) ***`，开机任务 `CMP40HX Gen2 PostBind` → `EXIT=0` + `PASS: physical Gen2 x16 reached.`，同一次运行里 `GUARD=PASS SS0=0x88888888`（算力与 Gen2 同时成立）。
> 本仓库自含所需二进制（解锁 EFI、Windows 侧 helper、两个签名驱动、脚本），重装后不依赖网上重新找。

---

## 0. 本机基线（实测，非推测）

| 项目 | 值 |
|---|---|
| 主板 | Gigabyte B560M AORUS ELITE |
| BIOS | AMI F13d（2026-06-29） |
| CPU | Intel Xeon W-1370P（8C/16T） |
| 显卡 | NVIDIA CMP 40HX，ASUS 版，子系统 `1043:8804`，VBIOS `90.06.67.00.04` |
| 拓扑 | GPU `01:00.0` ← Root Port `00:01.0`（x16 电气） |
| 内存 | 8 GB |
| 系统 | Windows 11 专业版 build 26200，UEFI + GPT，无 BitLocker |
| 显卡驱动 | NVIDIA 616.92（GSP 固件必须开启） |
| 实测性能 | FP32 8.35 TFLOPs/s、显存读 400 / 写 426 GB/s、PCIe 物理 Gen2 x16 双向 ≈ 5.98 GB/s |

`payload/esp-2026-09-20/` 是当前 ESP 的实际快照（解锁固件、固件日志、驱动备份），可逐字节比对。

---

## 1. 方案骨架（为什么是这两步）

解锁与 Gen2 是**两个独立动作**，分处固件与 Windows：

1. **EFI 阶段（每次开机都要跑，算力是易失的）**
   `\EFI\40HX\40HXUNLK.EFI`（OnlyEFI v0.1.1）在开机时：
   - 写 SS0/SS1 解锁算力 → 日志 `*** UNLOCKED (SS0=0x88888888 SS1=0x8) ***`
   - 对 4 个 TU106 Gen2 策略寄存器做 RMW，并把 Root Port 的 TLS 设为 Gen2（`[efi-b] Root TLS=Gen2; GPU TLS intentionally unchanged`）
   - **故意不在 EFI 里重训链路**（`[efi-b] NO-RETRAIN: TLS2 set; skip EFI retrain`）
   - 然后 chainload `\EFI\Microsoft\Boot\bootmgfw.efi` 进 Windows（`chainload: bootmgfw.efi from current device`）

2. **Windows 阶段（驱动 bind 之后，一次开机只需成功一次）**
   `C:\ProgramData\CMP40HXGen2\windows\CMP40HXGen2.exe`（由开机任务调用）：
   守卫校验（要求 `SS0=0x88888888`、`SS1=0x8`、`GPU LNKCAP=0x00453D02`、`LNKCAP2=6`、`GPU TLS=2`、`ROOT TLS=2`、`PL_LINK_RATE=0x00220036`、`VSEC=0x801`）
   → 只恢复两个被驱动改写的寄存器 `LINK_CONFIG_0 800C5800→80085800`、`PRIV_MISC_1 E0B40D00→E0B42D00`
   → Root Retrain SET_ONLY #1（LT=0，只压不发）再 #2（LT=1，落地）
   → `PASS: physical Gen2 x16 reached`（`GPU final: Gen2 x16 LNKSTA=0x1102` / `ROOT final: ... 0xF102`）

   **不复位显卡**（不写 GPU/Root TLS、不写 XVE/CYA、不用 GPU retrain / PnP / FLR / D3 / SBR / Link Disable）—— 所以算力不会被清。幂等：已是 Gen2 时输出 `PASS: already physical Gen2 x16; no writes needed.`

> 关键前提：EFI 与 Windows helper 是一对，**守卫要求的基线由 OnlyEFI 的 EFI 预埋**。厂商版 EFI 不做这组预埋（`LNKCAP=0x00453D01`/`LNKCAP2=2`/`GPU TLS=1`），helper 会 `exit 14 / ERROR: validated post-driver baseline not reached`。两者不能混用。

---

## 2. 重装后的恢复步骤

### 步骤 0 — BIOS 前置（不满足必失败）

- UEFI + GPT 引导（MBR 需先 `mbr2gpt`）
- **Secure Boot = Disabled**（固件变量 `SecureBoot` = 00）
- **Above 4G Decoding = Enabled** ← 头号失败原因
- CSM = Disabled，Fast Boot = Disabled
- 无 BitLocker（否则改引导链会索要恢复密钥）
- 启动顺序：让 `40HX Unlock`（或硬盘本身，见步骤 3b）排第一

### 步骤 1 — 显卡驱动 + GSP

- 安装 NVIDIA 驱动（本机为 616.92；**GSP 必须开**，否则解锁后 nvlddmkm 不认卡 → Code 43 / 黑屏）
  检查：注册表 `HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters` 里 `EnableGpuFirmware = 1`
- 设备管理器确认显卡 `Status=OK / Problem=0`（不是 Code 43）

### 步骤 2 — 把解锁 EFI 写回 ESP

```
# 管理员 PowerShell
mountvol Y: /s
mkdir Y:\EFI\40HX            # 若不存在
copy /y  <repo>\payload\onlyefi-v0.1.1\EFI\40HXUNLK.EFI  Y:\EFI\40HX\40HXUNLK.EFI
# 兜底路径：先备份原 Windows 引导器，再覆盖
copy /y  Y:\EFI\Boot\bootx64.efi  Y:\EFI\Boot\bootx64.efi.40hx.bak
copy /y  <repo>\payload\onlyefi-v0.1.1\EFI\40HXUNLK.EFI  Y:\EFI\Boot\bootx64.efi
# 自愈源（杀软不扫 ESP 分区）：先把仓库里的 base64 备份还原成二进制
#   powershell -ExecutionPolicy Bypass -File <repo>\payload\drivers\RESTORE-DRIVERS.ps1
mkdir Y:\EFI\40HX\drv
copy /y  <repo>\payload\drivers\ThrottleStop.sys   Y:\EFI\40HX\drv\
copy /y  <repo>\payload\drivers\WinRing0x64.sys    Y:\EFI\40HX\drv\
# 校验：两个 EFI 的 sha256 必须都是
#   1e9ca43fab3d5ce851e8fcd09dc9be63282fbf3ce3828c3dbcdcbb21cf7ce1c7
Get-FileHash Y:\EFI\40HX\40HXUNLK.EFI,Y:\EFI\Boot\bootx64.efi -Algorithm SHA256
mountvol Y: /d
```

现成脚本：`scripts/install_onlyefi.ps1`（含备份+哈希校验，需把里面写死的路径改成仓库所在盘）。

### 步骤 3 — 固件启动项（三选一）

a. **BIOS 里手动设**：启动项列表选 `40HX Unlock`，排第一。
b. **没有该项时**：把第一启动项设为**硬盘本身** —— 固件会走 `\EFI\Boot\bootx64.efi` 兜底，该文件已被换成解锁固件（步骤 2 已处理）。
c. **远程重建 NVRAM 项**（不必进 BIOS）：
   1. `scripts/nvram_chk.ps1` 读现状（管理员；P/Invoke `GetFirmwareEnvironmentVariableW`，需先启用 `SeSystemEnvironmentPrivilege`）
   2. 复制现有 `Boot####` 的 EFI_LOAD_OPTION 结构（属性 + FilePathLen + 描述 UTF-16 + 设备路径节点），只把描述改成 `40HX Unlock`、FilePath 节点改成 `\EFI\40HX\40HXUNLK.EFI`（同步修正节点长度、FilePathListLength，并用 0 填充保持总长），写成新的 `Boot####`
   3. **先用 `BootNext=<新编号>` 做一次性试跑**（失败断电重开即恢复，最安全）
   4. 验证成功后写 `BootOrder` = [解锁项, Windows 项, 其余]
   - 本机当前实测：`BootOrder = 0005, 0003, 0002`，其中 `Boot0005` = `40HX Unlock`（`\EFI\40HX\40HXUNLK.EFI`），`0003`/`0002` = Windows Boot Manager。**Boot#### 编号每台机器不同，别硬编码**（仓库里 `scripts/nvram_bootorder.ps1` 里的 0003 是历史版本，用前先按 `nvram_chk.ps1` 的实际编号改）。
   - 另一条只读核对途径：管理员 `bcdedit /enum firmware`（能看到 `40HX Unlock` 项与 `{fwbootmgr}` 的 `displayorder`）。

### 步骤 4 — Windows 侧（helper + 驱动 + 服务 + 开机任务）

```
# 目录
C:\ProgramData\CMP40HXGen2\
├─ windows\      CMP40HXGen2.exe / AutoRetrain.cmd / RunPostBind.cmd / Status.cmd / logs\ / state\
└─ drivers\      ThrottleStop.sys / WinRing0x64.sys     （自愈源）
```

1. 复制 `payload/windows-live/*` → `C:\ProgramData\CMP40HXGen2\windows\`
2. 驱动：仓库里以 base64 文本备份（裸 `ThrottleStop.sys` 会被杀软秒删）→ 跑一次
   `powershell -ExecutionPolicy Bypass -File <repo>\payload\drivers\RESTORE-DRIVERS.ps1`
   还原到 `C:\Windows\System32\drivers\` 与 `C:\ProgramData\CMP40HXGen2\drivers\`，并自动补建缺失的服务
3. 重建两个内核服务（厂商脚本只启动不创建，缺了会报 1060）：
   ```
   sc create ThrottleStop    type= kernel start= demand binPath= "\SystemRoot\System32\drivers\ThrottleStop.sys"
   sc create WinRing0_1_2_0  type= kernel start= demand binPath= "\SystemRoot\System32\drivers\WinRing0x64.sys"
   ```
4. `RunPostBind.cmd` = 多源自愈包装（每轮补驱动 → 补/建服务 → 调 `AutoRetrain.cmd`，失败重试 3 次），模板见 `payload/windows-live/RunPostBind.cmd`（**注意里面写死的源路径要按新机器改**）
5. 注册开机任务（SYSTEM / ONSTART）：
   ```
   schtasks /create /tn "CMP40HX Gen2 PostBind" /sc onstart /ru SYSTEM /rl HIGHEST ^
     /tr "cmd.exe /d /c C:\ProgramData\CMP40HXGen2\windows\RunPostBind.cmd" /f
   ```
   现成脚本：`scripts/step6_auto.ps1`（建目录+拷文件+注册任务）、`scripts/step7_heal.ps1`（生成多源自愈包装）

### 步骤 5 — 杀软信任（火绒/360 等）

必须加信任，否则 `ThrottleStop.sys` 会被**秒删**、服务被删（症状：`postbind.log` 里 `[SC] OpenService 失败 1060` + `FATAL: ThrottleStop service did not start`，退出码 30，本次开机停在 Gen1）：

- 文件：`C:\Windows\System32\drivers\ThrottleStop.sys`、`C:\Windows\System32\drivers\WinRing0x64.sys`
- 目录：`C:\ProgramData\CMP40HXGen2`、解锁工作目录（本机为 `D:\40hx-unlock`）

自愈机制已内建（普通目录 + ESP `\EFI\40HX\drv\` 兜底源自愈 + 重建服务），但**信任区仍要加**，否则每轮开机都靠自愈，链路会间歇失败。

### 步骤 6 — 验证（判据，别用 nvidia-smi）

1. **算力**：ESP 根目录 `40hx_log.txt` 出现 `*** UNLOCKED (SS0=0x88888888 SS1=0x8) ***`；文件不存在 = 本次开机 EFI 没跑（启动项/兜底 没生效）
2. **Gen2（落地）**：`C:\ProgramData\CMP40HXGen2\windows\logs\last.log` 要 `GUARD=PASS` + `GPU final: Gen2 x16 LNKSTA=0x1102` + `ROOT final: Gen2 x16 LNKSTA=0xF102` + `PASS: physical Gen2 x16 reached.` + `EXIT=0`
3. **开机任务**：`postbind.log` 该轮 `PostBind EXIT=0` / `PASS: physical Gen2 post-bind step succeeded`；任务 `CMP40HX Gen2 PostBind` 上次结果 = 0
4. **带宽交叉验证**：跑 `release\OpenCL.exe` 基准，输出里会标注 `PCIe Bandwidth (bidirectional) (Gen2 x16)` 且 ≈ 5.7–6.2 GB/s（Gen1 只有 3.2–4）
   ⚠ 该工具会把机器上**所有** GPU 依次跑一遍：`Device ID 0` 是 40HX（FP32 ≈ 8.3 TFLOPs/s），再往后是核显（本机 ≈ 0.54 TFLOPs/s）——别看错段
5. **别信 `nvidia-smi` 的 `pcie.link.gen.current`**：纯计算负载不产生 PCIe 流量时它会动态降到 1，实测 100% 负载也照样显示 1。看 `LNKSTA` 寄存器或带宽工具
6. 冷启动端到端验证（可选）：一次性开机任务，3 分钟后自动出报告，脚本见 `scripts/coldboot-report.ps1` + `scripts/register-coldboot-task.ps1`

---

## 3. 关键坑（摘要）

- **厂商安装器会静默覆盖 ESP 上的解锁 EFI**（`\EFI\40HX\40HXUNLK.EFI` 与 `\EFI\Boot\bootx64.efi` 变回厂商版，MD5 `A2D47F4C…`）→ OnlyEFI 的 Windows helper 立刻失效（每天 `exit 14`），Gen2 永不落地。**试厂商包前先备份这两个文件，试完写回并复核 sha256。**
- **算力与 Gen2 在部分主板上互斥**：厂商方案若走 Stage2 硬回退（Root Link Disable + PnP 禁用/启用显卡）→ 显卡一复位，算力（易失寄存器）清零。本机 v3.2 实测：retrain-only 6 轮全败，只能硬回退，且**显卡会变 Code 43，热重启无效，必须完全关机冷启动**。OnlyEFI 路线正是为绕开这一点（不复位设备）。
- **升级厂商工具后**：`HKLM\SOFTWARE\40HXUnlock` 的 `Gen2AutoHard=0` / `Gen2PnpFallback=0` 会被改回，HKCU Run 的 `40HXGen2` 与两个厂商计划任务会被放回来 —— 每次升级后都要复查并重新禁用（`scripts/restore-onlyefi.ps1` 一条命令做完：备份厂商 EFI → 写回 OnlyEFI EFI → 校验哈希 → 禁厂商任务 → 清 HKCU Run → 设策略键）。
- **别在验证前跑厂商 `40HXCheck.exe`**：它是"临时拉起驱动、测完即卸"，跑完会把 `System32\drivers` 里的 .sys 清掉，随后 helper 报 `cannot open \\.\ThrottleStop`（退出码 10）。踩了就重拷驱动再跑。
- **`schtasks /ru SYSTEM` 的任务里跑 OpenCL 基准会枚举成核显**（Device 0 = Intel）→ 测显卡别用 SYSTEM 会话。
- 幽灵设备实例（`Problem=0x2D`，`present=False`）不影响功能，可用 `pnputil /remove-device "<instanceid>"` 清掉，脚本 `scripts/ghost-clean.ps1`。
- **裸 `ThrottleStop.sys` 会被杀软从任何非信任路径秒删**（临时目录、解压出来的上游包内都保不住，实测 10 秒内消失）→ 本仓库以 base64 文本保存；恢复时跑 `payload/drivers/RESTORE-DRIVERS.ps1`，之后把两个 .sys 加进杀软信任区。

细节（完整踩坑史、时间线、原始输出）：`docs/03-pitfalls.md`。

---

## 4. 目录说明

```
README.md                     本手册（恢复主流程）
docs/01-hardware.md           本机硬件/固件/拓扑实测
docs/02-how-it-works.md       原理：EFI 阶段与 Windows 阶段做了什么
docs/03-pitfalls.md           坑清单与历史踩坑记录（含厂商 v3.2 回滚经过）
docs/04-verify.md             验证判据与证据
docs/05-inventory.md          文件清点（来源、哈希、用途）
payload/onlyefi-v0.1.1/       OnlyEFI v0.1.1 完整发布包（EFI + Windows helper + 源码 + 文档）
payload/windows-live/         本机在用的 Windows 侧文件（含多源自愈 RunPostBind.cmd）
payload/drivers/              两个 BYOVD 驱动：base64 文本备份（裸 .sys 会被杀软秒删）+ RESTORE-DRIVERS.ps1 还原脚本
payload/esp-2026-09-20/       当前 ESP 快照（解锁固件 + 固件日志 + drv 备份）
payload/nvram-backup-20260911/ NVRAM 引导变量原始二进制备份（BootOrder/Boot0000/0002/0003/0005…）
scripts/                      可直接跑的 PowerShell 脚本（见 docs/05-inventory.md）
evidence/                     实测证据：冷启动报告、基准输出、helper 日志、固件日志
```

## 5. 回滚到"没有解锁"的干净状态

1. 用 `payload/esp-2026-09-20/EFI_Boot/bootx64.efi.40hx.bak`（或重新从 Windows 修复安装取的 `bootmgfw.efi`）还原 `\EFI\Boot\bootx64.efi`
2. 删除 `\EFI\40HX\`
3. 禁用/删除任务 `CMP40HX Gen2 PostBind`，删除 `C:\ProgramData\CMP40HXGen2\`
4. `sc delete ThrottleStop` / `sc delete WinRing0_1_2_0`，删两个 .sys
5. BIOS 启动顺序改回 Windows Boot Manager
