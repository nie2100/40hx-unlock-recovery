@echo off
setlocal EnableExtensions EnableDelayedExpansion
title CMP40HX EFI Boot Entry Installer v0.1.1

fltmc >nul 2>&1
if errorlevel 1 (
  echo [CMP40HX] ERROR: Run this script as Administrator.
  pause
  exit /b 2
)

set "ENTRY_NAME=CMP40HX Unlock"
set "EFI_DIR=\EFI\CMP40HX"
set "EFI_PATH=\EFI\CMP40HX\40HXUNLK.EFI"
set "SRC_EFI=%~dp0..\EFI\40HXUNLK.EFI"
set "STATE_DIR=%ProgramData%\CMP40HXGen2\efi"
set "GUID_FILE=%STATE_DIR%\efi_boot_guid.txt"
set "BCD_BACKUP=%STATE_DIR%\bcd_before_cmp40hx.bcd"
set "FW_SNAPSHOT=%STATE_DIR%\firmware_before_cmp40hx.txt"
set "ESP="
set "NEW_ENTRY=0"

if not exist "%SRC_EFI%" (
  echo [CMP40HX] ERROR: EFI image not found:
  echo   %SRC_EFI%
  echo.
  echo This script must stay in the package "windows" directory.
  pause
  exit /b 3
)

if not exist "%STATE_DIR%" md "%STATE_DIR%" >nul 2>&1

echo [CMP40HX] Saving BCD and firmware-entry snapshots...
bcdedit /export "%BCD_BACKUP%" >nul 2>&1
if errorlevel 1 (
  echo [CMP40HX] ERROR: BCD backup failed. No changes made.
  pause
  exit /b 4
)
bcdedit /enum firmware /v > "%FW_SNAPSHOT%" 2>&1

rem Mount ESP on the first free letter from a conservative list.
for %%L in (S R Q P O N M L K J I H G F E) do (
  if not defined ESP (
    if not exist "%%L:\" (
      mountvol %%L: /S >nul 2>&1
      if not errorlevel 1 set "ESP=%%L"
    )
  )
)

if not defined ESP (
  echo [CMP40HX] ERROR: Could not mount the EFI System Partition.
  echo [CMP40HX] Confirm this Windows installation is booted in UEFI mode.
  pause
  exit /b 5
)

echo [CMP40HX] ESP mounted as %ESP%:

if not exist "%ESP%:\EFI" (
  echo [CMP40HX] ERROR: Mounted partition does not look like an EFI System Partition.
  goto :rollback_file
)

if not exist "%ESP%:%EFI_DIR%" md "%ESP%:%EFI_DIR%" >nul 2>&1
if errorlevel 1 (
  echo [CMP40HX] ERROR: Failed to create %EFI_DIR%.
  goto :rollback_file
)

copy /y "%SRC_EFI%" "%ESP%:%EFI_PATH%" >nul
if errorlevel 1 (
  echo [CMP40HX] ERROR: Failed to copy 40HXUNLK.EFI to ESP.
  goto :rollback_file
)

echo [CMP40HX] EFI image installed:
echo   %ESP%:%EFI_PATH%

rem Reuse the entry previously created by this installer if it still exists.
set "GUID="
if exist "%GUID_FILE%" (
  set /p GUID=<"%GUID_FILE%"
  if defined GUID (
    bcdedit /enum !GUID! >nul 2>&1
    if errorlevel 1 set "GUID="
  )
)

if defined GUID (
  echo [CMP40HX] Reusing owned firmware entry: !GUID!
) else (
  echo [CMP40HX] Creating a dedicated firmware boot entry...
  for /f "tokens=2 delims={}" %%G in ('bcdedit /copy {bootmgr} /d "%ENTRY_NAME%"') do (
    if not defined GUID set "GUID={%%G}"
  )
  if not defined GUID (
    echo [CMP40HX] ERROR: BCDEdit did not return a GUID.
    goto :rollback_file
  )
  >"%GUID_FILE%" echo !GUID!
  set "NEW_ENTRY=1"
)

echo [CMP40HX] Configuring !GUID! ...
bcdedit /set !GUID! device partition=%ESP%: >nul
if errorlevel 1 goto :rollback_entry
bcdedit /set !GUID! path %EFI_PATH% >nul
if errorlevel 1 goto :rollback_entry
bcdedit /set !GUID! description "%ENTRY_NAME%" >nul
if errorlevel 1 goto :rollback_entry

rem Put the dedicated entry first in firmware order without modifying Windows Boot Manager itself.
echo [CMP40HX] Putting CMP40HX Unlock first in UEFI firmware boot order...
bcdedit /set {fwbootmgr} displayorder !GUID! /addfirst >nul
if errorlevel 1 goto :rollback_entry

echo.
echo [CMP40HX] Verifying the new entry...
bcdedit /enum !GUID! /v
if errorlevel 1 goto :rollback_entry

mountvol %ESP%: /D >nul 2>&1
echo.
echo [CMP40HX] SUCCESS.
echo [CMP40HX] Firmware entry : !GUID!
echo [CMP40HX] EFI path       : %EFI_PATH%
echo [CMP40HX] Boot order     : first
echo [CMP40HX] Backup         : %BCD_BACKUP%
echo.
echo Reboot once. The EFI should unlock the card and chainload Windows automatically.
echo After Windows starts, run RunOnce.cmd once. If Gen2 x16 passes, run Install_Auto.cmd.
pause
exit /b 0

:rollback_entry
echo.
echo [CMP40HX] ERROR: Failed while configuring the firmware entry.
if "%NEW_ENTRY%"=="1" (
  echo [CMP40HX] Removing newly-created entry !GUID! ...
  bcdedit /delete !GUID! /cleanup >nul 2>&1
  del /q "%GUID_FILE%" >nul 2>&1
)

:rollback_file
if defined ESP (
  del /q "%ESP%:%EFI_PATH%" >nul 2>&1
  rd "%ESP%:%EFI_DIR%" >nul 2>&1
  mountvol %ESP%: /D >nul 2>&1
)
echo [CMP40HX] This install attempt was rolled back.
echo [CMP40HX] BCD backup remains at:
echo   %BCD_BACKUP%
pause
exit /b 10
