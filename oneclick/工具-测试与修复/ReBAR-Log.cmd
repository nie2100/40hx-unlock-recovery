@echo off
setlocal
rem READ-ONLY diagnostic: read ESP \40hx_log.txt and print the [rebar] reason.
fltmc >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'" >nul 2>&1
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ReBAR-Log.ps1"
echo.
pause
