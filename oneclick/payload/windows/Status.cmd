@echo off
setlocal
set "ROOT=%ProgramData%\CMP40HXGen2"
set "DST=%ROOT%\windows"
set "EFI_STATE=%ROOT%\efi"
echo ==== CMP40HX Gen2 v0.1.1 package / v0.1.0 validated core ====
echo.
echo ==== services ====
sc query ThrottleStop
sc query WinRing0_1_2_0
echo.
echo ==== scheduled task ====
schtasks /Query /TN "CMP40HX Gen2 PostBind" /V /FO LIST
echo.
echo ==== EFI installer state ====
if exist "%EFI_STATE%\efi_boot_guid.txt" (
  set /p GUID=<"%EFI_STATE%\efi_boot_guid.txt"
  echo Owned firmware entry: %GUID%
) else (
  echo No package-owned EFI GUID recorded.
)
echo.
echo ==== last log ====
if exist "%DST%\logs\last.log" (
  type "%DST%\logs\last.log"
) else (
  echo No automatic-run log yet.
)
pause
