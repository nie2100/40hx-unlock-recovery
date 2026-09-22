@echo off
chcp 936 >nul 2>&1
title 40HX 解锁状态检查
setlocal

set "SMI=C:\Windows\System32\nvidia-smi.exe"
set "TMPQ=%TEMP%\40hx_q.csv"
set "TMPO=%TEMP%\40hx_bw.out"
set "TMPY=%TEMP%\40hx_bw.py"
set "TMPB=%TEMP%\40hx_bw.b64"
set "STAT=C:\ProgramData\40HXUnlock\gen2_status.txt"
set "LOGP=C:\ProgramData\CMP40HXGen2\windows\logs\postbind.log"

set "OKMODE=0"
set "OKLINK=0"
set "VERD="
set "H2DT="
set "D2HT="

echo ============================================================
echo                 40HX 解锁状态检查
echo ============================================================
echo.

if not exist "%SMI%" (
  echo   [错误] 未找到 %SMI%
  goto :summary
)

"%SMI%" --query-gpu=name,driver_version,memory.total,temperature.gpu,power.draw,power.limit,driver_model.current,driver_model.pending,pcie.link.width.current,pcie.link.width.max --format=csv > "%TMPQ%" 2>nul
if not exist "%TMPQ%" goto :nosmi
for /f "skip=1 tokens=1-10 delims=," %%a in (%TMPQ%) do (
  for /f "tokens=* delims= " %%x in ("%%a") do set "GPU=%%x"
  for /f "tokens=* delims= " %%x in ("%%b") do set "DRV=%%x"
  for /f "tokens=* delims= " %%x in ("%%c") do set "VMEM=%%x"
  for /f "tokens=* delims= " %%x in ("%%d") do set "TEMPC=%%x"
  for /f "tokens=* delims= " %%x in ("%%e") do set "PWR=%%x"
  for /f "tokens=* delims= " %%x in ("%%f") do set "PLIM=%%x"
  for /f "tokens=* delims= " %%x in ("%%g") do set "DMC=%%x"
  for /f "tokens=* delims= " %%x in ("%%h") do set "DMP=%%x"
  for /f "tokens=* delims= " %%x in ("%%i") do set "LWC=%%x"
  for /f "tokens=* delims= " %%x in ("%%j") do set "LWM=%%x"
)

echo [1/5] 显卡与驱动
echo     GPU       : %GPU%
echo     驱动版本  : %DRV%
echo     显存      : %VMEM%
echo     温度/功耗 : %TEMPC% C / %PWR%  (上限 %PLIM%)
echo.

echo [2/5] 驱动模式   (WDDM = WSL 直通可用)
echo     当前 : %DMC%     待生效 : %DMP%
if /I "%DMC%"=="WDDM" set "OKMODE=1"
if /I "%DMC%"=="WDDM" echo     [OK] WDDM 模式正常
if /I "%DMC%"=="TCC" echo     [!!] TCC 模式异常: WSL 直通会失效, PCIe 也会掉回 Gen1
echo.

echo [3/5] PCIe 链路   (实测带宽, 唯一可信判据)
echo     链路宽度 : x%LWC%   (最大 x%LWM%)
set "PY="
if exist "%LOCALAPPDATA%\Programs\Python\Python311\python.exe" set "PY=%LOCALAPPDATA%\Programs\Python\Python311\python.exe"
if not defined PY if exist "C:\Windows\py.exe" set "PY=C:\Windows\py.exe"
if not defined PY for /f "delims=" %%p in ('where python 2^>nul') do if not defined PY set "PY=%%p"
if not defined PY goto :nopython
echo     正在实测带宽 (约 5 秒) ...
>"%TMPB%" echo aW1wb3J0IGN0eXBlcywgc3lzLCB0aW1lCgpkZWYgZmFpbChtc2cpOgogICAgcHJpbnQoIkVSUk9SICIgKyBtc2cpCiAgICBzeXMuZXhpdCgxKQoKdHJ5OgogICAgY3VkYSA9IGN0eXBlcy5XaW5ETEwoIm52Y3VkYS5kbGwiKQpleGNlcHQgRXhjZXB0aW9uOgogICAgZmFpbCgibnZjdWRhLmRsbCBub3QgZm91bmQiKQogICAgcmFpc2UgU3lzdGVtRXhpdCgxKQoKZGV2ID0gY3R5cGVzLmNfaW50KDApCmlmIGN1ZGEuY3VJbml0KDApICE9IDA6CiAgICBmYWlsKCJjdUluaXQgZmFpbGVkIikKaWYgY3VkYS5jdURldmljZUdldChjdHlwZXMuYnlyZWYoZGV2KSwgMCkgIT0gMDoKICAgIGZhaWwoImN1RGV2aWNlR2V0IGZhaWxlZCIpCmN0eCA9IGN0eXBlcy5jX3ZvaWRfcCgpCmlmIGN1ZGEuY3VDdHhDcmVhdGVfdjIoY3R5cGVzLmJ5cmVmKGN0eCksIDAsIGRldikgIT0gMDoKICAgIGZhaWwoImN1Q3R4Q3JlYXRlIGZhaWxlZCIpCgpTSVpFID0gNTEyICogMTAyNCAqIDEwMjQKZHB0ciA9IGN0eXBlcy5jX3ZvaWRfcCgpCmlmIGN1ZGEuY3VNZW1BbGxvY192MihjdHlwZXMuYnlyZWYoZHB0ciksIGN0eXBlcy5jX3NpemVfdChTSVpFKSkgIT0gMDoKICAgIGZhaWwoImN1TWVtQWxsb2MgZmFpbGVkIikKaHB0ciA9IGN0eXBlcy5jX3ZvaWRfcCgpCnIgPSBjdWRhLmN1TWVtSG9zdEFsbG9jKGN0eXBlcy5ieXJlZihocHRyKSwgY3R5cGVzLmNfc2l6ZV90KFNJWkUpLCA1KQppZiByICE9IDA6CiAgICByID0gY3VkYS5jdU1lbUhvc3RBbGxvYyhjdHlwZXMuYnlyZWYoaHB0ciksIGN0eXBlcy5jX3NpemVfdChTSVpFKSwgMSkKaWYgciAhPSAwOgogICAgZmFpbCgiY3VNZW1Ib3N0QWxsb2MgZmFpbGVkIikKClJFUFMgPSAxMAoKZGVmIHJ1bihkaXJlY3Rpb24pOgogICAgaWYgZGlyZWN0aW9uID09ICJIMkQiOgogICAgICAgIGZuLCBzcmMsIGRzdCA9IGN1ZGEuY3VNZW1jcHlIdG9EX3YyLCBocHRyLCBkcHRyCiAgICBlbHNlOgogICAgICAgIGZuLCBzcmMsIGRzdCA9IGN1ZGEuY3VNZW1jcHlEdG9IX3YyLCBkcHRyLCBocHRyCiAgICBmbihkc3QsIHNyYywgY3R5cGVzLmNfc2l6ZV90KFNJWkUpKQogICAgdDAgPSB0aW1lLnRpbWUoKQogICAgZm9yIF8gaW4gcmFuZ2UoUkVQUyk6CiAgICAgICAgZm4oZHN0LCBzcmMsIGN0eXBlcy5jX3NpemVfdChTSVpFKSkKICAgIGR0ID0gdGltZS50aW1lKCkgLSB0MAogICAgaWYgZHQgPD0gMDoKICAgICAgICBmYWlsKCJ0aW1pbmcgZmFpbGVkIikKICAgIHJldHVybiBSRVBTICogU0laRSAvIGR0IC8gMWU5CgpoYncgPSBydW4oIkgyRCIpCmRidyA9IHJ1bigiRDJIIikKcHJpbnQoIkgyRCAlLjJmIiAlIGhidykKcHJpbnQoIkgyRElOVCAlZCIgJSBpbnQoaGJ3ICogMTAwKSkKcHJpbnQoIkQySCAlLjJmIiAlIGRidykKcHJpbnQoIlZFUkRJQ1QgIiArICgiR0VOMiIgaWYgaGJ3ID49IDQuNSBlbHNlICJHRU4xIikpCg==
certutil -decode "%TMPB%" "%TMPY%" >nul 2>&1
if not exist "%TMPY%" goto :nopython
"%PY%" "%TMPY%" > "%TMPO%" 2>nul
if not exist "%TMPO%" goto :nopython
for /f "tokens=1,2 delims= " %%a in (%TMPO%) do (
  if /I "%%a"=="H2D" set "H2DT=%%b"
  if /I "%%a"=="D2H" set "D2HT=%%b"
  if /I "%%a"=="VERDICT" set "VERD=%%b"
)
if not defined H2DT set "H2DT=失败"
if not defined D2HT set "D2HT=失败"
echo     H2D 带宽 : %H2DT% GB/s
echo     D2H 带宽 : %D2HT% GB/s
echo     参考值   : Gen1 约 3.1-3.4 / Gen2 约 5.8-6.7 GB/s
if /I "%VERD%"=="GEN2" set "OKLINK=1"
if /I "%VERD%"=="GEN2" echo     [OK] 判定: Gen2 已解锁
if /I "%VERD%"=="GEN1" echo     [!!] 判定: Gen1 未解锁
if not defined VERD echo     [!!] 判定: 带宽测试失败
echo.
goto :gen2info

:nosmi
echo [1/5] 显卡与驱动
echo     [!!] nvidia-smi 无输出, 驱动可能异常
echo.
goto :summary

:nopython
echo     [!!] 未找到可用的 Python, 无法实测带宽
echo     (本机应有 C:\Windows\py.exe)
echo.
goto :gen2info

:gen2info
echo [4/5] 开机自动重训任务 (CMP40HXGen2)
if exist "%LOGP%" (
  powershell -NoProfile -Command "Select-String -Path '%LOGP%' -Pattern 'PostBind start','PostBind EXIT','PASS:','FAIL:' -Encoding Default | Select-Object -Last 3 | ForEach-Object { $_.Line }"
) else (
  echo     [--] 未找到日志 %LOGP%
)
echo.

echo [5/5] 解锁工具状态文件
if exist "%STAT%" (
  powershell -NoProfile -Command "$c = Get-Content '%STAT%' -Encoding UTF8; Write-Output ('    written: ' + (Get-Item '%STAT%').LastWriteTime); $c -replace ([char]0x2705),'[OK]' -replace ([char]0x274C),'[NG]' -replace ([char]0x2713),'v' -replace ([char]0x26A0),'!' -replace ([char]0xFE0F),''"
) else (
  echo     [--] 未找到 %STAT%
)
echo.

:summary
echo ============================================================
if "%OKMODE%%OKLINK%"=="11" (
  echo   结论: 全绿 -- WDDM 模式 + PCIe Gen2, 解锁正常
) else (
  echo   结论: 存在异常
  if "%OKMODE%"=="0" echo     - 驱动模式不是 WDDM: 管理员执行 nvidia-smi -dm 0, 然后重启
  if "%OKLINK%"=="0" echo     - PCIe 未达 Gen2: 先重启让开机任务重训; 仍不行检查 ACE-BOOT 是否拦截
)
echo ============================================================
echo.
echo 按任意键退出...
pause >nul
