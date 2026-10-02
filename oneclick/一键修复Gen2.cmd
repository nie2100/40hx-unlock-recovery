@echo off
chcp 936 >nul
title 40HX 一键修复 PCIe Gen2
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0一键修复Gen2.ps1"
set "RC=%ERRORLEVEL%"
echo.
if %RC% NEQ 0 (
  echo.
  echo [X] 修复脚本返回错误码 %RC% —— 这次没修成功,
  echo     请把桌面上的 40HX-Gen2修复结果-*.txt 和 retrain-last.log 发回来 ^(这两个是证据^)
) else (
  echo.
  echo [OK] 修复脚本跑完了 ^(退出码 0^)：结果与日志已存到桌面, 需要时发给技术即可
)
if not "%NO_PAUSE%"=="1" pause >nul
rem 2026-10-02（第三方审查）：退出码要传出去 —— 否则自动化/批处理看到恒 0，把"没修好"当成功
exit /b %RC%
