@echo off
rem 2026-10-04: 双击入口 —— CMP 40HX 的 GSP（GPU 固件）诊断；加 /fix 才会写注册表。
chcp 936 >nul
title 40HX GSP 诊断/修复 - 默认只读，/fix 才写注册表
echo ============================================================
echo   CMP 40HX  GSP（GPU 固件）诊断    默认只读
echo     跑完会自动打开报告（记事本）
echo   要顺手修复（GSP 没开时写 EnableGpuFirmware=1）: 查GSP.cmd /fix
echo ============================================================
echo.
cd /d "%~dp0"
set "PSARGS="
if /I "%~1"=="/fix" set "PSARGS=-Fix"
rem 2026-10-04: NO_ELEVATE=1 时把 -NoElevate 传下去（无人值守 / 自动化验证用，不弹 UAC）
if "%NO_ELEVATE%"=="1" set "PSARGS=%PSARGS% -NoElevate"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0查GSP.ps1" %PSARGS%
if not "%NO_PAUSE%"=="1" pause >nul
