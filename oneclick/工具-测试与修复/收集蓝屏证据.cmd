@echo off
chcp 936 >nul
title 40HX 蓝屏取证
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0收集蓝屏证据.ps1"
echo.
echo ===== 结果在桌面：40HX-蓝屏证据-*.txt（把它发回来即可）=====
if not "%NO_PAUSE%"=="1" pause >nul
