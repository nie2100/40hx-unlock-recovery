# 01 — 本机硬件、固件与拓扑（实测）

采集命令（管理员 PowerShell）：

```powershell
Get-CimInstance Win32_BaseBoard   | Select Manufacturer,Product,Version
Get-CimInstance Win32_BIOS        | Select Manufacturer,Name,SMBIOSBIOSVersion,ReleaseDate
Get-CimInstance Win32_Processor   | Select Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed
Get-CimInstance Win32_ComputerSystem | Select Manufacturer,Model,TotalPhysicalMemory
Get-CimInstance Win32_VideoController | Select Name,DriverVersion,PNPDeviceID
```

| 项目 | 实测值 |
|---|---|
| 主板 | Gigabyte Technology Co., Ltd. / **B560M AORUS ELITE** |
| BIOS | American Megatrends F13d（2026-06-29） |
| CPU | Intel Xeon **W-1370P** @ 3.60 GHz，8 核 / 16 线程 |
| 内存 | 8 GB |
| 系统 | Windows 11 专业版 build 26200，UEFI + GPT，Secure Boot 关闭，无 BitLocker |
| GPU | **NVIDIA CMP 40HX**（ASUS 版），子系统 `1043:8804`，`PCI\VEN_10DE&DEV_1F0B` |
| VBIOS | `90.06.67.00.04`（ESP 上有 dump：`\40hx_vbios.bin`） |
| 驱动 | NVIDIA 616.92 / CUDA 13.4，GSP 开启 |
| PCI 位置 | GPU `01:00.0` ← Root Port `00:01.0`，x16 电气 |

## PCIe 链路实测值（判据来源）

| 状态 | GPU LNKSTA | ROOT LNKSTA | 说明 |
|---|---|---|---|
| Gen1 x16（开机默认） | `0x1101` | `0x7101` | 未落地时的现场 |
| **Gen2 x16（目标）** | `0x1102` | `0xF102` | helper 跑完后的现场 |
| 中间态（Retrain #2 进行中） | — | `0xF901` | `ROOT2 poll LT=1 ROOT_GEN=1 GPU_GEN=2` |

守卫/基线寄存器（OnlyEFI EFI 预埋后、Windows helper 读到的值）：

| 寄存器 | 值 |
|---|---|
| SS0 / SS1 | `0x88888888` / `0x8`（算力解锁） |
| GPU LNKCAP / LNKCAP2 | `0x00453D02` / `0x00000006` |
| GPU TLS / ROOT TLS | `2` / `2`（Gen2 目标速率） |
| PL_LINK_RATE | `0x00220036` |
| VSEC | `0x00000801` |
| 被驱动改写的两个寄存器 | `LINK_CONFIG_0 0x800C5800`（需恢复为 `0x80085800`）、`PRIV_MISC_1 0xE0B40D00`（需恢复为 `0xE0B42D00`） |

> 对照：厂商版 EFI 预埋出来的基线是 `LNKCAP=0x00453D01`、`LNKCAP2=0x2`、`GPU TLS=1` —— 与 OnlyEFI helper 的守卫不符，helper 会拒绝写入（exit 14）。

## 性能基线（解锁 + Gen2 状态下实测）

| 指标 | 值 |
|---|---|
| FP32（fma） | **8.346–8.409 TFLOPs/s** |
| FP16（half2） | 16.49–16.57 TFLOPs/s |
| INT8（dp4a） | 31.25–31.38 TIOPs/s |
| 显存带宽 | 读 400 GB/s / 写 426 GB/s |
| PCIe 带宽（双向，工具标注 Gen2 x16） | **5.98–6.19 GB/s**（send 5.72–5.87 / recv 6.15–6.53） |

对照：本机核显 Intel UHD P750 在同一基准里 FP32 ≈ 0.537 TFLOPs/s、显存带宽 ≈ 35 GB/s —— 两者差 15 倍以上，可用来确认"这段跑的是哪块卡"。

## 读数的坑

- `nvidia-smi --query-gpu=pcie.link.gen.current` **不可信**：空闲或纯计算负载（不产生 PCIe 流量）时会动态降速到 1，实测 100% 满载也可能显示 1。判 Gen2 只认寄存器 `LNKSTA` 或带宽工具的输出标注。
- 用 GPIO/BYOVD 工具读 `SS0` 需要 ThrottleStop 驱动在跑；驱动"用完即卸"后读不到属正常终态，不代表解锁丢了。
- `schtasks /ru SYSTEM` 会话里跑 OpenCL 基准会枚举成核显（Device 0 = Intel）。
