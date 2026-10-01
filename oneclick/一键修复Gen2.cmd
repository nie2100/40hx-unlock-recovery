@echo off
chcp 936 >nul
title 40HX 一键修复 PCIe Gen2
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0一键修复Gen2.ps1"
echo.
if errorlevel 1 (
  echo.
  echo [X] 修复脚本返回了错误码 %ERRORLEVEL% —— 说明这次没修成功,
  echo     请把桌面上的 40HX-Gen2修复结果-*.txt 和 retrain-inpout.log 发回来
) else (
  echo.
  echo [OK] 修复脚本跑完了 ^(退出码 0^)：把桌面上的 40HX-Gen2修复结果-*.txt 和 retrain-inpout.log 发回来
)
if not "%NO_PAUSE%"=="1" pause >nul
