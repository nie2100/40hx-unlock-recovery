@echo off
rem Copyright 2026 nie2100 - All rights reserved; redistribution or resale not permitted.
rem Upstream MIT parts: CMP40HX-Unlock by PZH1gdmu / CMP40HX-Unlock-OnlyEFI by BardKing-CN.
chcp 936 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title CMP 40HX 一键安装

rem ---- 2026-10-04: preflight ------------------------------------------------------------
rem Single line + label at EOF on purpose: a parenthesised block breaks when the folder
rem   name contains ) or & (e.g. Windows unpacks twice -> "xxx (1)").
if not exist "%~dp0Install-40HXUnlock.ps1" goto nops1

rem 已提权的那一份（带 elevated 标记）直接干活，不再问第二次
echo %* | findstr /i "elevated" >nul && goto run

net session >nul 2>&1
if errorlevel 1 goto ask

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-40HXUnlock.ps1" -Mode Install -Yes
set "RC=%ERRORLEVEL%"
echo.
echo 安装退出码 = %RC%   (0 表示步骤全部成功)
rem 2026-10-04: -196608 = 0xFFFD0000 = PowerShell never read the script (nothing was done).
if "%RC%"=="-196608" goto nops1
rem 196608 without the minus is what customers usually report (the minus gets lost).
rem   cmd formats %ERRORLEVEL% as signed, so a real 196608 would be another failure;
rem   we still show the same explanation because the customer-side steps are identical.
if "%RC%"=="196608"  goto nops1
echo.
echo ============================================================
echo   现在请【完全关机】再开机（必须，不是重启）：算力解锁靠每次开机的解锁固件生效；
echo   重启清不掉显卡残留状态，残留状态不对 = 开机黑屏一段时间 + 设备管理器代码 43；
echo   做法：开始菜单-关机，最好拔电 10 秒再开机
echo   开机后双击 状态自检.bat 看结论；出问题看 排查指引.md
echo   上面若列了"重启前请先处理"的事项，请先处理再重启
echo   回滚见 文档\使用说明-详细.md （或根目录 README.md）
echo ============================================================
echo.
pause
exit /b %RC%

:ask
echo ==============================================================
echo   CMP 40HX 算力解锁 + PCIe Gen2  一键安装 / 迁移
echo ==============================================================
echo   将要做的改动：
echo     1) 两个内核驱动复制到 System32\drivers 并注册服务
echo     2) OnlyEFI 解锁固件写入 EFI 分区（原文件自动备份到 backup\）
echo     3) 写入固件启动项 "40HX Unlock" 并排到启动顺序第一位
echo     4) 注册开机任务：每次开机自动落地 PCIe Gen2 + 处理腾讯 ACE
echo.
echo   随时可回滚：
echo     powershell -ExecutionPolicy Bypass -File "%~dp0Install-40HXUnlock.ps1" -Mode Uninstall -Yes
echo.
echo   想先只看不改：Install-40HXUnlock.ps1 -Mode Check
echo.
set /p ANS=回车开始安装，输入 n 退出: 
if /i "%ANS%"=="n" goto quit
echo.
echo [*] 正在申请管理员权限：会弹 UAC 和一个新的黑窗口，装完按任意键关闭
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
goto :eof


:nops1
echo ============================================================
echo   [注意] 安装没能开始：PowerShell 没有读到安装脚本
echo.
echo   退出码 -196608 就是十六进制 0xFFFD0000 —— 这是 PowerShell 自己
echo   "脚本没能跑起来"的错误码，不是安装脚本报的错。也就是说下面这些
echo   一件都还没做：没改注册表、没写驱动、没动启动项、没改引导。
echo.
echo   常见原因，按可能性排序：
echo     1. 直接从压缩包里双击运行 —— 请先把 zip 完整解压到一个文件夹再运行
echo     2. 杀软把 Install-40HXUnlock.ps1 删了或隔离了
echo        请到杀软的隔离区恢复它，并把本目录加进信任区
echo     3. 只把 一键安装.cmd 拷了出来 —— 请整包拷贝
echo     4. 包放在映射的网络盘或共享目录上，提权后读不到 —— 请拷到本机硬盘
echo.
echo   正确解压后，本目录里应当能看到：
echo     Install-40HXUnlock.ps1   一键安装.cmd   payload   文档
echo   当前目录（可截图发回）
echo      "%~dp0"
echo.
echo   还是不行：把本窗口截图（含上面那行英文报错）发给技术
echo ============================================================
if not "%NO_PAUSE%"=="1" pause >nul
exit /b 1

:quit
echo 已取消，什么都没改。
pause
