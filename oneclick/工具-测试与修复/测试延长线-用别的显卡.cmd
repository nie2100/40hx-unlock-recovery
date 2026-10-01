@echo off
chcp 936 >nul
title 用别的显卡测延长线（只读）
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0测试延长线-用别的显卡.ps1"
echo.
echo ===== 建议：空载读一次，跑 5~10 分钟游戏/烤机 再读一次，两份都发回来 =====
if not "%NO_PAUSE%"=="1" pause >nul
