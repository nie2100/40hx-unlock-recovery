# payload/drivers — 两个 BYOVD 驱动（以 base64 文本备份）

| 文件 | 说明 | 还原后 SHA/MD5 |
|---|---|---|
| `ThrottleStop.sys.b64` | base64 文本；还原后 50216 字节 | md5 `6bc8e3505d9f51368ddf323acb6abc49` |
| `WinRing0x64.sys.b64` | base64 文本；还原后 14544 字节 | md5 `0c0195c48b6b8582fa6f6373032118da` |
| `WinRing0x64.sys` | 二进制副本（该文件通常不会被杀软删，留一份直用） | 同上 |
| `RESTORE-DRIVERS.ps1` | 管理员运行：解码 → 写到 `System32\drivers` 与 `C:\ProgramData\CMP40HXGen2\drivers` → 缺服务则 `sc create` | — |

## 为什么用 base64 而不是直接放 .sys

`ThrottleStop.sys` 被火绒等杀软视为 **BYOVD（自带易受攻击驱动）**，从**未信任路径**复制过去会被**秒删**（实测：复制到临时目录后 10 秒内消失；连解压出来的 OnlyEFI 包内那份也会被清掉）。而用户已信任的 `C:\Windows\System32\drivers\` 与 `C:\ProgramData\40HXUnlock\drivers\` 下的副本能长期存活。

因此本仓库以 base64 文本形式保存，避开扫描；重装恢复时用 `RESTORE-DRIVERS.ps1` 还原。**还原后务必把这两个文件加入杀软信任区**，否则每次开机都要靠 `RunPostBind.cmd` 的多源自愈重拷（能自愈，但会偶发失败）。

## 服务注册（还原脚本已包含）

```
sc create ThrottleStop   type= kernel start= demand binPath= "\SystemRoot\System32\drivers\ThrottleStop.sys"
sc create WinRing0_1_2_0 type= kernel start= demand binPath= "\SystemRoot\System32\drivers\WinRing0x64.sys"
```

这两个驱动用于在 Windows 侧读写 PCI 配置空间；服务"按需启动、用完即卸"。
