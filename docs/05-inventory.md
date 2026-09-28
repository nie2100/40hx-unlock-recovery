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
| `payload/windows-live/RunPostBind.cmd` | **本机在用的**自愈包装（多源补驱动 + 补服务 + 重试 3 次 + **ACE 处理走 `ACE-Toggle.ps1`**：`call :ace_toggle off\|on\|HealTray`）；纯 ASCII，见 `docs/03` D7 | md5 `c7c28a0972d3bc2e024e4a766d16f516` |
| `payload/windows-live/ACE-Toggle.ps1` | 与本机 `%ProgramData%\CMP40HXGen2\windows\ACE-Toggle.ps1` 逐字节相同（含 `HealTray` 托盘自愈），随开机任务一起被调用 | md5 `e150f4ff59d543148af7bbcabd363bad` |
| `payload/windows-live/RunPostBind.ace-bat-20260922.cmd.bak` | 加 `ACE-Toggle.ps1` 之前的 ACE 处理版（把 `ACE-BOOT` 服务名/目录写死在 `.cmd` 里），留档对照 | md5 `7573f1e0407c055ee58e1096d5b7abd1` |
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
| `scripts/40HX解锁状态.bat` | **日常一键自检**（双击即用，6 步）：nvidia-smi + WDDM 模式 + CUDA ctypes 实测链路带宽判 Gen2 + **PTX 实测算力**（SM 数 / FP32 / FP16 / FP16-TC / 显存带宽）+ 开机任务日志 + 厂商状态文件，末行给三态结论 | md5 `66396b8918d75af0b42adcef24cab38d`（与本机桌面文件逐字节一致；GBK + CRLF） |
| `oneclick/一键安装.cmd` | **一键安装入口**（双击；先摘要+确认再提权，提权后那份不再二次询问） | GBK + CRLF（`.gitattributes` 已禁止转换） |
| `oneclick/Install-40HXUnlock.ps1` | 自含安装/修复/取证脚本：`Check`/`SelfTest`/`Install`/`Repair`/`Verify`/`MakeDefault`/`Uninstall`；退出码 0/1/2/3/4/5，失败自动打印「出错怎么办」；**2026-09-28 修掉**：所有原生命令（`schtasks`/`sc`/`mountvol`/`nvidia-smi`）统一走 `Invoke-Native` 包装 —— 此前 `$ErrorActionPreference='Stop'` 下首次安装必断在 `schtasks /delete`（见 `docs/03` D6） | UTF-8 **带 BOM** |
| `oneclick/状态自检.bat` | 与 `scripts/40HX解锁状态.bat` **逐字节相同**（md5 `66396b8918d75af0b42adcef24cab38d`），包内自带一份以保持自含 | GBK + CRLF |
| `oneclick/README-使用说明.md` / `排查指引.md` / `验证记录.md` | 包内说明、**按报错原话/退出码索引的排查指引**、交付前本机实测记录 | UTF-8 |
| `oneclick/payload/windows/ACE-Toggle.ps1` | **ACE(腾讯反作弊) 定位与停/恢复**：按 ImagePath 含 `AntiCheatExpert` 定位（换目录/改名无关）、托盘按路径定位、
恢复按状态文件里记录的原始启动类型；WARN 提示其它厂商反作弊。被 `RunPostBind.cmd` 的 `:ace_toggle off|on` 调用 | UTF-8 带 BOM |
| `oneclick/payload/` | EFI 解锁固件 + Windows helper + 两个驱动的 base64 + `sha256.txt`（与仓库其它 payload 目录内容等价：EFI/helper 逐字节相同；`*.b64` 仅换行方式不同，**解码后字节一致**、哈希与期望值相符） | 同仓库其它 payload |
| `docs/06-ace-boot.md` | **过腾讯 ACE**：判据、`ACE-Tray` 关键一步、自动化、厂商诊断误判、完整时间线 | — |
| `evidence/ace-20260922/` | ACE 专项原始证据（诊断/STOP_PENDING/杀托盘后成功/A-B 双 PASS + 当时用的 ps1） | — |
| `oneclick/ACE排查/` | **装机后 ACE 报错的现场排查包**：`排查ACE.cmd`（双击/自提权/只读采集 → 桌面报告，判据结论在末节）、`ACE-Diag.ps1`、`怎么用-先读我.txt`、`状态自检.bat`；`-Fix` 可顺手修（ACE-BOOT 启动类型/状态、重启托盘、禁用被启用的厂商 Gen2 任务） | UTF-8 BOM(.ps1) / GBK(.cmd) |
| `oneclick/hotfix-20260928/` | **最小热修包**（只补「ACE 弹初始化失败」）：`应用热修.cmd`、`应用热修并立即验证.cmd`、`apply-hotfix.ps1`、`payload\{RunPostBind.cmd,ACE-Toggle.ps1}`、`热修说明.txt`；覆盖前自动备份到 `logs\pre-hotfix-<时间>\` | — |
| `evidence/ace-20260928/` | **本次证据**（已脱敏）：装机现场排查报告、HealTray 四场景实测、EAP=Stop NativeCommandError 复现与修法对照、热修后端到端输出 | — |
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
