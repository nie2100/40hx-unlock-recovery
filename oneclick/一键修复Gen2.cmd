@echo off
chcp 936 >nul
title 40HX 一键修复 PCIe Gen2
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0一键修复Gen2.ps1"
echo.
echo ===== 跑完了：把桌面上的 40HX-Gen2修复结果-*.txt 和 retrain-inpout.log 发回来 =====
if not "%NO_PAUSE%"=="1" pause >nul
