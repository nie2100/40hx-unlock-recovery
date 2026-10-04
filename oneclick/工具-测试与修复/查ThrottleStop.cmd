@echo off
rem 2026-10-04: double-click entry for the ThrottleStop driver inspector (read-only).
rem   Forwards to ²éThrottleStop.ps1 which self-elevates (UAC) and writes a report to the desktop.
rem   Optional switch:  -Deep   also scan the ESP fallback copy (mounts the EFI partition briefly).
chcp 936 >nul
title 40HX - ThrottleStop driver inspector (read only)
cd /d "%~dp0"
set "PSARGS="
if /I "%~1"=="-deep" set "PSARGS=-Deep"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0²éThrottleStop.ps1" %PSARGS%
if not "%NO_PAUSE%"=="1" pause >nul
