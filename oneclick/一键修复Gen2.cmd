@echo off
rem Copyright 2026 nie2100 - All rights reserved; redistribution or resale not permitted.
rem Upstream MIT parts: CMP40HX-Unlock by PZH1gdmu / CMP40HX-Unlock-OnlyEFI by BardKing-CN.
chcp 936 >nul
title 40HX 一键修复 PCIe Gen2
cd /d "%~dp0"

rem ---- 2026-10-04: preflight ------------------------------------------------------------
rem Single line + label at EOF on purpose: a parenthesised block breaks when the folder
rem   name contains ) or & (e.g. Windows unpacks twice -> "xxx (1)").
if not exist "%~dp0一键修复Gen2.ps1" goto nops1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0一键修复Gen2.ps1"
set "RC=%ERRORLEVEL%"
rem 2026-10-04: -196608 = 0xFFFD0000 = PowerShell never read the script (nothing was done)
if "%RC%"=="-196608" goto nops1
if "%RC%"=="196608"  goto nops1
echo.
if %RC% NEQ 0 (
  echo.
  echo [X] 修复脚本返回错误码 %RC% —— 这次没修成功,
  echo     请把桌面上的 40HX-Gen2修复结果-*.txt 和 retrain-last.log 发回来 ^(这两个是证据^)
) else (
  echo.
  echo [OK] 修复脚本跑完了 ^(退出码 0^)：结果与日志已存到桌面, 需要时发给技术即可
)
if not "%NO_PAUSE%"=="1" pause
rem 2026-10-02（第三方审查）：退出码要传出去 —— 否则自动化/批处理看到恒 0，把"没修好"当成功
exit /b %RC%

:nops1
echo ============================================================
echo   [注意] 修复没能开始：PowerShell 没有读到 一键修复Gen2.ps1
echo   退出码 -196608 就是十六进制 0xFFFD0000（PowerShell 自己"脚本没跑起来"的码），
echo   不是修复脚本报的错 —— 也就是说这次什么都没改。
echo     1. 别在压缩包里直接运行 —— 先把 zip 完整解压到一个文件夹
echo     2. 去杀软隔离区看 一键修复Gen2.ps1 在不在，并把本目录加进信任区
echo     3. 包别放在映射网络盘或共享目录上，拷到本机硬盘（如 D:\40hx）
echo   当前目录（可截图发回）
echo      "%~dp0"
echo ============================================================
if not "%NO_PAUSE%"=="1" pause
exit /b 1

