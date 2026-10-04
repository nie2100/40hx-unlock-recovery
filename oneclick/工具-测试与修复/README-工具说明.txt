40HX 一键包 —— 工具 / 测试 / 修复脚本（按需取用，不影响安装）
============================================================

这个文件夹里都是"出事了才用"的脚本，全部**只读优先**、能自提权、报告默认落到桌面。
主流程（安装 / 修 Gen2 / 状态自检）在包根目录，日常不用进这里。

【日常自检】
  根目录 状态自检.bat                 —— 6 步体检：驱动模式 / PCIe 宽度 / 带宽+算力(免 Python) / 开机任务 / 状态文件
                                        （带宽+算力用 Windows 自带的 csc.exe 现场编译内置 C# 实测程序，装不装 Python 都行；
                                          若 csc 被精简系统删掉或被安全软件拦截，那节会标"跳过"，不代表故障）

【Gen2 上不去排查】
  判断延长线.cmd                      —— 只读四判据：是延长线/信号问题还是寄存器/固件问题
  测试延长线-用别的显卡.cmd           —— 用一张普通显卡（如 1060）测同一条延长线，负载下看 Gen2/Gen3 与 WHEA
  诊断包-20260930\一键诊断.cmd       —— 只读取证包：GSP 三态 / BDF 探测 / 开机时间线 / 任务结果，出桌面报告+zip

【GSP（GPU 固件）没开 —— 代码 43 / 黑屏】
  查GSP.cmd                           —— 只读诊断：驱动层 → GSP 开关 → 驱动包里有没有 gsp_tu10x.bin；
                                        报告落桌面并自动打开，第 4 节直接给结论与处置顺序
  （包根还有个快捷入口 `GSP体检.cmd`，转发到这里的 查GSP.cmd；客户从包根就能跑）
  查GSP.cmd /fix                      —— 开关是 0 时写 EnableGpuFirmware=1（先备份到桌面）；写完后必须**完全关机再开机**
                                        （重启不算 —— GSP 只在驱动重新初始化时生效）。驱动层不正常时它不会让你写

【游戏/反作弊】
  ACE修复.cmd                         —— 只读体检：ACE 组件、自启项、开机脚本版本、ThrottleStop 溯源
  ACE修复.cmd /fix                    —— 修复：升级开机任务脚本、ThrottleStop **只停+置 disabled（不动文件）**、清 40HX 自启项(留档)、恢复 ACE-BOOT/托盘
                                          （默认不挪文件：ACE 拦的是"映像加载"，不加载就够；文件留着保住厂商 legacy 回退）
  ACE修复.cmd /fix -retirefile        —— 同上，另把 ThrottleStop 彻底退役（删掉指向它的服务 + .sys 挪进 drivers-disabled\）；此后厂商 legacy 回退不可用
  ACE修复.cmd /acefirst on|off        —— ACE 优先模式：开机任务永不停止 ACE-BOOT（代价：新路径不通时本轮不落地 Gen2）
  修复ACE.cmd                         —— **等于 ACE修复.cmd /fix（会改系统！）**：两个入口名字只差字序，别点错；
                                        它自带醒目标题 + 3 秒延时，详见 文档\给客户-ACE报错处理指引-20261004.txt

【桌面/系统异常】
  桌面恢复.cmd                        —— 桌面不加载(黑屏+鼠标)时用：诊断 explorer / Winlogon Shell / ACE 组件 / 可回滚点
  桌面恢复.cmd /fix                   —— 拉起 explorer + 修正 Shell + 拉起 ACE 组件
  桌面恢复.cmd /disableace            —— 临时停用腾讯 ACE（拿回桌面最有效的一招；之后在游戏里"修复"即可恢复）
  桌面恢复.cmd /restoreautorun        —— 还原我们清理过的 Run 自启项（留档在 ProgramData\CMP40HXGen2\windows\logs）
  安全模式-修复.cmd                   —— 安全模式下用：清理残留开机任务/服务、把会崩的工具改名

【取证】
  收集蓝屏证据.cmd                    —— BugCheck 参数 / WHEA 错误源 / minidump 清单 / 驱动拦截源排查(SAC/HVCI/ACE/CI 日志)
  查ThrottleStop.cmd                  —— 只读：ThrottleStop 驱动在哪 / 有没有在跑 / 谁还会把它加载回来；
                                        末节给「直接删掉安不安全」。加 `-deep` 连 ESP 兜底副本一起扫（会临时挂 EFI 分区）

全部脚本的报告位置：桌面 40HX-*.txt（桌面出不来时同时写 C:\40HX-*.txt）
