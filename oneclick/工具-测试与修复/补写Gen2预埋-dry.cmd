@echo off
chcp 936 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title 40HX Gen2 预埋 dry-run（只看，不写）
rem ---- 2026-10-05: preflight + self-elevation (same pattern as 一键安装.cmd) -------------------
rem Single line + label at EOF on purpose: a parenthesised block breaks when the folder name
rem   contains ) or & (Windows unpacks twice -> "xxx (1)"). Never leave a bare "if" with no command:
rem   cmd aborts the whole script with 255 (that is what made the old dry.cmd flash and close).
if not exist "%~dp0补写Gen2预埋.ps1" goto nops1
echo %* | findstr /i "dry" >nul && set "MODE=-DryOnly"
echo %* | findstr /i "elevated" >nul && goto run
net session >nul 2>&1
if errorlevel 1 goto ask

:run
echo ============================================================
echo   40HX Gen2 预埋 dry-run（只看，不写）
echo ============================================================
echo   本文件只做 dry-run：不写任何 GPU 寄存器（只生成原值备份文件）。
echo   看明白要写什么之后，双击 补写Gen2预埋.cmd 再真写。
echo   全程不停 ACE-BOOT、不复位显卡；算力解锁不受影响。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0补写Gen2预埋.ps1" %MODE%
set "RC=%ERRORLEVEL%"
echo.
echo   退出码: %RC%   （0 = 正常结束；其它见上面输出或桌面报告）
echo ============================================================
pause
exit /b %RC%

:ask
echo ============================================================
echo   40HX Gen2 预埋 dry-run（只看，不写）
echo ============================================================
echo   需要管理员权限（会动 GPU 内部寄存器，必须提权）。
echo   马上弹 UAC，请点"是"；点了之后**新的黑窗口**里才是真正在跑，
echo   那个窗口跑完会自己停住等你按键，不会闪退。
echo.
pause
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated','dry' -Verb RunAs"
goto :eof

:nops1
echo ============================================================
echo   [注意] 没找到 补写Gen2预埋.ps1
echo ============================================================
echo   它必须和本 .cmd 放在**同一个文件夹**里。
echo   当前目录（可截图发回）：
echo      "%~dp0"
echo.
pause
exit /b 1
