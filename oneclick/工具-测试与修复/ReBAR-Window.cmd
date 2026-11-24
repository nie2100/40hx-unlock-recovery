@echo off
setlocal
rem CMP 40HX ReBAR 8 GiB manual window (X99). Self-elevates, then runs ReBAR-Window.ps1.
if "%~1"=="" goto menu
set "MODE=%~1"
goto run
:menu
echo.
echo   1  Check    read-only status (BAR1 / 4G-above MMIO windows / boot entries)
echo   2  Test     deploy ReBAR EFI + boot entry with rebarwin, one-shot BootNext, then FULL SHUTDOWN
echo   3  Persist  after a successful Test: put it first in BootOrder + self-heal logon task
echo   4  Undo     clear BootNext + remove the self-heal task
echo.
set "SEL="
set /p "SEL=Select [1-4]: "
if "%SEL%"=="1" set "MODE=Check"
if "%SEL%"=="2" set "MODE=Test"
if "%SEL%"=="3" set "MODE=Persist"
if "%SEL%"=="4" set "MODE=Undo"
if not defined MODE goto menu
:run
fltmc >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%MODE%'" >nul 2>&1
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ReBAR-Window.ps1" -Mode %MODE%
echo.
pause
