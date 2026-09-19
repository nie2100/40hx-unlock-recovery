@echo off
setlocal EnableExtensions
title CMP40HX Full Uninstall v0.1.1

fltmc >nul 2>&1
if errorlevel 1 (
  echo [CMP40HX] ERROR: Run this script as Administrator.
  pause
  exit /b 2
)

echo ============================================================
echo CMP40HX Full Uninstall
echo ============================================================
echo This removes:
echo   1. Package-owned UEFI boot entry + EFI image
echo   2. CMP40HX Gen2 scheduled task + package-owned reader state
echo.
echo BCD/firmware snapshots are intentionally kept under:
echo   C:\ProgramData\CMP40HXGen2\efi
echo.
choice /C YN /N /M "Continue? [Y/N]: "
if errorlevel 2 exit /b 0

rem Remove EFI first so its recorded GUID cannot be lost.
call "%~dp0Remove_EFI_Boot.cmd"
call "%~dp0Uninstall_Auto.cmd"

echo.
echo [CMP40HX] Full uninstall sequence finished.
echo [CMP40HX] Safety backups, if present, remain under C:\ProgramData\CMP40HXGen2\efi
pause
exit /b 0
