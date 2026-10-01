@echo off
chcp 936 >nul
title 40HX 安全模式修复（开机蓝屏）
net session >nul 2>&1
if errorlevel 1 (
  echo 需要管理员权限，正在自动提权...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
  exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0安全模式-修复.ps1"
echo.
echo ===== 做完了：直接正常重启，应该能进系统；结果在桌面 40HX-安全模式修复-*.txt =====
if not "%NO_PAUSE%"=="1" pause >nul
