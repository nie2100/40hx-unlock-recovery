@echo off
chcp 936 >nul
title CMP40HX 热修 + 立即验证
cd /d "%~dp0"
if not exist "%~dp0apply-hotfix.ps1" (
  echo [错误] 找不到 apply-hotfix.ps1 —— 请把整个文件夹一起拷过来，别只拷这个 cmd。
  pause
  exit /b 2
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply-hotfix.ps1" -VerifyNow
