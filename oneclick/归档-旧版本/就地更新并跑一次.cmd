@echo off
chcp 936 >nul
title 40HX Gen2 就地更新并跑一次
net session >nul 2>&1
if errorlevel 1 (
  echo 需要管理员权限，正在提权...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
  exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0就地更新并跑一次.ps1"
echo.
echo ===== 跑完了，把上面的输出和 retrain-inpout.log 发回来 =====
pause
