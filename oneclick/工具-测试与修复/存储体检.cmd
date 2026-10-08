@echo off
chcp 936 >nul
setlocal
cd /d "%~dp0"
title 40HX - 存储体检（系统盘 GPT 判定诊断）

rem ---- 2026-10-08: 安装报「系统盘不是 GPT（未知）」时双击本文件取证 ----
rem Single line + label at EOF on purpose: a parenthesised block breaks when the folder
rem   name contains ) or & (e.g. Windows unpacks twice -> "xxx (1)").
if not exist "%~dp0..\Install-40HXUnlock.ps1" goto nops1

if /I "%~1"=="elevated" goto run
net session >nul 2>&1
if errorlevel 1 goto ask

:run
set "OUT=%USERPROFILE%\Desktop\40HX-存储体检-报告.txt"
echo ============================================================
echo   40HX 存储体检：逐后端打印存储信息原始结果（**只读**，不改任何东西）
echo.
echo   用途：安装时报「系统盘不是 GPT（未知）」或 ESP / 固件启动项相关报错时，
echo         双击本文件取证，把桌面报告发给技术。
echo   报告: %OUT%
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Install-40HXUnlock.ps1" -Mode StorageDiag > "%OUT%" 2>&1
set "RC=%ERRORLEVEL%"
type "%OUT%"
echo.
echo ------------------------------------------------------------
echo 退出码 = %RC%
echo 报告已保存: %OUT%
echo 请把这个 txt（或本窗口截图）发给技术；日志在同一包的 logs\run-*-StorageDiag.log
echo ------------------------------------------------------------
pause
exit /b %RC%

:ask
echo ==============================================================
echo   40HX 存储体检（只读诊断，不改任何东西）
echo ==============================================================
echo   会检查：Storage 模块在不在 / CIM 存储命名空间通不通 / 系统盘样式 /
echo           ESP 分区 / 每块硬盘的裸读结果（不依赖 WMI）
echo.
echo   [*] 正在申请管理员权限：会弹 UAC 和一个新的黑窗口，跑完按任意键关闭
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
goto :eof

:nops1
echo ============================================================
echo   [注意] 没找到 ..\Install-40HXUnlock.ps1
echo   本文件必须留在包内的「工具-测试与修复」目录里使用：
echo   请把 zip 完整解压到一个文件夹（不要在压缩包里双击），再运行本文件。
echo   当前目录: "%~dp0"
echo ============================================================
pause >nul
exit /b 1
