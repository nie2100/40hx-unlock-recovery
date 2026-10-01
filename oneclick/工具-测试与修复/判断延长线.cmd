@echo off
chcp 936 >nul
title 判断 Gen2 上不去是不是延长线
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0判断延长线.ps1"
echo.
echo ===== 结果在桌面：40HX-延长线判定-*.txt（带延长线跑一次，直插再跑一次，两份都发回来）=====
if not "%NO_PAUSE%"=="1" pause >nul
