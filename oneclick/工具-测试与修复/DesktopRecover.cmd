@echo off
chcp 936 >nul
title 40HX - desktop/shell recovery
cd /d "%~dp0"
set "A="
if /I "%~1"=="/fix" set "A=-Fix"
if /I "%~1"=="/disableace" set "A=-DisableAce"
if /I "%~1"=="/restoreautorun" set "A=-RestoreAutorun"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DesktopRecover.ps1" %A%
if not "%NO_PAUSE%"=="1" pause >nul
