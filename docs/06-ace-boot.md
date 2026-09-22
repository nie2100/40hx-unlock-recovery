# 06 — 过 ACE：腾讯反作弊预启动模式（ACE-BOOT）拦截解 Gen2 驱动

> 实测日期：**2026-09-22**（本机 Windows 11 build 26200）。
> 结论先行：**ACE 只拦 Gen2 需要的那两个 BYOVD 驱动的"映像加载"，与算力解锁无关**；厂商文档没写的关键一步是
> **`sc stop ACE-BOOT` 会永远卡在 `STOP_PENDING`——必须先杀掉用户态 `ACE-Tray.exe`**。做完这步，
> 「反作弊正常运行 + Gen2 已落地」可以长期并存，不需要禁用 ACE。

---

## 1. 症状与判据（怎么确认是 ACE 干的）

某次开机后：

1. 桌面弹 ACE 提示：
   ```
   检测到与游戏可能存在兼容问题的软件程序加载:
   C:\Windows\System32\drivers\ThrottleStop.sys
   ```
2. 开机任务那条记录变红：`CMP40HX Gen2 PostBind` 上次结果 = **30**，
   `...\windows\logs\last.log`：
   ```
   ==== CMP40HX Gen2 v0.1.1 package / v0.1.0 core auto run 2026/09/22 20:50:32 ====
   [SC] StartService 失败 31:
   连到系统上的设备没有发挥作用。
   FATAL: ThrottleStop service did not start.
   ```
   （`postbind.log` 对应 `ATTEMPT 1 exit=30` → `PostBind EXIT=30` → `FAIL: post-bind step did not reach Gen2`）
3. **同一次开机 ESP `40hx_log.txt` 里仍然有**：
   ```
   [40HX] *** UNLOCKED (SS0=0x88888888 SS1=0x8) ***
   [efi-b] Root TLS=Gen2; GPU TLS intentionally unchanged
   [efi-b] NO-RETRAIN: TLS2 set; skip EFI retrain
   ```
   → **算力是好的**（走 EFI，ACE 管不到）；坏的只是 Gen2 的 Windows 侧落地那一步。别把整机判成"解锁崩了"。

排除项（都实测过，不是它们）：

| 嫌疑 | 实测 | 结论 |
|---|---|---|
| 系统 WDAC 易受攻击驱动列表 | `VulnerableDriverBlocklistEnable = 0`（`reg query`） | 不是它 |
| 驱动文件被删/火绒清场 | `System32\drivers\ThrottleStop.sys` 在、md5 正常；`sc query ThrottleStop` 存在 | 不是它 |
| 厂商 v3.2 的"关易受攻击驱动列表"开关 | 本机本来就是关的 | 用不上 |

真正的拦截者：**`ACE-BOOT`**（`\??\C:\Program Files\AntiCheatExpert\ACE-BOOT.sys`，`TYPE=1 KERNEL_DRIVER`，
`START_TYPE=1 SYSTEM_START`）——腾讯 ACE「反作弊预启动模式」的引导期内核驱动，在**映像加载阶段**拦；
`SC` 返回的 **错误 31 = ERROR_GEN_FAILURE「连到系统上的设备没有发挥作用」** 就是它给出的拒载信号。

**只有 `ThrottleStop.sys` 被拦**：同目录的 `WinRing0x64.sys` 不受影响（它不在 ACE 的名单里）。
厂商 README v3.2 §5.2 有同款结论。

---

## 2. 厂商文档没写的关键一步：杀 `ACE-Tray.exe` 才能停掉 ACE-BOOT

**只 `sc stop ACE-BOOT` 是停不掉的**：命令返回 `stop exitcode=0`，但服务**永久卡在 `STOP_PENDING`**
（实测持续 4 分钟以上，远超正常卸载时间），此时 `sc start ThrottleStop` 依旧 `exit 31`。

根因：用户态托盘进程 **`ACE-Tray.exe`**（就是弹那个提示框的程序）持有 ACE-BOOT 的句柄，内核驱动卸载
在等它释放。**必须先结束托盘进程**（等价于托盘图标右键 →「退出」）：

```
taskkill /IM ACE-Tray.exe /F
sc stop ACE-BOOT          :: 这次立刻 STOPPED（A/B 实测 t+5s 内）
sc start ThrottleStop     :: start exitcode=0 → STATE=RUNNING
```

实测对照（同一天两次，互为 A/B）：

| 时刻 | ACE-BOOT 状态 | 动作 | 结果 |
|---|---|---|---|
| 20:50:27 | RUNNING | 只 `sc stop` | 卡 `STOP_PENDING` → 跑任务仍 `EXIT=30` |
| 20:51:26 | STOP_PENDING（已卡 1 分钟+） | `taskkill ACE-Tray` → `sc stop`（报 `1062 服务尚未启动`）→ t+5s 起 `STATE=STOPPED` 稳定 | `sc start ThrottleStop` = `exitcode=0`，`STATE=4 RUNNING` |
| 21:03 | 已停 | 直接跑任务 | `EXIT=0` + `PASS` |
| 21:04 | ACE-BOOT 运行中 | 脚本自动"杀托盘 → 停 → 重训 → 恢复" | `EXIT=0` + `PASS`（`PASS: already physical Gen2 x16; no writes needed.`） |

**误判陷阱**（看到别紧张，都是同一个拦截图的不同表现）：
- `sc query ThrottleStop` 的 `WIN32_EXIT_CODE : 31 (0x1f)`；
- 系统事件日志 SCM **7000**「ThrottleStop 服务没能发挥作用」；
- `sc stop ACE-BOOT` 返回成功 → 不等于 ACE 真停了，**必须查 `STATE`**。

---

## 3. 解锁完把反作弊拉回来，Gen2 不会被撤销

Gen2 是**链路寄存器状态**（`LNKSTA`），不是"驱动常驻"状态；驱动卸载/停止不改变链路速率。所以：

```
sc config ACE-BOOT start= system      :: 原本就是 SYSTEM_START
sc start ACE-BOOT                     :: 回到 RUNNING
CMP40HXGen2.exe                       :: 复跑 helper 验证
→ PASS: already physical Gen2 x16; no writes needed.
```

实测在 `sc start ACE-BOOT` 之后复跑 helper 得到上述输出 → 日常状态 = **反作弊正常运行 + Gen2 已解锁**，
腾讯游戏不需要重启机器。**不要**为了解锁去持久禁用 ACE-BOOT（厂商 v3.2 ① 区那个开关）：没必要，
而且腾讯游戏会要求你恢复它（厂商卸载器也会把启动类型还原成 SYSTEM_START）。

---

## 4. 已实装自动化（开机即自愈，无需人工）

改的是**本机自写的** `C:\ProgramData\CMP40HXGen2\windows\RunPostBind.cmd`（**不碰 ESP / EFI**），
新增三个子过程，开机任务流程变成：

```
:ace_off    → sc query ACE-BOOT；在跑就 sc stop，等 20s；
              仍 STOP_PENDING 才 taskkill /IM ACE-Tray.exe /F，再等 40s
            → :heal（补驱动 / 补服务，多源 + ESP 兜底）
            → AutoRetrain.cmd（跑 helper；失败重试 3 次，间隔 15s）
            → 只有 EXIT=0 才 :ace_on（sc config start= system + sc start）
              失败就保持 ACE-BOOT 停机，便于下一次重试
```

要点：
- **只放行成功路径**：`if "!RC!"=="0" call :ace_on` —— 重训失败时不去恢复反作弊，避免"ACE 又被拉起、
  驱动又加载不了"的死循环，也留着窗口让你手工重跑一次任务。
- **真·开机（BootTrigger）路径不需要杀托盘**：开机那一瞬 `ACE-Tray.exe` 还没启动（它是登录后由
  HKLM Run 拉起的），所以不持有 ACE-BOOT，`sc stop` 直接成功。实测 **2026-09-22 22:08** 那次
  开机任务 `postbind.log` 里**没有** `killing ACE-Tray` 行，只有 `ACE: ACE-BOOT stopped` → `EXIT=0`。
  22:40 手工重跑时托盘在，日志出现 `ACE: stop still pending - killing ACE-Tray.exe (it keeps ACE-BOOT open)`，
  也同样 `EXIT=0`。两条路径都验过。
- **脚本不负责重启 `ACE-Tray.exe`**：任务以 SYSTEM 跑，`start` 只会把托盘扔进 session 0（用户看不见）。
  杀过托盘的那次登录需要手工跑一次
  `"C:\Program Files\AntiCheatExpert\ACE-Tray.exe"`，或等下次登录由 HKLM Run 自动恢复。
- 备份：改前的原文件 `RunPostBind.cmd.bak-20260922-ace`（md5/sha256 见 `INVENTORY.txt`），
  仓库里另存一份改前版本 `payload/windows-live/RunPostBind.no-ace.cmd.bak`。

### 改 `.cmd` 踩过的两条硬规矩（都真踩了）

1. **别用 Python 的 `b.find(b':label')` 定位标签**：`call :label` 里也含 `:label` 字符串，
   从调用点开始替换会把主流程（`set RC=99` + `for` 重试循环）整段吃掉。
   症状：`postbind.log` 只有 `start` 没有 `attempt`/`EXIT`，`last.log` 不再更新。
   正确姿势：从备份重建，用 `set "RC=99"` / PASS-FAIL 行这种**唯一锚点**插入。
2. **`echo` 文本里不能带括号**：`if (...) ( >>log echo xxx (yyy) )` 里的 `)` 会提前闭合 `if` 块，
   导致 if/else 两个分支都执行（症状：日志里 `PASS` 与 `WARN` 同时出现）。

---

## 5. 厂商 v3.2 诊断报"驱动未拉起 / 仅日志确认"= 稳态误判，别照它执行

装好上面的自动化后，**在任意平时的时刻**跑厂商 `40HXCheck.exe` 都会得到：

> 算力满血 + Gen2 达成 —— 但 ↑ 驱动未拉起（多为 ACE 拦截） —— 以上为[日志]确认，非本次实测
> 建议：① 勾选[禁用 ACE-BOOT] ② 或改走 EFI 路径

**这是误判，不是故障**：诊断要临时拉起 BYOVD 驱动来现场读寄存器，而稳态下 ACE-BOOT 早被开机任务
按设计恢复成 `RUNNING` → 映像加载阶段被拦（SC 31）→ 它才退化成读日志。**只有开机任务运行的那十几秒
ACE-BOOT 才是停的**。两条建议在本机都不要执行：① 持久禁用无意义（已实现并存）；② 换厂商 EFI 会覆盖
ESP 上 OnlyEFI 的固件 → 重演 `exit 14`（Gen2 永不落地）。

要**实时**证据不必跑厂商工具，看自有 helper 的日志就够：

```
GUARD=PASS SS0=0x88888888 SS1=0x00000008
TLS GPU=2 ROOT=2
GPU final: Gen2 x16 LNKSTA=0x1102
ROOT final: Gen2 x16 LNKSTA=0xF102
PASS: already physical Gen2 x16; no writes needed.
```

再补一条**功能性**实测（可选，最硬）：`release-v3.2.0\OpenCL.exe`（stdin 喂一个回车）会标注
`PCIe Bandwidth (bidirectional) (Gen2 x16)` 且 FP32 ≈ 8.35 TFLOPs/s / FP16 ≈ 16.6 / INT8 ≈ 31.3 TIOPs/s。
⚠ 它会把机器上所有 GPU 依次跑一遍，**认 `Device Name` 别认序号**。

厂商工具还会"测完即卸"：删掉 `System32\drivers\ThrottleStop.sys` / `WinRing0x64.sys` **和两个服务**，
跑完要按 `RunPostBind.cmd` 的 `:heal` 语义补回（从 `C:\ProgramData\40HXUnlock\drivers` 等源拷贝 +
`sc create ... start= demand`），否则后续 helper 报 `cannot open \\.\ThrottleStop`（退出码 10）。

**排查顺序**（避免白折腾）：先看 ESP `40hx_log.txt` 的 `UNLOCKED` 行 + `last.log` 的 `GUARD`/`EXIT`，
再 `nvidia-smi`，最后才考虑跑厂商工具。

---

## 6. 状态自检：`scripts\40HX解锁状态.bat`

本仓库 `scripts\40HX解锁状态.bat`（本机桌面同名文件）双击即可出结论，**6 步**（2026-09-23 升级：原 5 步，新增第 4 步「算力验证」）：

| 步骤 | 内容 | 判据 |
|---|---|---|
| 1 | `nvidia-smi` 读显卡 / 驱动 / 显存 / 温度功耗 / 链路宽度 | 能出数 |
| 2 | 驱动模式 `driver_model.current` | 必须 `WDDM`（`TCC` = WSL 直通失效且 PCIe 会掉回 Gen1） |
| 3 | **CUDA ctypes 实测链路带宽**（内嵌 base64 的 Python：`cuMemcpyHtoD_v2`/`DtoH_v2` 各 10 次 512MB，带 `cuCtxSynchronize` 正确计时） | H2D ≥ 4.5 GB/s 判 `GEN2`；Gen1 ≈ 3.1–3.4，Gen2 ≈ 5.8–6.7 GB/s |
| 4 | **算力验证**（同一个内嵌 Python 用 PTX kernel 实测，SM 数取 `cuDeviceGetAttribute(16)`） | SM 单元 ≥ 34（本机 34 SM / 2176 CUDA 核心）、FP32 ≥ 7.0、FP16 ≥ 13.0、FP16 Tensor Core ≥ 40.0 TFLOPS、显存带宽 ≥ 330 GB/s；满血基线 FP32 8.3–8.4 / FP16 ~16 / TC 51+ / 显存 ~400 |
| 5 | `CMP40HXGen2\windows\logs\postbind.log` 尾 3 条 `PostBind start/EXIT/PASS` | 该轮 `EXIT=0` + `PASS` |
| 6 | `C:\ProgramData\40HXUnlock\gen2_status.txt`（厂商工具写的状态文件） | 参考 |

> 第 3、4 步共用同一个内嵌 Python（约 15 秒），全程只走 CUDA 运行时 —— **不需要管理员权限，也不加载 BYOVD 驱动**。

三项（WDDM / Gen2 / 算力）全过才打印 `结论: 全绿 -- WDDM + PCIe Gen2 + 算力满血, 解锁正常`；异常时逐条提示
`- 驱动模式不是 WDDM`（`nvidia-smi -dm 0` 后重启）/ `- PCIe 未达 Gen2`（先重启让开机任务重训；
仍不行检查 ACE-BOOT 是否拦截 ← 就是本文）/ `- 算力低于基线`（查是否降频 / 高温 / 驱动未正常加载）。

**这是本文档的判据落地版**：不依赖 `nvidia-smi` 的 `pcie.link.gen.current`（会动态降速到 1，见 `docs/03` C1），
而是用**实测带宽**；第 4 步再用**实测算力**交叉验证 `SS0=0x88888888` 解锁态是否真的生效
（核心被砍 / 降频 / TC 被关会直接暴露出来）。

---

## 7. 时间线（2026-09-22 实测全过程）

| 时间 | 事件 |
|---|---|
| 20:43:38 | 该次开机固件日志写入：`UNLOCKED (SS0=0x88888888 SS1=0x8)` + `NO-RETRAIN` → 算力与 Gen2 预埋都正常 |
| 20:49:10 | 现场诊断：`ThrottleStop` 服务 `STOPPED` + `WIN32_EXIT_CODE 31`，`sc start` 失败 31；`VulnerableDriverBlocklistEnable=0`；ESP 两个 EFI 哈希 = OnlyEFI `1e9ca43f…`（没被覆盖）；三个 40HX 任务状态正确；`ACE-Tray.exe` 在跑 |
| 20:50:27 | `sc stop ACE-BOOT` → **卡 STOP_PENDING**；跑任务仍 `EXIT=30` |
| 20:51:26 | `taskkill ACE-Tray` → `sc stop` → **STOPPED 稳定** → `sc start ThrottleStop` = **exitcode 0 / RUNNING** → 定位成功 |
| 21:03 | ACE-BOOT 已停状态下跑开机任务：`EXIT=0` + `PASS` |
| 21:04 | ACE-BOOT 运行状态下跑开机任务：日志出现 `killing ACE-Tray.exe` → 自动停/重训/恢复 → `EXIT=0` + `PASS: already physical Gen2 x16` |
| 21:07 | 任务结果 `lastResult=0`，ACE-BOOT 已恢复 `STATE=RUNNING` / `START_TYPE=SYSTEM_START` |
| 22:08 | **真·开机（BootTrigger）验证**：托盘未启动，无需杀进程，`sc stop` 直接成功 → `EXIT=0` |
| 22:40 | 稳态复跑：`ACE: ACE-BOOT running - temporary stop…` → `ACE: ACE-BOOT stopped` → `EXIT=0` → 自动恢复 `ACE-BOOT restored (SYSTEM_START)` |

**仍未验证**（诚实标注）：玩腾讯游戏时是否弹"需重启"（厂商说不会）；`ACE-Tray.exe` 被 SYSTEM 会话
杀掉后，若用户不手工重开托盘、也不重新登录，托盘图标会缺一次会话。

---

## 8. 恢复机器时这一节怎么做（照做即可）

1. 按 README 主流程把 OnlyEFI EFI + Windows 侧 helper + 开机任务装好；
2. 装回腾讯 ACE（正常安装腾讯游戏即会带回 `ACE-BOOT`）；
3. 用本仓库的 `payload/windows-live/RunPostBind.cmd`（**已是含 `:ace_off`/`:ace_wait`/`:ace_on` 的版本**）
   覆盖 `C:\ProgramData\CMP40HXGen2\windows\RunPostBind.cmd`；
4. 开机验证：`postbind.log` 出现
   `ACE: ACE-BOOT running - temporary stop so the Gen2 driver can load` → `ACE: ACE-BOOT stopped`
   → `---- attempt 1 ----` → `PostBind EXIT=0` / `PASS: physical Gen2 post-bind step succeeded`
   → `ACE: ACE-BOOT restored (SYSTEM_START)`；
5. 随时用 `scripts\40HX解锁状态.bat` 确认全绿。

**没装 ACE 的机器**：`:ace_off` 会打印 `ACE: service ACE-BOOT not present` 后直接返回 0，
其余流程不受影响（幂等，可安全使用同一份脚本）。
