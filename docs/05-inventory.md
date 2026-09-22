# 05 — 文件清点

完整清单（每个文件的 md5 + 字节数 + 路径）：仓库根目录 **`INVENTORY.txt`**。
重新生成：

```bash
bash scripts/make-inventory.sh        # 在仓库根目录跑，输出 INVENTORY.txt
```

## 关键文件与用途

| 路径 | 用途 | 校验 |
|---|---|---|
| `payload/onlyefi-v0.1.1/EFI/40HXUNLK.EFI` | **解锁固件**（写入 ESP 两个位置） | sha256 `1e9ca43fab3d5ce851e8fcd09dc9be63282fbf3ce3828c3dbcdcbb21cf7ce1c7` |
| `payload/esp-2026-09-20/EFI_40HX/40HXUNLK.EFI` | 当前 ESP 上的实际文件（同一文件，双重备份） | 同上 |
| `payload/onlyefi-v0.1.1/windows/CMP40HXGen2.exe` | Windows 侧 helper（守卫 + 两个寄存器恢复 + Root Retrain） | md5 `1490de9bd90105e6ebc73e50abecc5cf` |
| `payload/onlyefi-v0.1.1/source/windows/CMP40HXGen2_prod.c` | helper 源码（可自行编译，`BUILD_CLANG.cmd`） | — |
| `payload/onlyefi-v0.1.1/source/efi/apply_no_efi_retrain.py` | 上游用来生成"不重训版" EFI 的脚本（含输入/输出镜像哈希双校验） | — |
| `payload/windows-live/RunPostBind.cmd` | **本机在用的**自愈包装（多源补驱动 + 补服务 + 重试 3 次 + **ACE 处理** `:ace_off`/`:ace_wait`/`:ace_on`） | md5 `7573f1e0407c055ee58e1096d5b7abd1` |
| `payload/windows-live/RunPostBind.no-ace.cmd.bak` | 加 ACE 处理之前的版本（留档对照） | md5 `71458e1cbf9d86c288c1a1faa714e0bd` |
| `payload/windows-live/AutoRetrain.cmd` | 上游脚本：起服务 + 跑 helper（只 start 不 create 服务） | md5 `0021c1978b749ee7e55834e2aa7ef59a` |
| `payload/drivers/ThrottleStop.sys.b64` | BYOVD 驱动（base64 文本，还原后 50216 B） | md5 `6bc8e3505d9f51368ddf323acb6abc49` |
| `payload/drivers/WinRing0x64.sys` / `.b64` | BYOVD 驱动（14544 B） | md5 `0c0195c48b6b8582fa6f6373032118da` |
| `payload/drivers/RESTORE-DRIVERS.ps1` | 还原驱动 + 补建服务 | — |
| `payload/esp-2026-09-20/40hx_log.txt` | 本次开机的固件日志样本（`UNLOCKED` + `NO-RETRAIN`） | — |
| `payload/nvram-backup-20260911/*.bin` | NVRAM 引导变量原始二进制（`BootOrder` / `Boot0000` / `0002` / `0003` / `0005` / `SecureBoot` / `PlatformLang`） | — |
| `scripts/restore-onlyefi.ps1` | **一键回到 OnlyEFI 状态**（备份厂商 EFI → 写回解锁 EFI → 校验哈希 → 禁厂商任务 → 清 HKCU Run → 设策略键） | — |
| `scripts/install_onlyefi.ps1` | 首次把解锁 EFI 写进 ESP（含备份与哈希校验） | — |
| `scripts/step6_auto.ps1` / `step7_heal.ps1` / `step8_wrapper.ps1` | 建目录/拷文件/注册开机任务/生成自愈包装 | — |
| `scripts/coldboot-report.ps1` + `register-coldboot-task.ps1` | 一次性开机任务：冷启动 3 分钟后自动出验证报告 | — |
| `scripts/nvram_chk.ps1` / `nvram_write.ps1` / `nvram_bootorder.ps1` | 读写 UEFI 引导变量（`SeSystemEnvironmentPrivilege`） | — |
| `scripts/ghost-clean.ps1` | 清理幽灵 PnP 实例（先 `reg export` 备份） | — |
| `scripts/40HX解锁状态.bat` | **日常一键自检**（双击即用）：nvidia-smi + WDDM 模式 + CUDA ctypes 实测带宽判 Gen2 + 开机任务日志 + 厂商状态文件，末行给结论 | md5 `d02b492184f7398a77847b8b0a024d8c`（与本机桌面文件逐字节一致） |
| `docs/06-ace-boot.md` | **过腾讯 ACE**：判据、`ACE-Tray` 关键一步、自动化、厂商诊断误判、完整时间线 | — |
| `evidence/ace-20260922/` | ACE 专项原始证据（诊断/STOP_PENDING/杀托盘后成功/A-B 双 PASS + 当时用的 ps1） | — |
| `evidence/` | 实测证据：冷启动报告、基准输出、helper 日志、固件日志、NVRAM 读取、回滚日志 | — |

## 恢复时的顺序提示

1. `payload/drivers/RESTORE-DRIVERS.ps1`（管理员）→ 拿到两个驱动 + 服务
2. `scripts/install_onlyefi.ps1`（改成仓库实际路径）→ 或按 README 步骤 2 手工 copy + 校验哈希
3. `scripts/step6_auto.ps1` + `step7_heal.ps1` → 建目录/文件/开机任务（注意脚本内写死的 `D:\40hx-unlock` 路径要改）
4. 重启 → `scripts/register-coldboot-task.ps1` → 冷启动验证

## 未纳入仓库的东西（体积/授权原因）

- 厂商包 `CMP40HX-Unlock`（`40HXInstaller.exe` / `40HXCheck.exe` / `40HXUninstaller.exe`，几 MB）——本机方案不用它；需要时按 `docs/03-pitfalls.md` 的提醒先备份 ESP 再试。
- NVIDIA 驱动安装包（616.92，几百 MB）——从官方渠道获取。
- `payload/esp-2026-09-20/EFI_Boot/bootx64.efi.40hx.bak`（3 MB 的微软 `bootmgfw.efi` 原始备份）——属于 Windows 自带文件，回滚时从系统/安装介质取即可。
