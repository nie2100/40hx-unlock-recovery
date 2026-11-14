# 08 — ReBAR 版解锁固件（`40HXUNLK-REBAR.EFI`）是怎么来的

> 交付位置：`oneclick/payload/EFI/40HXUNLK-REBAR.EFI`（同一份也在交付包内）
> 冻结 sha256：`9D18D135B5FD5E20EE5D5B5A7DBB7530103D0D2732E25177FA9FA525104684FC`（364,081 字节）
> 安装/试跑脚本都按这个哈希做门禁：不符直接拒绝写入 ESP。
> Windows 侧入口：`一键解锁40HX.bat` 选 `2`（常驻）或 `试跑REBAR.cmd`（一次性）。

## 1. 它和主线那个解锁固件是什么关系

主线解锁固件 `payload/EFI/40HXUNLK.EFI` 来自上游 OnlyEFI v0.1.1（`BardKing-CN/CMP40HX-Unlock-OnlyEFI`，MIT），**按原样分发、没有源码**。
ReBAR 必须改固件里的代码（见第 3 节），所以在二进制上打补丁走不通，只能**找一个可编译的同源实现**重编。

找到的基线是 **Cyridd/cmpunlocker** 的 `unlock40x_v70.c`（MIT，`Copyright (c) 2026 Cyridd`，仓库 2026-10-14 用 GitHub API 核对）。
它不是"另一个作者的另一套东西"：**与我们生产线上那张卡的固件同源** —— 取它的 `v70.c` 编出来的 11 个 blob 与生产线 EFI 里的 blob **逐字节相同**
（`fwsec_40hx_prod @0x66d08` 命中；见 `evidence/40HXONLY-精简证据.txt`、`evidence/blob-vs-production.txt`）。

## 2. 我们在这份源码上改了什么（全部是追加式，删除为 0）

| # | 改动 | 为什么要它 |
|---|---|---|
| ① | **补齐"生产版 Gen2 预埋"**：`XVE_OVR(0x8872C)=6`、`LINK_CONFIG_0(0x8C040) bit18→0`、`PRIV_MISC_1(0x8841C) bit13→1`、`CYA_0(0x8C2C0) bit13→1`，再加双端 `LNKCTL2` 低 4 位 = 2 | Cyridd 的 EFI **没有**这段预埋；直接拿它当第一启动项会重演 2026-09-19 那次"PostBind 守卫 EXIT=14"。值/顺序是反汇编生产固件 `.bnative` 段（VA `0x191000`）得到的，不是猜的 |
| ② | **ReBAR 配置**：配 XVE 的 size field（64 MiB → 8 GiB）+ 上游桥窗口，把 `BAR1` 放到 8 GiB 对齐的空闲 64 位 MMIO 窗口 | Windows 侧实测开不了（写 13 被硬件钳回 8、设备重启后被驱动清回 6）。A/B 表见工作区 `evidence/r7-vs-r6-source.diff` 与 `evidence/` 下 QEMU 冒烟记录 |
| ③ | **红行捕获重播**：跑码滚动快、红字拍不到 → 在打印出口按"当前输出色=红"自动捕获整行（上限 12 条 × 160 字符），chainload 前重播一遍 | 现场取证：红行是否出现要能一次看清（`u40x_recap_freeze` 防止重播自身再被捕获） |
| ④ | **收敛判据只认 `VSEC_DEVICE`**：`PL_LINK_RATE` 是"当前链路"的实时镜像，EFI 阶段还没重训 → 原判定每个开机固定黄一行 | 同一次开机实测：EFI 阶段 `PL_LINK_RATE=0x00320036`（未重训），Windows PostBind 重训后 `=0x00220036`（期望值）——在 EFI 阶段等它收敛是结构性不可能 |
| ⑤ | **40HX-only blob 精简**：去掉 6 个只被死函数引用的 blob（`fwsec_ga102` / `fwsec_ga102_sig` / `booter_ucode_dbg` / `fwsec_40hx_dbg` / `sec2_ucode_vbios_49` / `sec2_ucode_vbios_89`），553 K → 358 K（-35%） | 交付件体积；**源码零改动、反汇编等价**（归一化对比见 `evidence/40HXONLY-精简证据.txt`）。要支持其它目标卡请用 `src/build-pe-allblobs.sh`（11-blob 版） |

`All rights`：上游部分（含我们的修改）仍按 **MIT** 再分发；本仓库自写的增量部分保留所有权利 —— 边界见根目录 `THIRD_PARTY.md` 第 1b / 6 节与 `LICENSE`。

## 3. 构建链（为什么不是官方那条路）

- Cyridd 官方构建出的是 **ELF** 分支；在本机 gcc 下由 QEMU 加载会 `#GP`（官方只产出 MSYS2/PE 货）→ 改用 **`x86_64-w64-mingw32` PE 链**复刻：
  `src/build-pe.sh`（40HX-only 5-blob）+ `src/build-pe-allblobs.sh`（原 11-blob）+ `src/compat.c`（补 10 个 libefi 符号）。
- `-fno-zero-initialized-in-bss` + `-j .bss`：否则未初始化数据进 `.bss`，mingw 的 PE 加载器行为与固件环境不一致。
- **EFI 二进制不可逐字节复现**（同源码连编差 3 字节 PE 头）→ 冻结的是**产物 sha256**；可复现物是**源码 + regen 脚本**。
- 冒烟：QEMU + OVMF（`evidence/smoke-qemu.sh`、`evidence/smoke-r7-serial.log`）。注意 QEMU 的 vvfat 写回会破坏文件 → 冒烟必须用真 FAT 镜像 + mtools。

## 4. 验证到什么程度（如实）

| 验证层 | 状态 | 证据 |
|---|---|---|
| QEMU/OVMF 冒烟（含分支：正常 / 回滚 / 跳过） | ✅ | 工作区 `evidence/smoke-qemu.sh` + `smoke-r7-serial.log` + `r7-smoke-screendump.png` |
| 本机真机开机（r7） | ✅ 2026-10-12 23:02 | `evidence/boot-20261012-230656/`：`UNLOCKED` + Gen2 预埋 prime converged + `[rebar] BAR1 8 GiB active` + Windows 侧 Gen2 5.71/6.63 GB/s、FP32 8.32 TFLOPs |
| 本机真机开机（r8-C1，当前交付版） | ✅ 2026-10-13 19:23 | `evidence/r8-C1-20261013/`：`UNLOCKED`×2、`[rebar] BAR1 8 GiB active`×1、chainload 前无红行、postbind `PASS`、GPU/ROOT 均 Gen2 x16 |
| 其它主板 / 驱动 / 多卡 / 长时间负载 / 含反作弊的游戏场景 | ❌ 未验证 | — |
| MMIO 策略写入在"锁态 + 能力位仍 Gen1"的机器上生效 | ⚠️ 部分 | Windows 侧同机制（Link Disable 循环）已在客户包 20261013c 上真机通过；EFI 侧同一台机器的"能力位已翻"状态下通过 |

## 5. 撤销与回退

- 菜单 `一键解锁40HX.bat` → `1`：只把启动项切回主线 EFI（保留 ReBAR 文件）。
- 菜单 → `u`：切回主线 EFI + 删 ReBAR 启动项与 ESP 文件 + 清一次性验证任务。
- EFI 内部任一步失败会**整体回滚**（只打印 + 停留，不写 NVRAM）；系统照常启动。
- 原始形态（r6 knowngood）留档在工作区 `40hx-rebar-efi-test/backup-EFI/`。

## 6. 源码在哪里

`src/`（`unlock40x_v70.c` = 改后、`unlock40x_v70.c.cyridd-orig` = 上游原件、`regen-v70.py` 幂等生成、`compat.c`、两个 build 脚本）
与逐处差异说明 `DIFF-rebar-efi.diff` 目前留在工作区（`D:\40hx-unlock\40hx-rebar-efi-test\`），**本轮没有随仓库/随包分发** —— 交付件只带编好的 EFI。
需要源码级复现时找作者取该目录。
