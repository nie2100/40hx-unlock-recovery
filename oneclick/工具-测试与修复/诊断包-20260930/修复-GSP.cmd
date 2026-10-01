@echo off
chcp 936 >nul
setlocal
cd /d "%~dp0"
title CMP 40HX GSP 修复（EnableGpuFirmware=1）
echo %* | findstr /i "elevated" >nul && goto run
net session >nul 2>&1
if errorlevel 1 goto ask
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0修复-GSP.ps1"
echo.
set "RC=%ERRORLEVEL%"
echo 退出码 = %RC%
if not "%RC%"=="0" echo [X] 有项目没写成功 —— 见上面的红字（把这一段拍给经销商）
echo.
pause
rem 2026-10-01b（审查）：把真实退出码传给调用方（原来 goto :eof 恒返回 0）
exit /b %RC%
:ask
echo ==============================================================
echo   CMP 40HX GSP 修复：给 40HX 写 EnableGpuFirmware=1
echo ==============================================================
echo   什么时候用：诊断报告的 [判据 A] 写着 "GSP 未启用" 时才用
echo               （GSP 没开 = 解锁后 nvlddmkm 认不了卡 = 黑屏 + 代码 43）
echo   它做什么：只写这一个注册表值（显示类子键），可逆，不动驱动/服务/EFI
echo   之后必须：完全关机（不是重启）再开机，然后重跑 一键诊断.cmd 复核
echo.
echo [*] 正在申请管理员权限...
echo.
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
goto :eof
