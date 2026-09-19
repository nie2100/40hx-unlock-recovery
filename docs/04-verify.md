# 04 — 验证判据与证据

## 判据（按可靠性排序）

| # | 判据 | 通过标准 | 位置 |
|---|---|---|---|
| 1 | 固件日志（算力） | 出现 `*** UNLOCKED (SS0=0x88888888 SS1=0x8) ***` | ESP 根目录 `\40hx_log.txt`（本次开机写） |
| 2 | 固件日志（Gen2 预埋） | 出现 `[efi-b] Root TLS=Gen2; GPU TLS intentionally unchanged` 与 `[efi-b] NO-RETRAIN: TLS2 set; skip EFI retrain` | 同上 |
| 3 | helper 现场读数 | `GUARD=PASS` + `SS0=0x88888888` + `SS1=0x00000008` | `C:\ProgramData\CMP40HXGen2\windows\logs\last.log` |
| 4 | 物理链路落地 | `GPU final: Gen2 x16 LNKSTA=0x1102` / `ROOT final: Gen2 x16 LNKSTA=0xF102` + `PASS: physical Gen2 x16 reached.` + `EXIT=0` | 同上 |
| 5 | 开机任务 | 该轮 `PostBind EXIT=0` / `PASS: physical Gen2 post-bind step succeeded`；任务 `CMP40HX Gen2 PostBind` 上次结果 = 0 | `...\logs\postbind.log` |
| 6 | 带宽交叉验证 | 工具输出标注 `PCIe Bandwidth (bidirectional) (Gen2 x16)` 且 ≈ 5.7–6.2 GB/s | 厂商 `release\OpenCL.exe` |
| 7 | 算力性能 | FP32 ≈ 8.3–8.4 TFLOPs/s（核显只有 0.54） | 同上 |

**不要用** `nvidia-smi` 的 `pcie.link.gen.current`（会动态降速到 1，见 docs/03 C1）。

## 本次证据（2026-09-20 冷启动）

固件日志（`payload/esp-2026-09-20/40hx_log.txt`，mtime 09-20 00:09:30）：

```
[40HX] SEC2 unlocked  direct booter load (DIRECT_SEC2)
[40HX] *** UNLOCKED (SS0=0x88888888 SS1=0x8) ***
=== EFI-B native injected Gen2 sequence ===
[efi-b] Root TLS=Gen2; GPU TLS intentionally unchanged
[efi-b] NO-RETRAIN: TLS2 set; skip EFI retrain
chainload: bootmgfw.efi from current device
chainload: starting Windows Boot Manager...
```

helper（`evidence/coldboot-report.txt` 里转引 `last.log`，2026-09-20 00:10:10）：

```
GUARD=PASS
SS0=0x88888888 / SS1=0x00000008
GPU LNKCAP=0x00453D02 / GPU LNKCAP2=0x00000006
GPU: Gen1 x16 LNKSTA=0x1101   ROOT: Gen1 x16 LNKSTA=0x7101   ← 从 Gen1 起步
TLS GPU=2 ROOT=2
[1] LINK_CONFIG_0 old=800C5800 req=80085800 rb=80085800
    PRIV_MISC_1   old=E0B40D00 req=E0B42D00 rb=E0B42D00
[2] Root Retrain #1 SET_ONLY  → LT=0
[3] Root Retrain #2 SET_ONLY  → LT=1 → GPU_GEN=2
GPU final: Gen2 x16 LNKSTA=0x1102
ROOT final: Gen2 x16 LNKSTA=0xF102
PASS: physical Gen2 x16 reached.        ==== EXIT=0 ====
```

开机任务（`evidence/coldboot-report.txt`）：

```
==== PostBind start 2026/09/20 0:10:06 ====
---- attempt 1 ----                       ← 一次成功，无需重试
==== PostBind EXIT=0 2026/09/20 0:10:10 ====
PASS: physical Gen2 post-bind step succeeded
```

性能（`evidence/bench-20260920.txt`，同一次开机）：

```
Device ID 0 | NVIDIA CMP 40HX         FP32 8.346 TFLOPs/s   INT8 31.247 TIOPs/s
                                     显存读 400.25 / 写 425.99 GB/s
                                     PCIe 双向 5.98 GB/s  (Gen2 x16)
Device ID 1 | Intel UHD Graphics P750 FP32 0.537 TFLOPs/s   （核显，对照）
```

设备状态：`PCI\VEN_10DE&DEV_1F0B&...&0&0008  Status=OK  Problem=0x0`。

## 怎么复现验证

```powershell
# 1) 固件日志（管理员）
mountvol Y: /s ; Get-Content Y:\40hx_log.txt | Select-String 'UNLOCKED|NO-RETRAIN|efi-b' ; mountvol Y: /d

# 2) helper 现状（幂等，可随时跑）
& C:\ProgramData\CMP40HXGen2\windows\CMP40HXGen2.exe

# 3) 日志
Get-Content C:\ProgramData\CMP40HXGen2\windows\logs\last.log
Get-Content C:\ProgramData\CMP40HXGen2\windows\logs\postbind.log -Tail 12

# 4) 开机任务结果
Get-ScheduledTaskInfo -TaskName 'CMP40HX Gen2 PostBind' | Select LastRunTime,LastTaskResult

# 5) 带宽/算力交叉验证（用交互会话，别用 SYSTEM）
D:\40hx-unlock\release\OpenCL.exe
```

冷启动整体验证：`scripts/register-coldboot-task.ps1` 注册一次性开机任务（开机后 3 分钟出报告 `coldboot-report.txt`，跑完自删），然后完全关机再开机。
