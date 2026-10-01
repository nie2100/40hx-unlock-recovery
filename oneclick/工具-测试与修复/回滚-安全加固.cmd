@echo off
chcp 936 >nul
title 回滚安全加固（40HX 一键包）
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0回滚-安全加固.ps1"
if errorlevel 1 (
  echo.
  echo [X] 回滚脚本返回了错误码 %ERRORLEVEL% —— 把上面的输出拍给经销商
) else (
  echo.
  echo [OK] 回滚脚本跑完了
)
echo.
pause
