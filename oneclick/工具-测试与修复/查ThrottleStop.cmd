@echo off
rem 2026-10-04: double-click entry for the ThrottleStop driver inspector (read-only).
rem   Forwards to 查ThrottleStop.ps1 which self-elevates (UAC) and writes a report to the desktop.
rem   Optional switch:  -Deep   also scan the ESP fallback copy (mounts the EFI partition briefly).
chcp 936 >nul
title 40HX - ThrottleStop driver inspector (read only)
cd /d "%~dp0"

rem ---- 2026-10-04: preflight ------------------------------------------------------------
rem Single line + label at EOF on purpose: a parenthesised block breaks when the folder
rem   name contains ) or & (e.g. Windows unpacks twice -> "xxx (1)").
if not exist "%~dp0查ThrottleStop.ps1" goto nops1
set "PSARGS="
if /I "%~1"=="-deep" set "PSARGS=-Deep"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0查ThrottleStop.ps1" %PSARGS%
set "RC=%ERRORLEVEL%"
if not "%NO_PAUSE%"=="1" pause >nul
rem 2026-10-04: carry the real exit code out (was implicit 0) and never fall into :nops1
exit /b %RC%

:nops1
echo ============================================================
echo  [注意] 没找到 查ThrottleStop.ps1
echo    本工具要靠同目录的这个 .ps1 干活；现在读不到它，所以什么都还没做
echo    （Windows 会因此显示 -196608，也就是 0xFFFD0000）
echo    1. 别在压缩包里直接运行 —— 先把 zip 完整解压到一个文件夹再运行
echo    2. 杀软可能把 .ps1 删了或隔离了 —— 到隔离区恢复它，并把本目录加进信任区
echo    3. .ps1 必须与本 .cmd 在同一个目录（只拷 .cmd 出来不管用）
echo    4. 包别放在映射的网络盘或共享目录上 —— 拷到本机硬盘再运行
echo 当前目录（可截图发回）
echo      "%~dp0"
echo ============================================================
if not "%NO_PAUSE%"=="1" pause >nul
exit /b 1
