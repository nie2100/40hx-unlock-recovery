# 第三方来源与许可（THIRD_PARTY）

本包（`40hx-oneclick`）不是从零写的：**它建立在下面这些开源项目之上**。这里逐项写清来源、用到了什么、许可是什么。

## 1. 上游项目（本包的基础）

| 项 | 内容 |
|---|---|
| 项目 | **CMP40HX-Unlock** |
| 地址 | https://github.com/PZH1gdmu/CMP40HX-Unlock |
| 许可 | **MIT**（见其仓库 `LICENSE`，`Copyright (c) 2026`；2026-10-02 核对） |
| 本包用到的部分 | 解锁原理与寄存器/Gen2 研究结论；Windows 侧 helper 二进制与脚本：`payload\windows\CMP40HXGen2.exe`、`AutoRetrain.cmd`、`Status.cmd`；驱动选型 |

> 本包**不调用**上游安装器（`40HXInstaller.exe`）—— 它会覆盖 ESP 上 OnlyEFI 的解锁固件，导致 Gen2 永远落不了地。
> 本包的安装器自己完成 ESP 固件写入、NVRAM 启动项、开机任务注册与驱动自愈。

## 2. 解锁固件（EFI）

| 项 | 内容 |
|---|---|
| 项目 | **CMP40HX-Unlock-OnlyEFI** |
| 地址 | https://github.com/BardKing-CN/CMP40HX-Unlock-OnlyEFI |
| 版本 | v0.1.1 |
| 许可 | **MIT**（见其仓库 `LICENSE`，`Copyright (c) 2026`；2026-10-02 核对） |
| 本包用到的部分 | `payload\EFI\40HXUNLK.EFI`（算力解锁 + 4 个 Gen2 策略寄存器 RMW + 根端口 TLS；**故意不在 EFI 里重训链路**） |

## 3. 第三方内核驱动（BYOVD 类工具）

| 文件 | 用途 | 说明 |
|---|---|---|
| `ThrottleStop.sys` | 老路径（legacy）写 PCIe 配置空间 + 重训 | 本包默认**不让它加载**（ACE 会拦、也会弹"兼容性"提示）；仅作回退路径 |
| `WinRing0x64.sys` | 读/写 PCI 配置空间（v1.2.0.5） | 新路径在用 |
| `inpoutx64.sys` + `inpoutx64.dll` | 读写 GPU BAR0（MMIO） | 新路径在用（Red Fox UK 签名） |

这些驱动都是"能读写物理内存/配置空间"的内核工具（技术上属 BYOVD 工具），**所有 CMP 40HX 的 PCIe 解锁方案都依赖同类驱动**，
因此杀软报警、被"易受攻击驱动"策略拦截都属预期现象（本包有多源自愈会把它们补回来）。它们均自带数字签名，随包以 **base64 文本**（`*.b64`）分发，避免一解压就被杀软删除。

## 4. 本仓库自己写的东西

`Install-40HXUnlock.ps1`、`payload\windows\40hx-retrain-inpout.ps1`、`RunPostBind.cmd`、`ACE-Toggle.ps1`、`Unpack-Drivers.ps1`、
`一键修复Gen2.*`、`状态自检.bat`、`工具-测试与修复\**`、`文档\**`、`排查指引.md` —— 版权归作者，**未附额外许可**（默认保留所有权利）。
如果你想在自己的项目里复用这部分，请先联系作者。

## 5. 其它

- 本包会以 base64 内嵌上述二进制；`payload\sha256.txt` 里是逐文件 MD5 与字节数，可自行校验。
- 若你是上述任一项目的作者并认为本包的分发方式不妥，请提 issue，我们会立即调整或移除相应内容。
