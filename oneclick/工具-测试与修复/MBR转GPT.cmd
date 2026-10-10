@echo off
rem Copyright 2026 nie2100 - All rights reserved; redistribution or resale not permitted.
chcp 936 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title 40HX 准备：MBR 转 GPT

if not exist "%~dp0MBR转GPT.ps1" goto nops1

echo %* | findstr /i "elevated" >nul && goto run

rem fltmc 不依赖 Server 服务（net session 在精简系统上会误判）
fltmc >nul 2>&1
if errorlevel 1 net session >nul 2>&1
if errorlevel 1 goto ask

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MBR转GPT.ps1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="-196608" goto nops1
if "%RC%"=="196608"  goto nops1
if not "%RC%"=="0" goto runfail
goto runend
:runfail
echo [X] 转换没有完成（退出码 %RC%）—— 按上面提示处理；磁盘没被动过的居多
echo     拿不准就把本窗口截图发给技术
:runend
if not "%NO_PAUSE%"=="1" pause
exit /b %RC%

:ask
echo ==============================================================
echo   MBR 系统盘一键转 GPT（40HX 解锁前提：UEFI + GPT）
echo ==============================================================
echo   这个工具做什么：
echo     用微软官方 mbr2gpt 原地转换系统盘分区表，不动数据。
echo     转换前会先跑官方校验，校验不过就什么都不改。
echo.
echo   必须知道的一件事：
echo     转完重启时要进 BIOS 把引导模式从 Legacy 改成 UEFI
echo    （关 CSM），否则开不了机（数据没丢，BIOS 改对就能进）。
echo.
set /p ANS=回车继续（会先弹 UAC 提权），输入 n 退出: 
if /i "%ANS%"=="n" goto quit
echo.
echo [*] 正在申请管理员权限：会弹 UAC 和一个新的黑窗口
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated %*' -Verb RunAs"
goto :eof

:nops1
echo [注意] 没能开始：PowerShell 没有读到 MBR转GPT.ps1（没解压全/被杀软拦）
if not "%NO_PAUSE%"=="1" pause
exit /b 1

:quit
echo 已取消，什么都没改。
if not "%NO_PAUSE%"=="1" pause
exit /b 0
