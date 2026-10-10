@echo off
rem Copyright 2026 nie2100 - All rights reserved; redistribution or resale not permitted.
rem Upstream MIT parts: CMP40HX-Unlock by PZH1gdmu / CMP40HX-Unlock-OnlyEFI by BardKing-CN.
chcp 936 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title CMP 40HX 一键卸载

rem ---- preflight（与 一键安装.cmd 同款：单行+末尾标签，避免文件夹名带 ) 或 & 时括号块解析炸掉）
if not exist "%~dp0Install-40HXUnlock.ps1" goto nops1

rem 已提权的那一份（带 elevated 标记）直接干活，不再问第二次
echo %* | findstr /i "elevated" >nul && goto run

rem 2026-10-10：fltmc 不依赖 Server 服务（net session 在精简系统上会误判）
fltmc >nul 2>&1
if errorlevel 1 net session >nul 2>&1
if errorlevel 1 goto ask

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-40HXUnlock.ps1" -Mode Uninstall -Yes
set "RC=%ERRORLEVEL%"
echo.
echo 卸载退出码 = %RC%   (0 表示卸载成功)
rem -196608 = 0xFFFD0000 = PowerShell 没读到脚本（什么都没做）；客户报过来的常是丢了负号的 196608
if "%RC%"=="-196608" goto nops1
if "%RC%"=="196608"  goto nops1
if %RC% NEQ 0 (
  echo.
  echo [X] 卸载脚本返回错误码 %RC% —— 这次没卸干净,
  echo     请把本窗口截图和 logs 目录里最新的 run-*.log 发给技术
) else (
  echo.
  echo ============================================================
  echo   [OK] 卸载完成。请【重启】一次，重启后就是原生（未解锁）状态
  echo   注：有少数改动不会自动还原（GSP 开关/快速启动/策略键等，
  echo       都不影响使用），清单见上面脚本输出的黄色说明
  echo ============================================================
)
echo.
if not "%NO_PAUSE%"=="1" pause
exit /b %RC%

:ask
echo ==============================================================
echo   CMP 40HX 算力解锁 + PCIe Gen2  一键卸载
echo ==============================================================
echo   卸载会做的事（都有备份，随时可装回）：
echo     1) 删除固件启动项 "40HX Unlock" 并把它从启动顺序里去掉
echo     2) 还原 EFI 分区里 Windows 原始引导文件（仅限曾经覆盖过时）
echo     3) 删除开机任务、驱动服务和驱动文件
echo     4) 撤销 Defender 排除项
echo.
echo   不会自动还原（都不影响使用）：GSP 开关 / 快速启动 / 策略键等，
echo   卸载时脚本会列出完整清单。
echo.
echo   卸载后【重启】一次就回到原生（未解锁）状态。
echo   想装回来：双击 一键安装.cmd 即可。
echo.
set /p ANS=确定要卸载吗？回车开始卸载，输入 n 退出: 
if /i "%ANS%"=="n" goto quit
echo.
echo [*] 正在申请管理员权限：会弹 UAC 和一个新的黑窗口，卸完按任意键关闭
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
goto :eof

:nops1
echo ============================================================
echo   [注意] 卸载没能开始：PowerShell 没有读到卸载脚本
echo.
echo   退出码 -196608 就是十六进制 0xFFFD0000 —— 这是 PowerShell 自己
echo   "脚本没能跑起来"的错误码，不是卸载脚本报的错。也就是说这次
echo   什么都没改：启动项、任务、驱动全都还在。
echo.
echo   常见原因，按可能性排序：
echo     1. 直接从压缩包里双击运行 —— 请先把 zip 完整解压到一个文件夹再运行
echo     2. 杀软把 Install-40HXUnlock.ps1 删了或隔离了
echo        请到杀软的隔离区恢复它，并把本目录加进信任区
echo     3. 只把 一键卸载.cmd 拷了出来 —— 请整包拷贝
echo     4. 包放在映射的网络盘或共享目录上，提权后读不到 —— 请拷到本机硬盘
echo.
echo   当前目录（可截图发回）
echo      "%~dp0"
echo.
echo   也可以手动卸载（管理员 PowerShell 里跑）：
echo     powershell -ExecutionPolicy Bypass -File "%~dp0Install-40HXUnlock.ps1" -Mode Uninstall -Yes
echo ============================================================
if not "%NO_PAUSE%"=="1" pause
exit /b 1

:quit
echo 已取消，什么都没改。
if not "%NO_PAUSE%"=="1" pause
exit /b 0
