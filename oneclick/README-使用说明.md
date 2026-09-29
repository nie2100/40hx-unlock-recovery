# CMP 40HX 算力解锁 + PCIe Gen2 一键脚本（迁移版）

自含脚本：**只用本目录里的东西**，不需要联网、不需要厂商安装器。
把整个 `40hx-oneclick` 目录拷到任意一台装有 CMP 40HX 的电脑上，双击 `一键安装.cmd`，重启，完事。

```
40hx-oneclick\
├─ 一键安装.cmd                  ← 双击这个（自动提权 + 安装/修复）
├─ 状态自检.bat                  ← 双击看结论（无需管理员，算力/Gen2/性能）
├─ Install-40HXUnlock.ps1        ← 主脚本（Check/Install/Repair/Verify/SelfTest/Uninstall/MakeDefault）
├─ README-使用说明.md            ← 本文
├─ 排查指引.md                   ← **报错时查这个**（按报错原话 / 退出码索引）
├─ 验证记录.md                   ← 本机实测证据（每条日志文件名 + 读数）
├─ payload\EFI\40HXUNLK.EFI      ← OnlyEFI v0.1.1 解锁固件（算力解锁 + Gen2 primer）
├─ payload\windows\              ← Windows 侧 helper（CMP40HXGen2.exe / AutoRetrain / RunPostBind / Status / ACE-Toggle / 40hx-retrain-inpout）
├─ payload\drivers\*.b64          ← 签名驱动（base64，避免被杀软秒删）: ThrottleStop.sys / WinRing0x64.sys / inpoutx64.sys / inpoutx64.dll
├─ payload\sha256.txt            ← 载荷哈希清单
├─ logs\                         ← 每次运行自动留日志
├─ backup\<时间戳>\              ← 每次运行前把被改动的原文件/原固件启动项备份在这里
└─ state\installed.json          ← 安装状态（启动项编号等），Uninstall 用它回滚
```

## 1. 前提（装之前先确认，脚本会自己体检一遍）

| 项 | 要求 | 怎么查 |
|---|---|---|
| 引导 | **UEFI + GPT** | 脚本体检；MBR 盘先 `mbr2gpt` |
| Secure Boot | **关** | BIOS；脚本体检 |
| BIOS | **Above 4G Decoding = Enabled**、CSM 关、Fast Boot 关 | 只能进 BIOS 看，**这是头号失败原因** |
| BitLocker | 关/暂停（否则改引导链会索要恢复密钥） | 脚本体检 |
| 显卡 | CMP 40HX（`VEN_10DE&DEV_1F0B`）；NVIDIA 驱动 GSP 要开着 | 脚本体检（未开 GSP 时 Install 会写 `EnableGpuFirmware=1`） |
| 杀软 | 火绒必须在“信任区”加入下面 5 项 | `C:\Windows\System32\drivers\ThrottleStop.sys`、`...\WinRing0x64.sys`、`...\inpoutx64.sys`、`C:\ProgramData\CMP40HXGen2`、本包目录 |

> 火绒提示是**预期现象**：安装时它会报一次 `Exploit/Vulndriver.ad` 并试图删除驱动（都是 BYOVD 类驱动，所有 PCIe 解锁方案都靠它们）。
> 按提示选“信任/恢复”即可；就算被删，开机任务会用 **ESP 分区里的兜底源**自动补回（杀软不扫 EFI 分区）。
> 脚本只把裸 `.sys` 写到 `System32\drivers` 与两个 `%ProgramData%` 目录（实测这三处存活），载荷里驱动是 **base64 文本**，不会一解压就被当病毒。

### 1.1 杀软要做的动作（照做，30 秒）

**火绒**（会弹一次 `Exploit/Vulndriver.ad`，弹窗里“操作进程”就是本脚本的 powershell，属正常）：
`火绒 → 安全设置 → 信任区 → 添加`，加入这 5 项，然后关掉它的**「启动项保护 / UEFI/引导区保护」**：

```
C:\Windows\System32\drivers\ThrottleStop.sys
C:\Windows\System32\drivers\WinRing0x64.sys
C:\Windows\System32\drivers\inpoutx64.sys
C:\ProgramData\CMP40HXGen2            （目录）
本包目录，例如 D:\40hx-unlock\40hx-oneclick   （目录）
```

**Windows Defender**：`设置 → 病毒和威胁防护 → 管理设置 → 排除项`，加 `C:\ProgramData\CMP40HXGen2` 和上面那三个 `.sys` 全路径。

**360 / 电脑管家 / 厂商安全组件**（联想 Vantage 等）：同样加信任，并关掉**「启动项保护 / UEFI 保护」**——否则写固件启动项会失败（退出码 4）。

被删了也不用重装：加完信任区跑一次 `-Mode Repair`，开机任务的**多源自愈**（两个 `%ProgramData%` 目录 + ESP `\EFI\40HX\drv` 兜底）会自己补回来。
详细判据与话术见 `排查指引.md` 第 2 节。

腾讯 ACE 反作弊（ACE-BOOT）**不需要手工关**：开机任务的首选路径（`40hx-retrain-inpout.ps1`，用 `inpoutx64.sys` 直接写 GPU 寄存器）**全程不停 ACE-BOOT** ——
反作弊的预启动模式不被破坏，所以玩腾讯游戏不该再弹“需要重启 / 需要预启动模式”。只有新路径失败（退出码非 0）时才会自动回落到老办法：“停 ACE-BOOT → 重训 → 恢复 ACE-BOOT”，此时那一轮开机 ACE 会被短暂停一次（日志里能看到 `falling back to the legacy ACE path`）。

**ACE 换安装目录 / 改服务名都不影响**：`ACE-Toggle.ps1` 不认死 `C:\Program Files\AntiCheatExpert`，也不认死服务名 ——
它按①驱动 ImagePath 含 `AntiCheatExpert` 且正在运行的、②名字叫 `ACE-BOOT` 的顺序定位（实测模拟 `D:\Tencent\AntiCheatExpert\ACE-BOOT2.sys`、`D:\Games\AntiCheatExpert\SGuard64.sys` 都能正确选中）；
托盘进程同理按路径定位（找不到才回退 `taskkill /IM ACE-Tray.exe`）。停止前把原始启动类型（System/Auto/Manual…）写进 `logs\ace-state.json`，恢复时照原样还原。
另外它会提示检测到的其它厂商反作弊（vgk/EasyAntiCheat/BEDaisy/XIGNCODE…）——那些本脚本**不**处理，若它们也拦 `ThrottleStop.sys` 需要人工放行。

## 2. 三步用法

1. 双击 `一键安装.cmd` → 回车 → 等它跑完（首次约 1 分钟，含 10 秒杀软观察期）
2. **重启**（解锁是每次开机由 EFI 写 GPU 寄存器实现的，不重启不生效）
3. 重启后双击 `状态自检.bat`，看到 `全绿 -- WDDM + PCIe Gen2 + 算力满血` 即成功

换机器时把整个目录拷过去即可（U 盘、网盘都行）；装完不必留着，但留着方便修复/回滚。

跑完脚本会让你「重启」，并把这次要你做的事（杀软信任区之类）在结尾再列一遍，同时写出 `下一步-重启后看这里.txt`（控制台关了也能看）。
觉得提示不清就看那份 txt。

> `状态自检.bat` 是用 Python(`C:\Windows\py.exe`) 实测 PCIe 链路带宽与算力的，目标机没装 Python 时它会提示无法实测。
> 没有 Python 就用脚本自带的取证：`powershell -ExecutionPolicy Bypass -File Install-40HXUnlock.ps1 -Mode Verify`（不依赖 Python）。

## 3. 模式一览

```powershell
# 体检（可非管理员跑，缺 ESP/启动项检查）
powershell -ExecutionPolicy Bypass -File Install-40HXUnlock.ps1 -Mode Check

# 自检：ESP 读写往返 + 固件变量写入/回读/删除往返 + BootOrder 原样写回（不改动状态）
... -Mode SelfTest

# 安装/修复（幂等，可重复跑）
... -Mode Install                 # 全部
... -Mode Install -BootMode next  # 只做一次性 BootNext 试跑，不动 BootOrder
... -Mode Install -Force          # 前提有警告时强行继续
... -Mode Repair                  # 只补驱动/服务/helper/任务（不动 ESP 与启动项）

# 现场取证：算力 + Gen2 + 任务结果
... -Mode Verify

# 把 "40HX Unlock" 提到 BootOrder 第一位（安装时选了 -BootMode none 才需要）
... -Mode MakeDefault

# 卸载（还原 bootx64.efi、删启动项/任务/服务/驱动）；-Purge 连 ProgramData 一起删
... -Mode Uninstall -Yes
```

退出码：`0` 成功、`1` 一般失败、`2` 前提不满足、`3` 载荷哈希不符、`4` 固件变量(NVRAM)失败、`5` 驱动被拦截。
失败时脚本会自己打印一段「出错怎么办」，含退出码含义、日志路径、体检命令和回滚命令。

**换机器装的时候，报错就照 `排查指引.md` 查**（按日志里的原话/退出码索引，含杀软、前提、ESP/NVRAM、开机没解锁、驱动/服务五类共 30 多条对号入座的处置）。

## 4. 装了什么 / 为什么

| 部件 | 位置 | 作用 |
|---|---|---|
| `40HXUNLK.EFI` | ESP `\EFI\40HX\40HXUNLK.EFI` 与 `\EFI\Boot\bootx64.efi` | 开机时解锁算力（SS0=0x88888888）+ 预埋 Gen2 策略寄存器 + Root TLS=2，**故意不在 EFI 阶段重训**；之后 chainload 回 Windows Boot Manager |
| 固件启动项 `40HX Unlock` | NVRAM `Boot####`（脚本自己构造，含 ESP 设备路径节点） | 让固件开机先跑解锁固件；配合 `bootx64.efi` 兜底，固件忽略 NVRAM 的主板也能生效 |
| `ThrottleStop.sys` / `WinRing0x64.sys` | `System32\drivers` + `%ProgramData%\CMP40HXGen2\drivers` + `%ProgramData%\40HXUnlock\drivers` + ESP `\EFI\40HX\drv` | BYOVD：Windows 侧读写 PCI 配置空间落地 Gen2（老路径用；新路径只用它的 PCI 配置空间读/写） |
| `inpoutx64.sys` / `inpoutx64.dll` | `System32\drivers` + `%ProgramData%\CMP40HXGen2\drivers` + `%ProgramData%\40HXUnlock\drivers` + ESP `\EFI\40HX\drv` | **新路径的主力**：MMIO 直接读写 GPU BAR0（`LINK_CONFIG_0` / `PRIV_MISC_1` 两个被驱动冲掉的策略寄存器）。不建常驻服务：开机脚本自己 `sc create/delete` 临时服务 `inpoutx64T` |
| `CMP40HXGen2.exe` | `%ProgramData%\CMP40HXGen2\windows` | 守卫（要求 SS0/SS1/TLS/LNKCAP 等基线）→ 只恢复 2 个被驱动改掉的策略寄存器 → Root Retrain SET-only ×2 → `PASS: physical Gen2 x16`。**不复位显卡，所以不会清掉算力**（老路径用） |
| `40hx-retrain-inpout.ps1` | 同上 | **首选路径**：MMIO 走 `inpoutx64.sys`、PCI 配置空间走 `WinRing0x64.sys`；基线不认识就拒写；只写那两个策略寄存器 + Root Retrain SET-only ×2 → 校验 `GPU LNKSTA=0x1102 / ROOT LNKSTA=0xF102`。**ACE-BOOT 全程不用停**。退出码：0 PASS / 10 链路没到 Gen2 / 11 基线或 PCIe cap 找不到 / 12 GPU 未就绪 / 13 inpoutx64 没起来 / 3 WinRing0 不可用 |
| `RunPostBind.cmd` | 同上 | 开机任务入口：**先跑新路径**（`EXIT=0` 即结束，完全不碰 ACE）→ 不成功才走老办法 `call :ace_toggle off` → 多源自愈补驱动/建服务 → AutoRetrain（重试 3 次）→ 成功才 `call :ace_toggle on` |
| `ACE-Toggle.ps1` | 同上 | **只做 ACE 的定位与停/恢复**：按驱动 `ImagePath` 里的 `AntiCheatExpert` 定位（不写死服务名、不写死安装目录），托盘进程按可执行文件完整路径定位；停止前记录**原始启动类型**，恢复时按记录还原（不是写死 `start= system`）。顺带检测并提示其它厂商反作弊 |
| 开机任务 `CMP40HX Gen2 PostBind` | 任务计划程序（BootTrigger / SYSTEM / Highest） | 每次开机自动跑上面那步 |

厂商版（CMP40HX-Unlock）的安装器**故意不用**：它会把 ESP 上的 OnlyEFI 固件覆盖成厂商 EFI，导致 Windows 侧 helper 的守卫基线不成立（实测每轮 exit 14，Gen2 永远不落地）。本脚本也会顺手禁用厂商的 `40HX PCIe Gen2 Bring-up` / `40HX-Gen2-Retrain` 任务与 HKCU 登录自启（那套在本机只能靠复位显卡才拿到 Gen2，会把算力清掉）。

## 5. 常见故障

> 这里只列最高频的几条；**完整排查指南见 `排查指引.md`**（按日志原话索引，含“装完重启没效果/只有一半生效”的判据）。

| 症状 | 原因 / 处理 |
|---|---|
| 重启后 `40hx_log.txt` 没有新的 `UNLOCKED` 行 | BIOS 的 **Above 4G Decoding 没开**，或 Secure Boot 没关，或启动项没走解锁固件 → 进 BIOS 把第一启动项设为 "40HX Unlock"（或硬盘本身，走 `\EFI\Boot\bootx64.efi` 兜底） |
| 算力 OK 但 Gen2 没落地 | 先看 `%ProgramData%\CMP40HXGen2\windows\logs\postbind.log` 末尾：有 `PASS: Gen2 reached on the new path` = 好；有 `falling back to the legacy ACE path` 说明新路径失败，同段的 `NewPath EXIT=n` 就是原因（11 基线不认识 / 12 GPU 未就绪 / 13 inpoutx64 没起来 / 10 链路没到 Gen2 / 3 WinRing0 不可用），逐条读数在 `logs\retrain-inpout.log`。老路径的 `logs\last.log` 里 `EXIT=30` = 驱动没起来（杀软/ACE 拦截）；`exit 14` = 守卫基线不成立（ESP 固件被覆盖成厂商版了，重跑 Install 即可写回） |
| 驱动文件装完 10 秒消失 | 火绒隔离 → 信任区加第 1.1 节那几项，然后 `-Mode Repair` |
| 卡在 Code 43 / 黑屏 | 显卡被复位过 → **完全关机冷启动**（热重启无效）；并确认 GSP 已开启 |
| 开机任务上次 rc=0x1F（31） | ACE-BOOT 拦了老路径要用的驱动。首选新路径不用那个驱动，正常不会出现；真反复出现就看 `postbind.log` 里有没有 `falling back to the legacy ACE path`（新路径失败才会走它），并检查 `C:\Program Files\AntiCheatExpert\ACE-Tray.exe` 是否被别的策略拦住 |
| 想彻底回滚 | `-Mode Uninstall -Yes`（还原 `bootx64.efi`、删启动项/任务/服务/驱动），重启后就是原生状态 |

## 6. 载荷哈希（`payload\sha256.txt` 为准）

```
1e9ca43fab3d5ce851e8fcd09dc9be63282fbf3ce3828c3dbcdcbb21cf7ce1c7  EFI/40HXUNLK.EFI (590868 B, OnlyEFI v0.1.1)
16f83f056177c4ec24c7e99d01ca9d9d6713bd0497eeedb777a3ffefa99c97f0  ThrottleStop.sys (50216 B)
11bd2c9f9e2397c9a16e0990e4ed2cf0679498fe0fd418a3dfdac60b5c160ee5  WinRing0x64.sys (14544 B)
f8965fdce668692c3785afa3559159f9a18287bc0d53abb21902895a8ecf221b  inpoutx64.sys (15008 B, 新路径 MMIO 驱动)
5f27ed4d5cd58a1ee23deeb802e09e73f3a1d884ce2135f6e827f67b171269e7  inpoutx64.dll (98304 B, 配合上面那个驱动的用户态 DLL)
```

脚本每次运行都会校验这些哈希（EFI 与解码后的驱动），不一致就直接停下来报错，不会写坏现场。

## 7. 来源与血统

- 解锁固件与 Windows 侧 helper：[BardKing-CN/CMP40HX-Unlock-OnlyEFI](https://github.com/BardKing-CN/CMP40HX-Unlock-OnlyEFI) v0.1.1（MIT）——上游 issue #44 的方案，**唯一实测能让“算力 + Gen2”并存的路径**
- 两个签名驱动：CMP40HX-Unlock 项目 v3.x 包内 THIRD_PARTY_DRIVERS
- RunPostBind / 多源自愈 / ACE 处理 / NVRAM 启动项构造：本机（技嘉 B560M + CMP 40HX，Windows 11 26200）实测沉淀
- 本机完整实测记录（原理、坑、证据）：https://github.com/nie2100/40hx-unlock-recovery

## 8. 这份包在本机的验证记录

见 `验证记录.md`（含每一步的日志文件名与实测读数）。
