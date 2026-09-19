# 02 — 原理：两阶段方案分别做了什么

解锁分两个独立阶段，缺一不可，而且**每次开机都要重跑一遍**（算力是易失寄存器状态，Gen2 链路速率也会在冷启动时回到 Gen1）。

## 阶段 A：EFI（开机时，跑在 Windows 之前）

文件：`\EFI\40HX\40HXUNLK.EFI`（OnlyEFI v0.1.1，sha256 `1e9ca43f…`；同一文件同时放在 `\EFI\Boot\bootx64.efi` 作兜底引导路径）。

1. **算力解锁**：写 SS0/SS1（厂商脚本里的 `SEC2 unlocked direct booter load (DIRECT_SEC2)`），日志行：
   ```
   [40HX] SEC2 unlocked  direct booter load (DIRECT_SEC2)
   [40HX] *** UNLOCKED (SS0=0x88888888 SS1=0x8) ***
   ```
2. **Gen2 预埋**：对 4 个 TU106 Gen2 策略寄存器做读改写（RMW），并把 Root Port 的 Target Link Speed 置为 Gen2：
   ```
   === EFI-B native injected Gen2 sequence ===
   [efi-b] Root TLS=Gen2; GPU TLS intentionally unchanged
   [efi-b] NO-RETRAIN: TLS2 set; skip EFI retrain
   ```
   **故意不在这里重训链路** —— 因为 EFI 阶段重训在本平台训不上（见 docs/03），而且强行重训/复位会清掉刚解锁的算力。
3. **chainload** 到 Windows：`chainload: bootmgfw.efi from current device` → 交棒 `\EFI\Microsoft\Boot\bootmgfw.efi`。

日志文件：**ESP 根目录 `\40hx_log.txt`**（固件自己写，每次开机覆盖）。它是"EFI 这次开机有没有跑"的唯一直接证据。

## 阶段 B：Windows（驱动 bind 之后，由开机任务触发）

任务：`CMP40HX Gen2 PostBind`（SYSTEM / ONSTART，延迟触发）→ `C:\ProgramData\CMP40HXGen2\windows\RunPostBind.cmd`
（自愈包装：补驱动 → 补/建服务 → `call AutoRetrain.cmd`，失败重试 3 次）
→ `CMP40HXGen2.exe`（源码 `payload/onlyefi-v0.1.1/source/windows/CMP40HXGen2_prod.c`）

程序逻辑（`windows/logs/last.log` 全量记录）：

1. **守卫**（不满足就拒绝写入，退出码非 0）：
   `SS0=0x88888888`、`SS1=0x8`、`XVE_OVR=6`、`CYA=068731B3`、`PL_LINK_RATE=0x00220036`、`VSEC=0x801`、`GPU LNKCAP=0x00453D02`、`GPU LNKCAP2=6`、`GPU TLS=2`、`ROOT TLS=2`
   —— 这组基线正是阶段 A 的 OnlyEFI EFI 预埋的，所以两个组件必须成对使用。
2. **只恢复两个被驱动改写过的策略寄存器**：
   ```
   LINK_CONFIG_0 old=800C5800 req=80085800 rb=80085800
   PRIV_MISC_1   old=E0B40D00 req=E0B42D00 rb=E0B42D00
   ```
3. **Root Retrain SET_ONLY 两次**：
   `#1 LT=0`（只置位不训练，`ROOT1 SET_ONLY old=0040 req=0060`）→ `#2 LT=1`（落地，链路重训到 Gen2）
   轮询 `LT`/`ROOT_GEN`/`GPU_GEN` 直到稳定。
4. 结果：`GPU final: Gen2 x16 LNKSTA=0x1102` / `ROOT final: Gen2 x16 LNKSTA=0xF102` → `PASS: physical Gen2 x16 reached.`

**它明确不做的事**（这就是算力能保住的原因）：不写 GPU/Root TLS、不写 XVE/CYA、不做 GPU retrain、不用 PnP disable/enable、不用 FLR/D3/SBR/Link Disable —— **全程不复位设备**。

已经处于 Gen2 时再跑：`PASS: already physical Gen2 x16; no writes needed.`（幂等，可随时手动复跑确认）。

## 为什么早先的厂商方案不行（结论）

厂商工具（CMP40HX-Unlock v3.2 等）在本平台：
- retrain-only 路径 6 轮全败（GPU 侧 TLS 写进去回读仍是 Gen1）；
- 只有 Stage2 硬回退（Root Link Disable → 写 TLS → 重训 → `Disable-PnpDevice`/`Enable-PnpDevice` 复位显卡）才能把 Gen2 落地；
- 而**一复位显卡，SS0 解锁态就被清零** → Gen2 成功 = 算力丢失；而且实测还会把显卡弄成 Code 43（Problem 0x2B），热重启救不回，必须完全关机冷启动。

OnlyEFI 的思路正是绕开复位：EFI 只"埋配置"，Windows 侧只"改两个寄存器 + 让 Root Port 重训"，显卡始终不被复位。

## 前置条件（原理层面）

- **GSP 固件必须开**（`EnableGpuFirmware=1`）：解锁态 + GSP 关闭 = nvlddmkm 不认卡（Code 43/黑屏）。
- **Above 4G Decoding 必须开**：否则固件/驱动映射失败，卸载后卡起不来（本平台的头号失败原因）。
- 引导必须 UEFI + GPT；Secure Boot 必须关（EFI 未签名）。
- ThrottleStop.sys / WinRing0x64.sys（BYOVD）用于在 Windows 侧碰 PCI 配置空间，服务"按需启动、用完即卸"；被杀了就会在 `postbind.log` 报 `OpenService 1060` / `FATAL: ThrottleStop service did not start`。
