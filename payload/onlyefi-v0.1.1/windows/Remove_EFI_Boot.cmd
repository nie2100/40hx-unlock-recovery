@echo off
setlocal EnableExtensions
title CMP40HX EFI Boot Entry Remover v0.1.1

fltmc >nul 2>&1
if errorlevel 1 (
  echo [CMP40HX] ERROR: Run this script as Administrator.
  pause
  exit /b 2
)

set "STATE_DIR=%ProgramData%\CMP40HXGen2\efi"
set "GUID_FILE=%STATE_DIR%\efi_boot_guid.txt"
set "EFI_DIR=\EFI\CMP40HX"
set "EFI_PATH=\EFI\CMP40HX\40HXUNLK.EFI"
set "ESP="

if exist "%GUID_FILE%" (
  set /p GUID=<"%GUID_FILE%"
  if defined GUID (
    echo [CMP40HX] Deleting the firmware entry created by this package:
    echo   %GUID%
    bcdedit /delete %GUID% /cleanup
  )
) else (
  echo [CMP40HX] No owned firmware-entry GUID was recorded.
  echo [CMP40HX] No NVRAM entry will be guessed or deleted.
)

for %%L in (S R Q P O N M L K J I H G F E) do (
  if not defined ESP (
    if not exist "%%L:\" (
      mountvol %%L: /S >nul 2>&1
      if not errorlevel 1 set "ESP=%%L"
    )
  )
)

if defined ESP (
  if exist "%ESP%:%EFI_PATH%" (
    echo [CMP40HX] Removing %EFI_PATH% from ESP...
    del /f /q "%ESP%:%EFI_PATH%" >nul 2>&1
    rd "%ESP%:%EFI_DIR%" >nul 2>&1
  )
  mountvol %ESP%: /D >nul 2>&1
)

del /q "%GUID_FILE%" >nul 2>&1

echo.
echo [CMP40HX] EFI boot-entry cleanup complete.
echo [CMP40HX] Windows Boot Manager itself was not deleted or replaced.
pause
exit /b 0
