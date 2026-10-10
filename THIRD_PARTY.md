# 第三方来源与许可（仓库版）

> 本仓库根目录的 `payload/` 与 `oneclick/payload/` 是同源载荷；下面这份清单对两者都适用。
> 同一份文件也在交付包内（`oneclick/THIRD_PARTY.md`）。

---

# 第三方来源与许可（THIRD_PARTY）

本包（`40hx-oneclick`）不是从零写的：**它建立在下面这些开源项目之上**。这里逐项写清来源、用到了什么、许可是什么。

## 1. 上游项目（本包的基础）

| 项 | 内容 |
|---|---|
| 项目 | **CMP40HX-Unlock** |
| 地址 | https://github.com/PZH1gdmu/CMP40HX-Unlock（**仓库与账号 2026-10-10 已不可访问**，GitHub API 返回 404） |
| 许可 | **MIT**（其仓库 `LICENSE` 为 `MIT License` + `Copyright (c) 2026`；2026-10-02 核对。原声明与许可证文本已按 MIT 要求完整保留在仓库根目录 `LICENSE`） |
| 本包用到的部分 | 解锁原理与寄存器/Gen2 研究结论；驱动选型；以及 Windows 侧 helper 二进制与脚本：`payload\windows\CMP40HXGen2.exe`、`AutoRetrain.cmd`、`Status.cmd`（这三个文件与 `CMP40HX-Unlock-OnlyEFI` v0.1.1 发布包里的同名文件**逐字节相同**，见第 6 节的 md5 对照） |

> 本包**不调用**上游安装器（`40HXInstaller.exe`）—— 它会覆盖 ESP 上 OnlyEFI 的解锁固件，导致 Gen2 永远落不了地。
> 本包的安装器自己完成 ESP 固件写入、NVRAM 启动项、开机任务注册与驱动自愈。

## 2. 解锁固件（EFI）

| 项 | 内容 |
|---|---|
| 项目 | **CMP40HX-Unlock-OnlyEFI** |
| 地址 | https://github.com/BardKing-CN/CMP40HX-Unlock-OnlyEFI |
| 版本 | v0.1.1 |
| 许可 | **MIT**（其仓库 `LICENSE` 为 `MIT License` + `Copyright (c) 2026`；2026-10-02 核对，2026-10-10 再次核对一致） |
| 本包用到的部分 | `payload\EFI\40HXUNLK.EFI`（算力解锁 + 4 个 Gen2 策略寄存器 RMW + 根端口 TLS；**故意不在 EFI 里重训链路**） |

## 3. 第三方内核驱动（BYOVD 类工具）

| 文件 | 用途 | 说明 |
|---|---|---|
| `ThrottleStop.sys` | 老路径（legacy）写 PCIe 配置空间 + 重训 | 本包默认**不让它加载**（ACE 会拦、也会弹"兼容性"提示）；仅作回退路径 |
| `WinRing0x64.sys` | 读/写 PCI 配置空间（v1.2.0.5） | 新路径在用 |
| `inpoutx64.sys` + `inpoutx64.dll` | 读写 GPU BAR0（MMIO） | 新路径在用（Red Fox UK 签名） |

这些驱动都是"能读写物理内存/配置空间"的内核工具（技术上属 BYOVD 工具），**所有 CMP 40HX 的 PCIe 解锁方案都依赖同类驱动**，
因此杀软报警、被"易受攻击驱动"策略拦截都属预期现象（本包有多源自愈会把它们补回来）。它们均自带数字签名，随包以 **base64 文本**（`*.b64`）分发，避免一解压就被杀软删除。

> **授权**：这三个驱动**都不是本项目的作品** —— 著作权与许可条款归**各自的作者 / 发布方**所有（本包未修改它们，按原样以 base64 文本分发）。**具体授权条件以其各自原作者的说明为准**；若你是上述任一权利人并认为本包的分发方式不妥，请提 issue，我们会立即调整或移除相应内容。

## 4. 本仓库自己写的东西（保留所有权利，禁止转售）

`Install-40HXUnlock.ps1`、`payload\windows\40hx-retrain-inpout.ps1`、`RunPostBind.cmd`、`ACE-Toggle.ps1`、`Unpack-Drivers.ps1`、
`一键修复Gen2.*`、`状态自检.bat`、`工具-测试与修复\**`、`文档\**`、`排查指引.md` ——
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
| Windows 侧 helper：`payload\windows\CMP40HXGen2.exe`、`AutoRetrain.cmd`、`Status.cmd` | 上游 **CMP40HX-Unlock-OnlyEFI v0.1.1** 发布包的 `windows\` 目录（其源码为包内 `source/windows/CMP40HXGen2_prod.c`） | 按原样分发（未重编译、未改写），本包只调用其命令行接口；与 OnlyEFI 发布包同名文件逐字节相同：`CMP40HXGen2.exe` md5 `1490de9bd90105e6ebc73e50abecc5cf`、`AutoRetrain.cmd` md5 `0021c1978b749ee7e55834e2aa7ef59a`、`Status.cmd` md5 `6e3f7dbd75d2e59fd824c195b7278477` |
| `payload\EFI\40HXUNLK.EFI`（OnlyEFI v0.1.1） | 上游 CMP40HX-Unlock-OnlyEFI | 按原样分发（安装器还会用 sha256 核对是不是这份固件） |
| 一键包安装器、开机任务与多源自愈、首选路径 `40hx-retrain-inpout.ps1`、GSP 三态判定、状态自检与各修复工具、全部文档 | 本仓库自写（`Copyright (c) 2026 nie2100`，**保留所有权利**、禁止转售） | 上游没有这些；上游安装器（`40HXInstaller.exe`）本包**不调用** |
| `ThrottleStop.sys` / `WinRing0x64.sys` / `inpoutx64.sys` / `inpoutx64.dll` | 各自原作者 | 自带数字签名，按 base64 文本原样分发 |

> 若你是上游作者／权利人或认为本文件记录有误，请提 issue：核实后我们立即修正、或按要求移除相应内容。
