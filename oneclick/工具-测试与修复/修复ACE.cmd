@echo off
rem 2026-10-04: 双击入口 —— 等价于 ACE修复.cmd /fix。**会改系统**：恢复 ACE-BOOT / ThrottleStop 退场 / 清掉重装它的自启项。
rem   只读体检请用同目录的 ACE修复.cmd（不加参数）。2026-10-04 第三方审查 中-7：两个入口名只差字序，必须显式区分。
chcp 936 >nul
title 40HX ACE 修复【会改系统】- 只读体检请用 ACE修复.cmd
echo ============================================================
echo   这是【会改系统】的 ACE 修复（= ACE修复.cmd /fix）
echo     它会：恢复 ACE-BOOT 运行 / 让 ThrottleStop 退场 / 清掉重装它的自启项
echo   只做只读体检 -> 请关掉本窗口，双击同目录的 ACE修复.cmd
echo ============================================================
echo.
timeout /t 3 /nobreak >nul 2>&1
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ACE修复.ps1" -Fix
if not "%NO_PAUSE%"=="1" pause >nul