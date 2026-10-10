# CMP 40HX 解锁 + 恢复（算力满血 + PCIe Gen2 x16）

> **一句话**：让一张 CMP 40HX 矿卡在 Windows 上恢复被砍掉的算力，并把 PCIe 从 Gen1 提到 **Gen2 x16**，
> 而且**每次开机自动保持**。整套东西自含、离线、双击即装。

## ⬇ 下载（点这一条就够，不用点 Code、不用看懂 GitHub）

| 你要什么 | 怎么拿 |
|---|---|
| **一键包（推荐；装机器只用它）** | [点此直接下载 `40hx-oneclick.zip`](https://github.com/nie2100/40hx-unlock-recovery/releases/latest/download/40hx-oneclick.zip)（约 0.7 MB）→ 解压 → 双击 `一键安装.cmd` |
| 整个仓库（原理文档 + 实测证据 + 源码） | 绿色 **`Code`** 按钮 → **`Download ZIP`**（约 3 MB）。这是**整个仓库**，装机器时只用里面 **`oneclick/`** 那一层目录 |
| 国内下载慢 / 超时 / 打不开 | 在链接前面加镜像前缀 `https://ghfast.top/`，例：`https://ghfast.top/https://github.com/nie2100/40hx-unlock-recovery/releases/latest/download/40hx-oneclick.zip` |

> 一键包的 **sha256 写在对应 Release 的说明里**（[所有版本](https://github.com/nie2100/40hx-unlock-recovery/releases)），下载后可自行核对。

---

## 〇、开装之前：BIOS 里必须先改的 5 项（脚本替你做不了）

> 现场"装完没效果 / 认不到卡 / 代码 43"绝大多数栽在这里。各家 BIOS 菜单名不一样，
> 按**关键词**找（很多 BIOS 支持直接搜 `4G` / `CSM` / `Secure Boot`）。

| # | 改什么（常见叫法） | 设成 | 不改会怎样 | 常见位置 |
|---|---|---|---|---|
| 1 | **Above 4G Decoding**（4G 以上解码 / 大地址解码 / Above 4G memory） | **Enabled** | **头号失败原因**。40HX 是 8 GB 显存，显存 BAR 要落在 4 GB 以上地址空间；关着就认不到卡、或设备管理器"代码 43"、甚至开机黑屏 | 华硕/ROG：`Advanced → System Agent (SA) Configuration`；技嘉：`Settings → IO Ports`；微星：`Settings → Advanced → PCI Subsystem Settings`（矿版叫 `Above 4G memory/Crypto Currency mining`）；华擎：`Advanced → Chipset Configuration` |
| 2 | **CSM**（Launch CSM / 兼容性支持模块 / CSM Support） | **Disabled**（= 纯 UEFI 引导） | 固件会按 Legacy 引导 → 脚本判定"固件不是 UEFI 模式"直接中止安装（前提不满足）；解锁固件也不会被执行 | `Boot → CSM` |
| 3 | **Secure Boot**（安全启动） | **Disabled**（华硕老 BIOS 选 `Other OS`） | 解锁固件 `40HXUNLK.EFI` 是**未签名**的，Secure Boot 开着它就不执行 → 算力一直是未解锁状态 | `Security → Secure Boot` |
| 4 | **Fast Boot**（快速启动） | **Disabled** | 它会和 Windows 的"快速启动"叠加成**混合关机** → GSP/驱动改动不生效（代码 43 的根因之一） | `Boot → Fast Boot` |
| 5 | 该 x16 槽的 **PCIe 速率**（PCIe Speed / Link Speed） | **Auto**（别锁 Gen1） | 锁在 Gen1 就永远上不了 **Gen2 x16**（本方案的目标），拆显卡都白拆 | `Advanced`/`Chipset` 里的 PCIe 速率项 |

**同一时间顺手确认这几条（不在 BIOS 里，但同样决定成败）**：

| 项 | 要求 |
|---|---|
| 系统盘 | **GPT + UEFI**（老盘是 MBR：管理员执行 `mbr2gpt /convert /allowFullOS`） |
| BitLocker | 关掉或暂停（否则改引导链会索要恢复密钥） |
| 显示器接哪 | 40HX **没有视频输出口**：显示器接核显或另一张卡，BIOS 主显示设 `Auto` / `IGFX` 即可 |
| 启动顺序 | 开机要真的走一次 `40HX Unlock`（安装器会建这条）。被 Windows 更新/双系统改乱了：重跑 `-Mode MakeDefault`，或进 BIOS 把它排到第一位。**注意：脚本写进 NVRAM 的启动顺序 ≠ BIOS 里真的选了它** —— **第一次开机若没出现 40HX 解锁引导的跑码界面**（开机时屏幕上会先刷出几行解锁固件的文字，刷完才进 Windows），就是解锁固件没被执行 → 进 BIOS 把 `40HX Unlock` 排到第一位（2026-10-08 客户机实证：改完立刻解锁；技术人员可核对 ESP 根目录的 `40hx_log.txt` 有没有本次开机的记录） |
| 杀软 | 火绒/360：既要在"信任区"放行三个驱动，**也要单独关掉"漏洞驱动拦截"**（它是独立模块，只加信任区不生效） |

> 想先只看不改：`oneclick/Install-40HXUnlock.ps1 -Mode Check`（纯体检，0 项失败 = 环境 OK）。
> BIOS 相关的逐条报错对照在 [`oneclick/排查指引.md`](oneclick/排查指引.md) 第 3 节（退出码 2）。

---

## 一、我要怎么做（只用 `oneclick/` 这一个文件夹）

1. 下载本仓库里的 **`oneclick/`** 文件夹（或 Releases 里的 zip），拷到那台装 40HX 的 Windows 上
2. 双击 **`一键安装.cmd`** → 回车（脚本自己申请管理员）→ 等它跑完（首次约 1 分钟）
3. **完全关机再开机**：开始菜单 → 关机（**不是"重启"**），最好拔掉电源线等 10 秒。
   开机时会先闪过一段解锁固件的跑码界面，然后才进 Windows；
   进 Windows 后双击 **`状态自检.bat`**，看到 `全绿 -- WDDM + PCIe Gen2 + 算力满血` = 成功。
   若看到黄字「未实测」**别慌**（黄 ≠ 失败）：开机后台任务还要跑 1 到 3 分钟，**过 2 到 3 分钟再双击一次**就会出结论。

出问题：`oneclick/排查指引.md`（按日志原话/退出码搜）；装完黑屏或设备管理器**代码 43** → **双击包根 `GSP体检.cmd`**（代码 43 最常见的根因就是 GSP 没开；它默认就会把开关写好，写完**完全关机**再开机），要取证再跑 `oneclick/工具-测试与修复/诊断包-20260930/一键诊断.cmd`；
安装被「系统盘不是 GPT（未知）」挡住 → `oneclick/工具-测试与修复/存储体检.cmd`（只读取证，报告落桌面）。
想让脚本先只看不改：`oneclick/Install-40HXUnlock.ps1 -Mode Check`。
想卸载：`oneclick/Install-40HXUnlock.ps1 -Mode Uninstall -Yes`。

**人类友好版说明（先看这个）**：[`oneclick/README.md`](oneclick/README.md) —— 三步、成功判据、正常现象、出错找谁，一页看完。

---

## 二、仓库里都有什么

| 路径 | 是什么 | 你大概什么时候会看它 |
|---|---|---|
| `oneclick/` | **一键包**（自含、可迁移、离线）：安装器 + 解锁固件 + Windows 侧工具 + 驱动（base64） + 排错文档 | 想装机器时（**只需要这个目录**） |
| `docs/` | 原理与现场资料：硬件基线、工作机理、坑、验证判据、ACE 反作弊、恢复手册 | 想搞明白原理 / 换机器踩坑时 |
| `scripts/` | 本机（技嘉 B560M 那台）用过的单点脚本：NVRAM 读写、ESP 快照、状态自检 `.bat`、冷启动报告… | 手工排障 / 复现时 |
| `payload/` | 固件、驱动、Windows live 侧的原始载荷（与 `oneclick/payload` 同源，含 ESP 快照与 NVRAM 备份） | 重装系统后想从仓库直接恢复 |
| `evidence/` | 实测证据（日志片段、截图文本、时间线） | 想核对"真的验证过吗" |
| `THIRD_PARTY.md` | 第三方来源与许可（上游 MIT 声明、每个文件用到了什么） | 关心出处/合规时 |
| `INVENTORY.txt` | 全仓库文件清单（md5 + 字节数） | 校验完整性 |

---

## 三、出处与致谢（本项目基于上游项目改进）

| 来源 | 项目 | 用到了什么 |
|---|---|---|
| **上游（本项目的基础）** | **CMP40HX-Unlock — https://github.com/PZH1gdmu/CMP40HX-Unlock** | 解锁原理与整套 Windows 侧工具：`CMP40HXGen2.exe`（守卫 + 恢复两个策略寄存器 + 根端口重训）、`AutoRetrain.cmd`、`Status.cmd`、驱动选型与 Gen2 研究结论 |
| 解锁固件 | OnlyEFI v0.1.1 — https://github.com/BardKing-CN/CMP40HX-Unlock-OnlyEFI （MIT） | `\EFI\40HX\40HXUNLK.EFI`：算力解锁 + Gen2 策略寄存器/TLS 预埋，**故意不在 EFI 里重训链路**（这样才不会复位显卡、算力与 Gen2 才能并存） |
| 第三方驱动 | ThrottleStop.sys / WinRing0x64.sys / inpoutx64.sys | MMIO 与 PCI 配置空间读写（BYOVD 类工具，杀软报警属预期） |

**许可**：上面两个上游项目的仓库 `LICENSE` **都是 MIT**（`Copyright (c) 2026`，2026-10-02 核对；OnlyEFI 的许可证文本 2026-10-10 再次核对一致），
因此本仓库可以再分发它们的二进制。**本仓库自己写的那部分另有约定**（`Copyright (c) 2026 nie2100`，**保留所有权利**：自用可以，
未经作者书面许可不得再分发 / 二次打包 / 转卖）。两部分的范围与全文见根目录 [`LICENSE`](LICENSE)，逐项来源见 [`THIRD_PARTY.md`](THIRD_PARTY.md)。

**本仓库在它基础上做了什么**（都是"装到现场才会遇到"的坑）：

- **一键包**：不调用上游安装器（它会覆盖 ESP 上的 OnlyEFI 固件 → Gen2 永远落不了地），ESP 固件 / NVRAM 启动项 / 开机任务 / 驱动自愈全部自己写；纯离线可迁移。
- **首选路径「全程不停腾讯 ACE-BOOT」**：自写 `40hx-retrain-inpout.ps1`，用 `inpoutx64` 直写 GPU BAR0 + WinRing0 写 PCI 配置空间，只修被驱动改写的两个寄存器再重训 → 反作弊预启动模式不被破坏，游戏不再要求"重启修复"。
- **每次开机的自愈**：驱动被杀软隔离、`WinRing0` 被改成 DISABLED、服务被删、`inpoutx64` 缺文件 —— 开机任务多源（两个 ProgramData 目录 + ESP 兜底源 + base64）自动补回。
- **代码 43 的真因**：GSP 判定把 `N/A` 当"已开"+ 开关写错注册表位置 → 修成三态判定 + 写显示类权威子键，并要求**完全关机**（不是重启）才生效。
  **装/更新 NVIDIA 驱动后 GSP 默认是关的**（驱动重装会重新枚举设备，那份 `EnableGpuFirmware=1` 可能留在旧子键上不再被读）
  → 装完驱动用包内 **`GSP体检.cmd`**（= `工具-测试与修复\查GSP.cmd`）自检修复：它**默认就会把开关写对位置**（写前备份，可还原），
  条件不具备（驱动层没起来 / 驱动包里缺 `gsp_tu10x.bin`）时一个值都不写；只想看不想让它写，加 `/readonly`。改完仍要**完全关机**再开机。
- **换机器差异**：显卡/根端口位置自动探测（不再写死 `01:00.0`/`00:01.0`）、Gen2 基线按位判定（兼容不同 VBIOS 批次 `.04`/`.06`）。
- **安全加固**：驱动源目录 ACL 收紧（原来 `Users:Write` = 本地提权面）、驱动源改 base64、目录权限可一键回滚。
- **日志与指引不再骚扰**：状态正常时不生成"下一步"指引文件，日志只保留最近若干份；失败才留全档（`logs\failures\`）。

---

## 四、这套方案的两条硬事实（决定你怎么排错）

1. **算力解锁是易失的**：每次开机由 ESP 上的固件写 GPU 寄存器（SS0=0x88888888）。
   所以"上次好的、这次不行"通常等于**这次开机固件没跑**（看 `40hx_log.txt` 的时间戳）。
2. **PCIe Gen2 靠 Windows 侧在驱动 bind 之后落地**：固件只预埋策略寄存器，重训由开机任务完成。
   而且**不能复位显卡**（复位就清算力）—— 这就是本方案选用 OnlyEFI 固件 + 只重训不复位的原因。

判据（别信 `nvidia-smi pcie.link.gen.current`，空闲恒显示 1）：
- 算力：ESP `40hx_log.txt` 有 `*** UNLOCKED (SS0=0x88888888 SS1=0x8) ***`（时间戳=本次开机）
- Gen2：`工具-测试与修复` 的日志里 `GPU final: Gen2 x16 LNKSTA=0x1102` / `ROOT final: ... 0xF102`，或 `OpenCL.exe` 基准标注 `PCIe Bandwidth (bidirectional) (Gen2 x16)`

---

## 五、免责声明

解锁涉及**改引导链、注册内核驱动、写固件启动项**，有变砖风险（仓库里提供了备份与回滚，见 `oneclick/文档/风险与恢复.md`）。
只在 **CMP 40HX（`10DE:1F0B`）** 上实测过；矿卡本身可能有暗病（例如 PCIe 延长线场景会出 `0x124` WHEA 硬件错误，与解锁无关）。
解锁行为可能违反 NVIDIA/游戏厂商服务条款，**请自行判断用途**。

---

## 六、许可证（License）

本仓库（与交付包 `oneclick/`）的授权**分两部分**，全文见根目录 [`LICENSE`](LICENSE)：

| 部分 | 授权 | 你能做什么 |
|---|---|---|
| **上游部分**：`CMP40HX-Unlock`（GitHub: `PZH1gdmu`）、`CMP40HX-Unlock-OnlyEFI`（GitHub: `BardKing-CN`）的代码 / 二进制，以及我们对它们的修改 | **MIT**（其原始版权声明与许可全文完整保留在 `LICENSE` 里 —— 这是 MIT 对再分发的硬性要求） | 按 MIT：使用、修改、再分发都可以，保留版权与许可声明即可 |
| **本仓库自写部分**：一键包安装器、开机任务与自愈、`40hx-retrain-inpout.ps1`、状态自检与各修复工具、全部文档 | **保留所有权利**（`Copyright (c) 2026 nie2100`，**禁止转售 / 二次打包**） | 在自己**自有的** 40HX 设备上自用、备份、修改；**不得再分发、二次打包、改名销售或转卖**；商用先联系作者 |

- 上游 **CMP40HX-Unlock**（GitHub: `PZH1gdmu`）与固件来源 **CMP40HX-Unlock-OnlyEFI**（GitHub: `BardKing-CN`）**都是 MIT**，
  两者的**原始版权声明与 MIT 许可证文本已完整保留**在 `LICENSE` 里 —— 这是 MIT 对再分发的硬性要求。
- 上游 `PZH1gdmu/CMP40HX-Unlock` 的仓库与账号**现已不可访问**（2026-10-10 用 GitHub API 核实：返回 404），
  但它当初公开的 MIT 授权是**永久且不可撤销**的，所以本仓库继续合法地基于它开发与分发 —— 依据就是被完整保留下来的那份声明与许可证文本。
- 交付的一键包 `oneclick/` 里已经放了一份 `LICENSE`（包根），脱离本仓库单独分发时同样合规；本轮之后打出的 Release zip 会自动带上它（**线上最新的 `pkg-20261008aa` 打在这次改造之前，里面还没有**—— 已核对：那 78 个条目里没有 `LICENSE`）。
- 哪些是上游的、哪些是本仓库自写的：见 [`THIRD_PARTY.md`](THIRD_PARTY.md) 第 1、4、6 节。
