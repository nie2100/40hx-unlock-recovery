# issue #5 · r9c 真机开机复验（参考机，2026-11-14 20:42）

本目录的每个数字都取自真实文件/命令输出，路径在同一条里给出。

## 1. 这次跑的是什么

| 项 | 值 | 来源 |
|---|---|---|
| ESP 上的 `\EFI\40HX\40HXUNLK-REBAR.EFI` | 364081 B  sha256 `9d18d135b5fd5e20ee5d5b5a7dbb7530103d0d2732e25177fa9fa525104684fc` | `console.txt` 第 17 行；与 `交付-r9c-20261114/40HXUNLK-REBAR.EFI` 逐字节相同 |
| 包内同一件 | 同上 | `40hx-oneclick-20261114b.zip` → `payload/EFI/40HXUNLK-REBAR.EFI` |
| ESP 根 `40hx_log.txt` | 7812 B / 132 行  mtime 2026-11-14 20:42:24  sha256 `62DF56E486CC1E1EF6AD1DF86F1400BE419D3928D27B36115802518BBFBB0D20` | `console.txt` 第 11 行 |
| Windows 本次开机时刻 | 2026-11-14 20:42:38 | `Get-CimInstance Win32_OperatingSystem.LastBootUpTime` |
| 日志副本 | 本目录 `40hx_log.txt`（ESP 那份下次开机会被覆盖，故已快照） | — |

日志写在 20:42:24、Windows 20:42:38 起来 ⇒ 就是这次开机那次执行。

## 2. r9c 的逻辑在真机上确实走了（日志原文，行号为 `40hx_log.txt`）

```
123 [rebar] placer r9b: aperture reports 0x4000000000..0x6005ffffff, live window 0x6000000000..0x6005ffffff,
          need 0x202000000 (align 0x200000000), 24 occupied span(s) from one bus scan
124 [rebar] candidate 0x6000000000..0x6201ffffff would own 00:02.0 BAR base 0x6006000000 - rejected
125 [rebar] candidate 0x4000000000..0x4201ffffff would own 00:02.0 BAR base 0x4000000000 - rejected
126 [rebar] placer r9b: 6 candidate(s), first 0x4200000000 (in-footprint 1, beyond/unknown 3, alt 4, advisory 0)
128 [rebar] plan: BAR1 0x4200000000..0x43ffffffff  BAR3 (size 0x2000000) 0x4400000000..0x4401ffffff
129 [rebar] aperture ok @0x4200000000: [+0]=0x00000000 [+mid]=0x00000000
130 [rebar] BAR1 8 GiB active @ 0x4200000000 (was 0x6000000000), BAR3 @ 0x4400000000 (was 0x6004000000) lucky!
131 chainload: bootmgfw.efi from current device
```

要点：

- `placer r9b` / `aperture ok @<addr>` 这两行是 r9 才有的（旧版是 `aperture ok: [+0]=…`，没有地址），
  所以「新版没被执行」可以直接排除。
- **aperture 起点不是地板**：本机 `Configuration()` 报 min `0x4000000000`，而 r8-C1 当年就是落在
  `0x400000000`（在 min 之下）才成功的。这正是 r9 把 min 降级为「排序偏好、不硬拒绝」的原因；
  真机上两个候选都因**端点 BAR 占用**被拒，最终落在 `0x4200000000`（in-footprint）。
- 被拒的两条都是新加的检查在起作用：`00:02.0`（Intel UHD P750，`PCI\VEN_8086&DEV_4C90`）的 BAR 在
  `0x4000000000` 与 `0x6006000000`，旧版只扫 `bus < gBus` 的桥窗口，这两块都看不见。
- 单次全 bus 扫描（0..255）在这块 AMI 板上没有报错：本次日志里 `Exception` / `revert` / `falling back` /
  `verify fail` 命中数均为 0（开机耗时没有做版本间对比，不作结论）。

## 3. r8-C1 与 r9c 在本机的对照

| 版本 | 落点 | 结果 | 来源 |
|---|---|---|---|
| r8-C1（旧） | `0x400000000`（memmap 顶端锚点） | 8 GiB 生效 | `evidence/r8-C1-20261013/` 里的旧日志：`[rebar] BAR1 8 GiB active @ 0x400000000 (was 0x6000000000)` |
| r9c（新） | `0x4200000000`（aperture 内，避开 `00:02.0` 的 BAR） | 8 GiB 生效 | 本次日志第 130 行 |

⇒ 选点变了，功能面没有回归。

## 4. Windows / 驱动侧（端到端）

- `nvidia-smi -q`：`BAR1 Memory Usage → Total: 8192 MiB`（`nvidia-smi-q.txt`）
- `Get-PnpDevice -Class Display`：`NVIDIA CMP 40HX (RainCandy Technology)` `Status=OK` `Problem=CM_PROB_NONE`（`pnp-display.json`）
- PostBind（20:44，本次开机后自动跑）：`GUARD = PASS`、`GPU final: Gen2 x16 LNKSTA=0x1102`、
  `ROOT final: Gen2 x16 LNKSTA=0xF102`、`PASS: Gen2 reached on the new path`（`postbind.log`、`retrain-last.log`）
  ⇒ 换落点没有影响 Gen2 那边。
- 解锁路径照旧：`*** UNLOCKED (SS0=0x88888888 SS1=0x8) ***`（第 102 行）、Gen2 primer 收敛（第 116-118 行）、
  chainload 到 `bootmgfw.efi` 正常（第 131-132 行）。

## 5. 已知且非本次引入

- 第 130 行行尾有个 `\x14`（控制字符）：源码里那是全角破折号 `—`（U+2014），UEFI `Print` 落盘只保留低字节。
  `— lucky!` 这段字符串在**冻结的 r8-C1 基线源码里就有**（`src/unlock40x_v70.c` 偏移 368459），不是 r9 引入，
  只影响日志观感，不改。

## 6. 这轮没覆盖到的

- 报障人那块 X99-TF 的 `0x383e00000000` 是否真的被路由 —— 只有他的新日志能回答；
- 双 8 GiB（40HX + RX 580）在该板上是否放得下 —— `Configuration()` 报的是当前足迹不是上限。
