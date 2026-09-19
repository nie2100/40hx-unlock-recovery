@echo off
setlocal
title CMP40HX Unlock OnlyEFI v0.1.1

:menu
cls
echo ============================================================
echo CMP40HX Unlock OnlyEFI v0.1.1
echo Hardware-validated production path
echo ============================================================
echo.
echo [1] Install / repair UEFI boot entry
echo [2] Run one-time Gen2 validation
echo [3] Install Windows automatic post-bind task
echo [4] Show status and last log
echo [5] Remove Windows automatic task
echo [6] Remove UEFI boot entry
echo [7] Full uninstall
echo [0] Exit
echo.
choice /C 12345670 /N /M "Select: "
set "C=%ERRORLEVEL%"
if "%C%"=="8" exit /b 0
if "%C%"=="7" call "%~dp0Uninstall_All.cmd"
if "%C%"=="6" call "%~dp0Remove_EFI_Boot.cmd"
if "%C%"=="5" call "%~dp0Uninstall_Auto.cmd"
if "%C%"=="4" call "%~dp0Status.cmd"
if "%C%"=="3" call "%~dp0Install_Auto.cmd"
if "%C%"=="2" call "%~dp0RunOnce.cmd"
if "%C%"=="1" call "%~dp0Install_EFI_Boot.cmd"
goto :menu
