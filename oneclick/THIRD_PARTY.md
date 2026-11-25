# 第三方来源与许可（THIRD_PARTY）

本包（`40hx-oneclick`）不是从零写的：**它建立在下面这些开源项目之上**。这里逐项写清来源、用到了什么、许可是什么。

## 1. 上游项目（本包的基础）

| 项 | 内容 |
|---|---|
| 项目 | **CMP40HX-Unlock** |
| 地址 | https://github.com/PZH1gdmu/CMP40HX-Unlock（**仓库与账号 2026-10-10 已不可访问**，GitHub API 返回 404） |
| 许可 | **MIT**（其仓库 `LICENSE` 为 `MIT License` + `Copyright (c) 2026`；2026-10-02 核对。原声明与许可证文本已按 MIT 要求完整保留在仓库根目录 `LICENSE`） |
| 本包用到的部分 | 解锁原理与寄存器/Gen2 研究结论、驱动选型（**仅原理与结论**，当前包内无任何上游二进制）。其 Windows 侧 helper（`CMP40HXGen2.exe` / `AutoRetrain.cmd` / `Status.cmd` / `Uninstall_Auto.cmd`）曾随包分发（与 `CMP40HX-Unlock-OnlyEFI` v0.1.1 发布包同名文件逐字节相同，md5 对照见第 6 节），已全部移除、不再分发：前两个 2026-10-10 随"停 ACE 降级链"移除，后两个 2026-10-12 移除（功能由自写的 状态自检.bat / 一键卸载.cmd 覆盖） |

> 本包**不调用**上游安装器（`40HXInstaller.exe`）—— 它会覆盖 ESP 上 OnlyEFI 的解锁固件，导致 Gen2 永远落不了地。
> 本包的安装器自己完成 ESP 固件写入、NVRAM 启动项、开机任务注册与驱动自愈。

## 1b. 上游项目（ReBAR 版解锁固件的基线，2026-10-14 新增）

| 项 | 内容 |
|---|---|
| 项目 | **cmpunlocker**（CMP 40HX 解锁的独立可编译实现） |
| 地址 | https://github.com/Cyridd/cmpunlocker （**2026-10-14 用 GitHub API 核对：仓库公开、许可 MIT**） |
| 许可 | **MIT**（其仓库 `LICENSE` 为 `MIT License` + `Copyright (c) 2026 Cyridd`；文件 sha `5f79cc347f6fdcfa524481626346533534f659d9`。版权声明与许可全文已按 MIT 要求完整保留在仓库根目录/包根的 `LICENSE`） |
| 本包用到的部分 | ① `payload\EFI\40HXUNLK-REBAR.EFI`（带 ReBAR 的解锁固件）**以它的 `unlock40x_v70.c` 为基线自行编译**：在该源码上追加"生产版 Gen2 预埋"（XVE_OVR / LINK_CONFIG_0 / PRIV_MISC_1 / CYA_0 + 双端 TLS）与 ReBAR 的 XVE + BAR1 配置，并做了 40HX-only 的 blob 精简；② Windows 侧 4 处做法借鉴：GSP 显示类子键的硬件绑定判定、Secure Boot 静默拦截点名、ReBAR/BAR1 只读读出、UAC 提权路径不再内嵌路径 —— 这四处**按本项目代码自行实现**，不是原样拷贝 |
| 为什么需要它 | 上游 CMP40HX-Unlock 的解锁固件是二进制路线（无源码可改）；cmpunlocker 提供**可编译的 C 源码**（与我们生产线 EFI 同源：11 个 blob 逐字节命中），本包的 ReBAR 版固件因此才有源码级可追溯性 |

> 交付件 `payload\EFI\40HXUNLK-REBAR.EFI` 的冻结 sha256 = `DB28D8035B21DD6560201BDC2DF42FA44FADA2D8E590296C8A60D6639821F44F`（安装器与试跑脚本都按它做哈希门禁）。

## 2. 解锁固件（EFI）

| 项 | 内容 |
|---|---|
| 项目 | **CMP40HX-Unlock-OnlyEFI** |
| 地址 | https://github.com/BardKing-CN/CMP40HX-Unlock-OnlyEFI |
| 版本 | v0.1.1 |
| 许可 | **MIT**（其仓库 `LICENSE` 为 `MIT License` + `Copyright (c) 2026`；2026-10-02 核对，2026-10-10 再次核对一致） |
| 本包用到的部分 | `payload\EFI\40HXUNLK.EFI`（算力解锁 + 4 个 Gen2 策略寄存器 RMW + 根端口 TLS；**故意不在 EFI 里重训链路**） |
| ReBAR 版变体（本包自编） | `payload\EFI\40HXUNLK-REBAR.EFI` = 上游 **Cyridd/cmpunlocker** 源码 + 我们对它的修改（按 MIT 再分发）—— 算力解锁 + Gen2 预埋 + 8 GiB ReBAR；装 ReBAR 时由 `一键解锁40HX.ps1` 写进 ESP 并设为第一启动项 |

## 3. 第三方内核驱动（BYOVD 类工具）

| 文件 | 用途 | 说明 |
|---|---|---|
| `ThrottleStop.sys` | （历史）老路径写 PCIe 配置空间 + 重训 | **2026-10-12 起退役，不再随包分发/部署**（它一加载就触发 ACE 兼容性弹窗）；老版本装过的机器由开机脚本保持停用，卸载时清除 |
| `WinRing0x64.sys` | 读/写 PCI 配置空间（v1.2.0.5） | 新路径在用 |
| `inpoutx64.sys` + `inpoutx64.dll` | 读写 GPU BAR0（MMIO） | 新路径在用（Red Fox UK 签名） |

这些驱动都是"能读写物理内存/配置空间"的内核工具（技术上属 BYOVD 工具），**所有 CMP 40HX 的 PCIe 解锁方案都依赖同类驱动**，
因此杀软报警、被"易受攻击驱动"策略拦截都属预期现象（本包有多源自愈会把它们补回来）。它们均自带数字签名，随包以 **base64 文本**（`*.b64`）分发，避免一解压就被杀软删除。

> **授权**：这三个驱动**都不是本项目的作品** —— 著作权与许可条款归**各自的作者 / 发布方**所有（本包未修改它们，按原样以 base64 文本分发）。**具体授权条件以其各自原作者的说明为准**；若你是上述任一权利人并认为本包的分发方式不妥，请提 issue，我们会立即调整或移除相应内容。

## 4. 本仓库自己写的东西（保留所有权利，禁止转售）

`Install-40HXUnlock.ps1`、`一键解锁40HX.bat` / `一键解锁40HX.ps1`（唯一入口：只读体检 → 推荐 → 菜单/强制解锁）、
`payload\windows\40hx-retrain-inpout.ps1`（含 Gen2 Stage2 与 PASS/FAIL 判定）、`RunPostBind.cmd`、`ACE-Toggle.ps1`、`Unpack-Drivers.ps1`、
`一键修复Gen2.*`、`试跑REBAR.*`、`验证REBAR.ps1`、`状态自检.bat`、`工具-测试与修复\**`、`文档\**`、`排查指引.md` ——
`Copyright (c) 2026 nie2100`，**保留所有权利（All rights reserved）**，**不在 MIT 授权范围内**（见 `LICENSE` 第一部分）：

- 允许：在你**自有的** CMP 40HX 设备上按文档安装、使用、备份、修改（自用）。
- 禁止（未经作者书面许可）：再分发、二次打包、改名销售、转卖，或作为商品 / 服务 / 教程的一部分对外提供。
- 想在自己的项目里复用这部分、或做商业分发 → 先联系作者取得书面许可。
- **上游部分（含我们对其的修改）仍然是 MIT**，那部分的再分发按 MIT 走即可（见 `LICENSE` 第二部分）。

> 2026-10-10 当天曾一度（约半小时）把自写部分也声明为 MIT，**同日更正为本节写法**：自写部分保留所有权利。
> 在那期间拿到 MIT 版本的人，对其已获得的副本仍可依 MIT 使用；从本版起，自写部分不再对外授权 MIT。

## 5. 其它

- 本包会以 base64 内嵌上述二进制；`payload\sha256.txt` 里是逐文件 MD5 与字节数，可自行校验。
- 若你是上述任一项目的作者并认为本包的分发方式不妥，请提 issue，我们会立即调整或移除相应内容。

## 6. 许可继承与衍生边界（2026-10-10 许可合规改造）

**许可继承**：上游 `PZH1gdmu/CMP40HX-Unlock` 的仓库与账号现均已不存在（2026-10-10 用 GitHub API 核实：返回 404），
但它当初公开的 **MIT 授权是永久且不可撤销的**，本仓库据此继续合法使用与再分发。按 MIT 的要求，我们做了三件事：

1. **完整保留原始版权声明与许可证文本**（`Copyright (c) 2026`）—— 见仓库根目录与包根目录的 `LICENSE`；
2. **明确声明自写部分的授权**：保留所有权利、禁止转售（`Copyright (c) 2026 nie2100`，见 `LICENSE` 第一部分）—— 这**不改变**上游部分仍然是 MIT 这个事实；
3. **逐项记录来源**（本文件），并让 `LICENSE` 随包分发：一键包目录里已放 `LICENSE`（`oneclick/LICENSE`），本轮之后打出的 Release zip 会自动带上它（**线上最新的 `pkg-20261008aa` 是在这次改造之前打的，里面没有**—— 已核对：那 78 个条目里没有 `LICENSE`）。

**衍生边界**（哪些来自上游、哪些是本仓库自写）：

| 部分 | 来源 | 说明 |
|---|---|---|
| 解锁原理、寄存器 / Gen2 研究结论、驱动选型 | 上游 CMP40HX-Unlock | 结论与思路沿用（上游仓库已不可访问，无法再逐行比对） |
| Windows 侧 helper（**全部为历史记录，2026-10-12 起不再分发**）：`Status.cmd` / `Uninstall_Auto.cmd` / `CMP40HXGen2.exe` / `AutoRetrain.cmd` | 上游 **CMP40HX-Unlock-OnlyEFI v0.1.1** 发布包的 `windows\` 目录（其源码为包内 `source/windows/CMP40HXGen2_prod.c`） | 曾按原样分发（未重编译、未改写），现已全部移除（功能由本仓自写的安装器/状态自检/卸载器覆盖）；历史 md5 留档：`CMP40HXGen2.exe` `1490de9bd90105e6ebc73e50abecc5cf`、`AutoRetrain.cmd` `0021c1978b749ee7e55834e2aa7ef59a`、`Status.cmd` `6e3f7dbd75d2e59fd824c195b7278477`（仓内上游原包存档 `payload/onlyefi-v0.1.1/` 与历史快照 `payload/windows-live/` 仍含，仅作来源证据） |
| `payload\EFI\40HXUNLK.EFI`（OnlyEFI v0.1.1） | 上游 CMP40HX-Unlock-OnlyEFI | 按原样分发（安装器还会用 sha256 核对是不是这份固件） |
| ReBAR 版解锁固件 `payload\EFI\40HXUNLK-REBAR.EFI`（编译自 Cyridd/cmpunlocker 的 `unlock40x_v70.c` + 我们追加的 Gen2 预埋与 ReBAR 代码） | 上游 **Cyridd/cmpunlocker**（MIT）+ 本仓库自写增量 | 上游部分仍是 MIT（保留其版权声明与许可文本）；我们自写的增量部分归本仓库（保留所有权利） |
| Windows 侧 4 处借鉴做法（GSP 硬件绑定判定 / Secure Boot 点名 / ReBAR 读出 / UAC 提权路径） | 思路来自上游 **Cyridd/cmpunlocker**（MIT） | 结论与思路沿用，代码为本仓库自行实现 |
| 一键包安装器、**唯一入口 `一键解锁40HX.bat`/`.ps1`（只读体检 → 推荐矩阵 → 菜单/强制解锁 → ReBAR 部署与撤销）**、开机任务与多源自愈、首选路径 `40hx-retrain-inpout.ps1`（含并入的 Gen2 Stage2）、GSP 三态判定、状态自检与各修复工具、全部文档 | 本仓库自写（`Copyright (c) 2026 nie2100`，**保留所有权利**、禁止转售） | 上游没有这些；上游安装器（`40HXInstaller.exe`）本包**不调用**。其中 "Above 4G 的免驱动只读判据（CIM MMIO 窗口）" 与推荐/强制逻辑均为本项目自研 |
| `WinRing0x64.sys` / `inpoutx64.sys` / `inpoutx64.dll` | 各自原作者 | 自带数字签名，按 base64 文本原样分发 |
| `ThrottleStop.sys`（历史记录） | 原作者 | 曾按 base64 文本分发；2026-10-12 起退役，不再随包分发 |

> 若你是上游作者／权利人或认为本文件记录有误，请提 issue：核实后我们立即修正、或按要求移除相应内容。
