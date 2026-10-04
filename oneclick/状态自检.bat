@echo off
chcp 936 >nul 2>&1
title 40HX 解锁状态检查
setlocal

set "SMI=C:\Windows\System32\nvidia-smi.exe"
set "TMPQ=%TEMP%\40hx_q.csv"
set "TMPO=%TEMP%\40hx_bw.out"
set "TMPCS=%TEMP%\40hx_bw.cs"
set "TMPE=%TEMP%\40hx_bw.exe"
set "TMPC=%TEMP%\40hx_bw_csc.log"
set "TMPB=%TEMP%\40hx_bw.b64"
set "STAT=C:\ProgramData\40HXUnlock\gen2_status.txt"
set "LOGP=C:\ProgramData\CMP40HXGen2\windows\logs\postbind.log"

set "OKMODE=0"
set "OKLINK=0"
set "OKPOWER=0"
set "VERD="
set "H2DT="
set "D2HT="
set "FP32T="
set "FP16T="
set "TCT="
set "VRAMT="

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
rem 2026-10-02 修 BUG：这里以前写成 in ("%TMPQ%") —— 带引号的单个 token 会被 for /f 当成**字符串**
rem   而不是文件名（配合 skip=1 就一行都不解析），结果 GPU/驱动/链路宽度全是空值 → 结论永远"存在异常"。
rem   正确写法 = usebackq + 引号（既能当文件读，又能容忍路径里有空格）。
for /f "usebackq skip=1 tokens=1-10 delims=," %%a in ("%TMPQ%") do (
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

echo [1/6] 显卡与驱动
echo     GPU       : %GPU%
echo     驱动版本  : %DRV%
echo     显存      : %VMEM%
echo     温度/功耗 : %TEMPC% C / %PWR%  (上限 %PLIM%)
echo.

echo [2/6] 驱动模式   (WDDM = WSL 直通可用)
echo     当前 : %DMC%     待生效 : %DMP%
if /I "%DMC%"=="WDDM" set "OKMODE=1"
if /I "%DMC%"=="WDDM" echo     [OK] WDDM 模式正常
if /I "%DMC%"=="TCC" echo     [!!] TCC 模式异常: WSL 直通会失效, PCIe 也会掉回 Gen1
echo.

echo [3/6] PCIe 链路   (实测带宽, 唯一可信判据)
echo     链路宽度 : x%LWC%   (最大 x%LWM%)
set "CSC="
if exist "%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not defined CSC if exist "%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not defined CSC goto :nocompiler
echo     正在实测链路与算力 (首次要先编译内置小程序, 约 20 秒) ...
> "%TMPB%" echo Ly8gNDBIWCBQQ0llL0NVREEgc2VsZi10ZXN0IHByb2JlIC0gY29tcGlsZWQgb24gdGhlIGZseSBi
>> "%TMPB%" echo eSBjc2MuZXhlIChubyBQeXRob24gbmVlZGVkKS4KLy8gTWlycm9ycyB0aGUgcHJldmlvdXMgUHl0
>> "%TMPB%" echo aG9uIGN0eXBlcyBwcm9iZTogbnZjdWRhLmRsbCBtZW1jcHkgYmFuZHdpZHRoICsgRlAzMi9GUDE2
>> "%TMPB%" echo L1RlbnNvckNvcmUgcGVhay4KLy8gRW1pdHM6IFNNIENPUkVTIEZQMzIgRlAzMklOVCBGUDE2IEZQ
>> "%TMPB%" echo MTZJTlQgVEMgVENJTlQgVlJBTSBWUkFNSU5UIEgyRCBIMkRJTlQgRDJIIFZFUkRJQ1QKdXNpbmcg
>> "%TMPB%" echo U3lzdGVtOwp1c2luZyBTeXN0ZW0uRGlhZ25vc3RpY3M7CnVzaW5nIFN5c3RlbS5HbG9iYWxpemF0
>> "%TMPB%" echo aW9uOwp1c2luZyBTeXN0ZW0uUnVudGltZS5JbnRlcm9wU2VydmljZXM7CnVzaW5nIFN5c3RlbS5U
>> "%TMPB%" echo ZXh0OwoKY2xhc3MgR3B1QmVuY2gKewogICAgW0RsbEltcG9ydCgibnZjdWRhLmRsbCIpXSBzdGF0
>> "%TMPB%" echo aWMgZXh0ZXJuIGludCBjdUluaXQodWludCBmbGFncyk7CiAgICBbRGxsSW1wb3J0KCJudmN1ZGEu
>> "%TMPB%" echo ZGxsIildIHN0YXRpYyBleHRlcm4gaW50IGN1RGV2aWNlR2V0KG91dCBpbnQgZGV2LCBpbnQgb3Jk
>> "%TMPB%" echo aW5hbCk7CiAgICBbRGxsSW1wb3J0KCJudmN1ZGEuZGxsIildIHN0YXRpYyBleHRlcm4gaW50IGN1
>> "%TMPB%" echo RGV2aWNlR2V0QXR0cmlidXRlKG91dCBpbnQgdiwgaW50IGF0dHJpYiwgaW50IGRldik7CiAgICBb
>> "%TMPB%" echo RGxsSW1wb3J0KCJudmN1ZGEuZGxsIildIHN0YXRpYyBleHRlcm4gaW50IGN1Q3R4Q3JlYXRlX3Yy
>> "%TMPB%" echo KG91dCBJbnRQdHIgY3R4LCB1aW50IGZsYWdzLCBpbnQgZGV2KTsKICAgIFtEbGxJbXBvcnQoIm52
>> "%TMPB%" echo Y3VkYS5kbGwiKV0gc3RhdGljIGV4dGVybiBpbnQgY3VNZW1BbGxvY192MihvdXQgSW50UHRyIHAs
>> "%TMPB%" echo IFVJbnRQdHIgc2l6ZSk7CiAgICBbRGxsSW1wb3J0KCJudmN1ZGEuZGxsIildIHN0YXRpYyBleHRl
>> "%TMPB%" echo cm4gaW50IGN1TWVtSG9zdEFsbG9jKG91dCBJbnRQdHIgcCwgVUludFB0ciBzaXplLCB1aW50IGZs
>> "%TMPB%" echo YWdzKTsKICAgIFtEbGxJbXBvcnQoIm52Y3VkYS5kbGwiKV0gc3RhdGljIGV4dGVybiBpbnQgY3VN
>> "%TMPB%" echo ZW1jcHlIdG9EX3YyKEludFB0ciBkc3QsIEludFB0ciBzcmMsIFVJbnRQdHIgbik7CiAgICBbRGxs
>> "%TMPB%" echo SW1wb3J0KCJudmN1ZGEuZGxsIildIHN0YXRpYyBleHRlcm4gaW50IGN1TWVtY3B5RHRvSF92MihJ
>> "%TMPB%" echo bnRQdHIgZHN0LCBJbnRQdHIgc3JjLCBVSW50UHRyIG4pOwogICAgW0RsbEltcG9ydCgibnZjdWRh
>> "%TMPB%" echo LmRsbCIpXSBzdGF0aWMgZXh0ZXJuIGludCBjdU1lbWNweUR0b0RfdjIoSW50UHRyIGRzdCwgSW50
>> "%TMPB%" echo UHRyIHNyYywgVUludFB0ciBuKTsKICAgIFtEbGxJbXBvcnQoIm52Y3VkYS5kbGwiKV0gc3RhdGlj
>> "%TMPB%" echo IGV4dGVybiBpbnQgY3VDdHhTeW5jaHJvbml6ZSgpOwogICAgW0RsbEltcG9ydCgibnZjdWRhLmRs
>> "%TMPB%" echo bCIpXSBzdGF0aWMgZXh0ZXJuIGludCBjdU1vZHVsZUxvYWREYXRhKG91dCBJbnRQdHIgbW9kLCBJ
>> "%TMPB%" echo bnRQdHIgaW1hZ2UpOwogICAgW0RsbEltcG9ydCgibnZjdWRhLmRsbCIpXSBzdGF0aWMgZXh0ZXJu
>> "%TMPB%" echo IGludCBjdU1vZHVsZUdldEZ1bmN0aW9uKG91dCBJbnRQdHIgZm4sIEludFB0ciBtb2QsIHN0cmlu
>> "%TMPB%" echo ZyBuYW1lKTsKICAgIFtEbGxJbXBvcnQoIm52Y3VkYS5kbGwiKV0gc3RhdGljIGV4dGVybiBpbnQg
>> "%TMPB%" echo Y3VMYXVuY2hLZXJuZWwoSW50UHRyIGZuLCB1aW50IGd4LCB1aW50IGd5LCB1aW50IGd6LAogICAg
>> "%TMPB%" echo ICAgIHVpbnQgYngsIHVpbnQgYnksIHVpbnQgYnosIHVpbnQgc2htZW0sIEludFB0ciBzdHJlYW0s
>> "%TMPB%" echo IEludFB0ciBhcmdzLCBJbnRQdHIgZXh0cmEpOwoKICAgIGNvbnN0IGxvbmcgU0laRSA9IDUxMkwg
>> "%TMPB%" echo KiAxMDI0ICogMTAyNDsKICAgIGNvbnN0IGludCBSRVBTID0gMTA7CiAgICBjb25zdCBpbnQgRFJF
>> "%TMPB%" echo UFMgPSA1MDsKCiAgICBzdGF0aWMgSW50UHRyIGRwdHIgPSBJbnRQdHIuWmVybzsKICAgIHN0YXRp
>> "%TMPB%" echo YyBJbnRQdHIgaHB0ciA9IEludFB0ci5aZXJvOwoKICAgIHN0YXRpYyBzdHJpbmcgUFRYX0ZQMzIg
>> "%TMPB%" echo PSBAIgoudmVyc2lvbiA3LjAKLnRhcmdldCBzbV83NQouYWRkcmVzc19zaXplIDY0CgoudmlzaWJs
>> "%TMPB%" echo ZSAuZW50cnkgZnAzMl9wZWFrKAogICAgLnBhcmFtIC51NjQgcF9vdXQsCiAgICAucGFyYW0gLnUz
>> "%TMPB%" echo MiBwX2l0ZXJzCikKewogICAgLnJlZyAucHJlZCAlcDE7CiAgICAucmVnIC5iMzIgJXIxLCAlcjIs
>> "%TMPB%" echo ICVyMywgJXI0OwogICAgLnJlZyAuYjY0ICVyZDEsICVyZDI7CiAgICAucmVnIC5mMzIgJWYxLCAl
>> "%TMPB%" echo ZjIsICVmMywgJWY0LCAlZjUsICVmNiwgJWY3LCAlZjgsICVmOSwgJWYxMDsKCiAgICBsZC5wYXJh
>> "%TMPB%" echo bS51NjQgJXJkMSwgW3Bfb3V0XTsKICAgIGxkLnBhcmFtLnUzMiAlcjEsIFtwX2l0ZXJzXTsKICAg
>> "%TMPB%" echo IGN2dGEudG8uZ2xvYmFsLnU2NCAlcmQyLCAlcmQxOwogICAgbW92LnUzMiAlcjIsICV0aWQueDsK
>> "%TMPB%" echo ICAgIG1vdi51MzIgJXIzLCAlY3RhaWQueDsKICAgIG1vdi51MzIgJXI0LCAlbnRpZC54OwogICAg
>> "%TMPB%" echo bWFkLmxvLnMzMiAlcjIsICVyMywgJXI0LCAlcjI7CiAgICBjdnQucm4uZjMyLnUzMiAlZjEsICVy
>> "%TMPB%" echo MjsKICAgIG1vdi5mMzIgJWYyLCAwZjNGODAwMDAwOwogICAgbW92LmYzMiAlZjMsIDBmM0YwMDAw
>> "%TMPB%" echo MDA7CiAgICBtb3YuZjMyICVmNCwgJWYxOwogICAgbW92LmYzMiAlZjUsICVmMTsKICAgIG1vdi5m
>> "%TMPB%" echo MzIgJWY2LCAlZjE7CiAgICBtb3YuZjMyICVmNywgJWYxOwogICAgbW92LmYzMiAlZjgsICVmMTsK
>> "%TMPB%" echo ICAgIG1vdi5mMzIgJWY5LCAlZjE7CiAgICBtb3YuZjMyICVmMTAsICVmMTsKCiRMX2xvb3A6CiAg
>> "%TMPB%" echo ICBmbWEucm4uZjMyICVmMSwgJWYxLCAlZjIsICVmMzsKICAgIGZtYS5ybi5mMzIgJWY0LCAlZjQs
>> "%TMPB%" echo ICVmMiwgJWYzOwogICAgZm1hLnJuLmYzMiAlZjUsICVmNSwgJWYyLCAlZjM7CiAgICBmbWEucm4u
>> "%TMPB%" echo ZjMyICVmNiwgJWY2LCAlZjIsICVmMzsKICAgIGZtYS5ybi5mMzIgJWY3LCAlZjcsICVmMiwgJWYz
>> "%TMPB%" echo OwogICAgZm1hLnJuLmYzMiAlZjgsICVmOCwgJWYyLCAlZjM7CiAgICBmbWEucm4uZjMyICVmOSwg
>> "%TMPB%" echo JWY5LCAlZjIsICVmMzsKICAgIGZtYS5ybi5mMzIgJWYxMCwgJWYxMCwgJWYyLCAlZjM7CiAgICBz
>> "%TMPB%" echo dWIuczMyICVyMSwgJXIxLCAxOwogICAgc2V0cC5uZS5zMzIgJXAxLCAlcjEsIDA7CiAgICBAJXAx
>> "%TMPB%" echo IGJyYSAkTF9sb29wOwoKICAgIGFkZC5mMzIgJWYxLCAlZjEsICVmNDsKICAgIGFkZC5mMzIgJWY1
>> "%TMPB%" echo LCAlZjUsICVmNjsKICAgIGFkZC5mMzIgJWY3LCAlZjcsICVmODsKICAgIGFkZC5mMzIgJWY5LCAl
>> "%TMPB%" echo ZjksICVmMTA7CiAgICBhZGQuZjMyICVmMSwgJWYxLCAlZjU7CiAgICBhZGQuZjMyICVmNywgJWY3
>> "%TMPB%" echo LCAlZjk7CiAgICBhZGQuZjMyICVmMSwgJWYxLCAlZjc7CiAgICBzdC5nbG9iYWwuZjMyIFslcmQy
>> "%TMPB%" echo XSwgJWYxOwogICAgcmV0Owp9CiI7CiAgICBzdGF0aWMgc3RyaW5nIFBUWF9GUDE2ID0gQCIKLnZl
>> "%TMPB%" echo cnNpb24gNy4wCi50YXJnZXQgc21fNzUKLmFkZHJlc3Nfc2l6ZSA2NAoKLnZpc2libGUgLmVudHJ5
>> "%TMPB%" echo IGZwMTZfcGVhaygKICAgIC5wYXJhbSAudTY0IHBfb3V0LAogICAgLnBhcmFtIC51MzIgcF9pdGVy
>> "%TMPB%" echo cwopCnsKICAgIC5yZWcgLnByZWQgJXAxOwogICAgLnJlZyAuYjMyICVyMSwgJXIyLCAlcjMsICVy
>> "%TMPB%" echo NDsKICAgIC5yZWcgLmIzMiAlYTEsICVhMiwgJWEzLCAlYTQsICVhNSwgJWE2LCAlYTcsICVhODsK
>> "%TMPB%" echo ICAgIC5yZWcgLmI2NCAlcmQxLCAlcmQyOwoKICAgIGxkLnBhcmFtLnU2NCAlcmQxLCBbcF9vdXRd
>> "%TMPB%" echo OwogICAgbGQucGFyYW0udTMyICVyMSwgW3BfaXRlcnNdOwogICAgY3Z0YS50by5nbG9iYWwudTY0
>> "%TMPB%" echo ICVyZDIsICVyZDE7CiAgICBtb3YudTMyICVyMiwgJXRpZC54OwogICAgbW92LmIzMiAlcjMsIDB4
>> "%TMPB%" echo M0MwMDNDMDA7CiAgICBtb3YuYjMyICVyNCwgMHgzQzAwM0MwMDsKICAgIG1vdi5iMzIgJWExLCAl
>> "%TMPB%" echo cjI7CiAgICBtb3YuYjMyICVhMiwgJXIyOwogICAgbW92LmIzMiAlYTMsICVyMjsKICAgIG1vdi5i
>> "%TMPB%" echo MzIgJWE0LCAlcjI7CiAgICBtb3YuYjMyICVhNSwgJXIyOwogICAgbW92LmIzMiAlYTYsICVyMjsK
>> "%TMPB%" echo ICAgIG1vdi5iMzIgJWE3LCAlcjI7CiAgICBtb3YuYjMyICVhOCwgJXIyOwoKJExfbG9vcDoKICAg
>> "%TMPB%" echo IGZtYS5ybi5mMTZ4MiAlYTEsICVhMSwgJXIzLCAlcjQ7CiAgICBmbWEucm4uZjE2eDIgJWEyLCAl
>> "%TMPB%" echo YTIsICVyMywgJXI0OwogICAgZm1hLnJuLmYxNngyICVhMywgJWEzLCAlcjMsICVyNDsKICAgIGZt
>> "%TMPB%" echo YS5ybi5mMTZ4MiAlYTQsICVhNCwgJXIzLCAlcjQ7CiAgICBmbWEucm4uZjE2eDIgJWE1LCAlYTUs
>> "%TMPB%" echo ICVyMywgJXI0OwogICAgZm1hLnJuLmYxNngyICVhNiwgJWE2LCAlcjMsICVyNDsKICAgIGZtYS5y
>> "%TMPB%" echo bi5mMTZ4MiAlYTcsICVhNywgJXIzLCAlcjQ7CiAgICBmbWEucm4uZjE2eDIgJWE4LCAlYTgsICVy
>> "%TMPB%" echo MywgJXI0OwogICAgc3ViLnMzMiAlcjEsICVyMSwgMTsKICAgIHNldHAubmUuczMyICVwMSwgJXIx
>> "%TMPB%" echo LCAwOwogICAgQCVwMSBicmEgJExfbG9vcDsKCiAgICB4b3IuYjMyICVhMSwgJWExLCAlYTI7CiAg
>> "%TMPB%" echo ICB4b3IuYjMyICVhMywgJWEzLCAlYTQ7CiAgICB4b3IuYjMyICVhNSwgJWE1LCAlYTY7CiAgICB4
>> "%TMPB%" echo b3IuYjMyICVhNywgJWE3LCAlYTg7CiAgICB4b3IuYjMyICVhMSwgJWExLCAlYTM7CiAgICB4b3Iu
>> "%TMPB%" echo YjMyICVhNSwgJWE1LCAlYTc7CiAgICB4b3IuYjMyICVhMSwgJWExLCAlYTU7CiAgICBzdC5nbG9i
>> "%TMPB%" echo YWwuYjMyIFslcmQyXSwgJWExOwogICAgcmV0Owp9CiI7CiAgICBzdGF0aWMgc3RyaW5nIFBUWF9U
>> "%TMPB%" echo QyA9IEAiCi52ZXJzaW9uIDcuMAoudGFyZ2V0IHNtXzc1Ci5hZGRyZXNzX3NpemUgNjQKCi52aXNp
>> "%TMPB%" echo YmxlIC5lbnRyeSB0Y19wZWFrKAogICAgLnBhcmFtIC51NjQgcF9vdXQsCiAgICAucGFyYW0gLnUz
>> "%TMPB%" echo MiBwX2l0ZXJzCikKewogICAgLnJlZyAucHJlZCAlcDE7CiAgICAucmVnIC5iMzIgJXIxLCAlcjIs
>> "%TMPB%" echo ICVyMywgJXI0LCAlcjU7CiAgICAucmVnIC5iNjQgJXJkMSwgJXJkMjsKICAgIC5yZWcgLmYzMiAl
>> "%TMPB%" echo ZjEsICVmMiwgJWYzLCAlZjQsICVmNSwgJWY2LCAlZjcsICVmODsKICAgIC5yZWcgLmYzMiAlZjks
>> "%TMPB%" echo ICVmMTAsICVmMTEsICVmMTIsICVmMTMsICVmMTQsICVmMTUsICVmMTY7CgogICAgbGQucGFyYW0u
>> "%TMPB%" echo dTY0ICVyZDEsIFtwX291dF07CiAgICBsZC5wYXJhbS51MzIgJXIxLCBbcF9pdGVyc107CiAgICBj
>> "%TMPB%" echo dnRhLnRvLmdsb2JhbC51NjQgJXJkMiwgJXJkMTsKICAgIG1vdi51MzIgJXIyLCAldGlkLng7CiAg
>> "%TMPB%" echo ICBtb3YuYjMyICVyMywgMHgzQzAwM0MwMDsKICAgIG1vdi5iMzIgJXI0LCAweDNDMDAzQzAwOwog
>> "%TMPB%" echo ICAgbW92LmIzMiAlcjUsIDB4M0MwMDNDMDA7CiAgICBtb3YuZjMyICVmMSwgMGYwMDAwMDAwMDsK
>> "%TMPB%" echo ICAgIG1vdi5mMzIgJWYyLCAwZjAwMDAwMDAwOwogICAgbW92LmYzMiAlZjMsIDBmMDAwMDAwMDA7
>> "%TMPB%" echo CiAgICBtb3YuZjMyICVmNCwgMGYwMDAwMDAwMDsKICAgIG1vdi5mMzIgJWY1LCAwZjAwMDAwMDAw
>> "%TMPB%" echo OwogICAgbW92LmYzMiAlZjYsIDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVmNywgMGYwMDAwMDAw
>> "%TMPB%" echo MDsKICAgIG1vdi5mMzIgJWY4LCAwZjAwMDAwMDAwOwogICAgbW92LmYzMiAlZjksIDBmMDAwMDAw
>> "%TMPB%" echo MDA7CiAgICBtb3YuZjMyICVmMTAsIDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVmMTEsIDBmMDAw
>> "%TMPB%" echo MDAwMDA7CiAgICBtb3YuZjMyICVmMTIsIDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVmMTMsIDBm
>> "%TMPB%" echo MDAwMDAwMDA7CiAgICBtb3YuZjMyICVmMTQsIDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVmMTUs
>> "%TMPB%" echo IDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVmMTYsIDBmMDAwMDAwMDA7CgokTF9sb29wOgogICAg
>> "%TMPB%" echo bW1hLnN5bmMuYWxpZ25lZC5tMTZuOGs4LnJvdy5jb2wuZjMyLmYxNi5mMTYuZjMyIHslZjEsJWYy
>> "%TMPB%" echo LCVmMywlZjR9LCB7JXIzLCVyNH0sIHslcjV9LCB7JWYxLCVmMiwlZjMsJWY0fTsKICAgIG1tYS5z
>> "%TMPB%" echo eW5jLmFsaWduZWQubTE2bjhrOC5yb3cuY29sLmYzMi5mMTYuZjE2LmYzMiB7JWY1LCVmNiwlZjcs
>> "%TMPB%" echo JWY4fSwgeyVyMywlcjR9LCB7JXI1fSwgeyVmNSwlZjYsJWY3LCVmOH07CiAgICBtbWEuc3luYy5h
>> "%TMPB%" echo bGlnbmVkLm0xNm44azgucm93LmNvbC5mMzIuZjE2LmYxNi5mMzIgeyVmOSwlZjEwLCVmMTEsJWYx
>> "%TMPB%" echo Mn0sIHslcjMsJXI0fSwgeyVyNX0sIHslZjksJWYxMCwlZjExLCVmMTJ9OwogICAgbW1hLnN5bmMu
>> "%TMPB%" echo YWxpZ25lZC5tMTZuOGs4LnJvdy5jb2wuZjMyLmYxNi5mMTYuZjMyIHslZjEzLCVmMTQsJWYxNSwl
>> "%TMPB%" echo ZjE2fSwgeyVyMywlcjR9LCB7JXI1fSwgeyVmMTMsJWYxNCwlZjE1LCVmMTZ9OwogICAgc3ViLnMz
>> "%TMPB%" echo MiAlcjEsICVyMSwgMTsKICAgIHNldHAubmUuczMyICVwMSwgJXIxLCAwOwogICAgQCVwMSBicmEg
>> "%TMPB%" echo JExfbG9vcDsKCiAgICBhZGQuZjMyICVmMSwgJWYxLCAlZjU7CiAgICBhZGQuZjMyICVmMiwgJWYy
>> "%TMPB%" echo LCAlZjY7CiAgICBhZGQuZjMyICVmMywgJWYzLCAlZjc7CiAgICBhZGQuZjMyICVmNCwgJWY0LCAl
>> "%TMPB%" echo Zjg7CiAgICBhZGQuZjMyICVmMSwgJWYxLCAlZjk7CiAgICBhZGQuZjMyICVmMiwgJWYyLCAlZjEw
>> "%TMPB%" echo OwogICAgYWRkLmYzMiAlZjMsICVmMywgJWYxMTsKICAgIGFkZC5mMzIgJWY0LCAlZjQsICVmMTI7
>> "%TMPB%" echo CiAgICBhZGQuZjMyICVmMSwgJWYxLCAlZjEzOwogICAgYWRkLmYzMiAlZjIsICVmMiwgJWYxNDsK
>> "%TMPB%" echo ICAgIGFkZC5mMzIgJWYzLCAlZjMsICVmMTU7CiAgICBhZGQuZjMyICVmNCwgJWY0LCAlZjE2Owog
>> "%TMPB%" echo ICAgc3QuZ2xvYmFsLmYzMiBbJXJkMl0sICVmMTsKICAgIHJldDsKfQoiOwoKICAgIHN0YXRpYyB2
>> "%TMPB%" echo b2lkIEZhaWwoc3RyaW5nIG1zZykKICAgIHsKICAgICAgICBDb25zb2xlLldyaXRlTGluZSgiRVJS
>> "%TMPB%" echo T1IgIiArIG1zZyk7CiAgICAgICAgRW52aXJvbm1lbnQuRXhpdCgxKTsKICAgIH0KCiAgICBzdGF0
>> "%TMPB%" echo aWMgSW50UHRyIEdldEtlcm5lbChzdHJpbmcgbmFtZSwgc3RyaW5nIHB0eCkKICAgIHsKICAgICAg
>> "%TMPB%" echo ICBieXRlW10gaW1nID0gRW5jb2RpbmcuQVNDSUkuR2V0Qnl0ZXMocHR4ICsgIlwwIik7CiAgICAg
>> "%TMPB%" echo ICAgSW50UHRyIGJ1ZiA9IE1hcnNoYWwuQWxsb2NIR2xvYmFsKGltZy5MZW5ndGgpOwogICAgICAg
>> "%TMPB%" echo IE1hcnNoYWwuQ29weShpbWcsIDAsIGJ1ZiwgaW1nLkxlbmd0aCk7CiAgICAgICAgSW50UHRyIG1v
>> "%TMPB%" echo ZDsKICAgICAgICBpZiAoY3VNb2R1bGVMb2FkRGF0YShvdXQgbW9kLCBidWYpICE9IDApIHJldHVy
>> "%TMPB%" echo biBJbnRQdHIuWmVybzsKICAgICAgICBJbnRQdHIgZm47CiAgICAgICAgaWYgKGN1TW9kdWxlR2V0
>> "%TMPB%" echo RnVuY3Rpb24ob3V0IGZuLCBtb2QsIG5hbWUpICE9IDApIHJldHVybiBJbnRQdHIuWmVybzsKICAg
>> "%TMPB%" echo ICAgICByZXR1cm4gZm47CiAgICB9CgogICAgc3RhdGljIGRvdWJsZSBCZW5jaChJbnRQdHIgZm4s
>> "%TMPB%" echo IHVpbnQgZ3JpZCwgdWludCBibG9jaywgdWludCBpdGVycywgZG91YmxlIGZsb3BpKQogICAgewog
>> "%TMPB%" echo ICAgICAgIGlmIChmbiA9PSBJbnRQdHIuWmVybykgcmV0dXJuIDAuMDsKICAgICAgICBJbnRQdHIg
>> "%TMPB%" echo b3V0cDsKICAgICAgICBpZiAoY3VNZW1BbGxvY192MihvdXQgb3V0cCwgKFVJbnRQdHIpKHVsb25n
>> "%TMPB%" echo KTQpICE9IDApIHJldHVybiAwLjA7CiAgICAgICAgSW50UHRyIGFPdXQgPSBNYXJzaGFsLkFsbG9j
>> "%TMPB%" echo SEdsb2JhbChJbnRQdHIuU2l6ZSk7CiAgICAgICAgSW50UHRyIGFJdCA9IE1hcnNoYWwuQWxsb2NI
>> "%TMPB%" echo R2xvYmFsKDQpOwogICAgICAgIE1hcnNoYWwuV3JpdGVJbnRQdHIoYU91dCwgb3V0cCk7CiAgICAg
>> "%TMPB%" echo ICAgTWFyc2hhbC5Xcml0ZUludDMyKGFJdCwgKGludClpdGVycyk7CiAgICAgICAgSW50UHRyIGFy
>> "%TMPB%" echo Z3MgPSBNYXJzaGFsLkFsbG9jSEdsb2JhbCgyICogSW50UHRyLlNpemUpOwogICAgICAgIE1hcnNo
>> "%TMPB%" echo YWwuV3JpdGVJbnRQdHIoYXJncywgMCwgYU91dCk7CiAgICAgICAgTWFyc2hhbC5Xcml0ZUludFB0
>> "%TMPB%" echo cihhcmdzLCBJbnRQdHIuU2l6ZSwgYUl0KTsKICAgICAgICBpZiAoY3VMYXVuY2hLZXJuZWwoZm4s
>> "%TMPB%" echo IGdyaWQsIDEsIDEsIGJsb2NrLCAxLCAxLCAwLCBJbnRQdHIuWmVybywgYXJncywgSW50UHRyLlpl
>> "%TMPB%" echo cm8pICE9IDApIHJldHVybiAwLjA7CiAgICAgICAgaWYgKGN1Q3R4U3luY2hyb25pemUoKSAhPSAw
>> "%TMPB%" echo KSByZXR1cm4gMC4wOwogICAgICAgIGRvdWJsZSBiZXN0ID0gMC4wOwogICAgICAgIGZvciAoaW50
>> "%TMPB%" echo IGkgPSAwOyBpIDwgMjsgaSsrKQogICAgICAgIHsKICAgICAgICAgICAgaWYgKGN1TGF1bmNoS2Vy
>> "%TMPB%" echo bmVsKGZuLCBncmlkLCAxLCAxLCBibG9jaywgMSwgMSwgMCwgSW50UHRyLlplcm8sIGFyZ3MsIElu
>> "%TMPB%" echo dFB0ci5aZXJvKSAhPSAwKSBicmVhazsKICAgICAgICAgICAgU3RvcHdhdGNoIHN3ID0gU3RvcHdh
>> "%TMPB%" echo dGNoLlN0YXJ0TmV3KCk7CiAgICAgICAgICAgIGlmIChjdUN0eFN5bmNocm9uaXplKCkgIT0gMCkg
>> "%TMPB%" echo YnJlYWs7CiAgICAgICAgICAgIHN3LlN0b3AoKTsKICAgICAgICAgICAgZG91YmxlIGR0ID0gc3cu
>> "%TMPB%" echo RWxhcHNlZC5Ub3RhbFNlY29uZHM7CiAgICAgICAgICAgIGlmIChkdCA+IDApCiAgICAgICAgICAg
>> "%TMPB%" echo IHsKICAgICAgICAgICAgICAgIGRvdWJsZSB2ID0gKGRvdWJsZSlncmlkICogKGRvdWJsZSlibG9j
>> "%TMPB%" echo ayAqIChkb3VibGUpaXRlcnMgKiBmbG9waSAvIGR0IC8gMWUxMjsKICAgICAgICAgICAgICAgIGlm
>> "%TMPB%" echo ICh2ID4gYmVzdCkgYmVzdCA9IHY7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgcmV0
>> "%TMPB%" echo dXJuIGJlc3Q7CiAgICB9CgogICAgc3RhdGljIGRvdWJsZSBYZmVyKGJvb2wgdG9EZXYpCiAgICB7
>> "%TMPB%" echo CiAgICAgICAgaWYgKHRvRGV2KSBjdU1lbWNweUh0b0RfdjIoZHB0ciwgaHB0ciwgKFVJbnRQdHIp
>> "%TMPB%" echo KHVsb25nKVNJWkUpOwogICAgICAgIGVsc2UgY3VNZW1jcHlEdG9IX3YyKGhwdHIsIGRwdHIsIChV
>> "%TMPB%" echo SW50UHRyKSh1bG9uZylTSVpFKTsKICAgICAgICBTdG9wd2F0Y2ggc3cgPSBTdG9wd2F0Y2guU3Rh
>> "%TMPB%" echo cnROZXcoKTsKICAgICAgICBmb3IgKGludCBpID0gMDsgaSA8IFJFUFM7IGkrKykKICAgICAgICB7
>> "%TMPB%" echo CiAgICAgICAgICAgIGlmICh0b0RldikgY3VNZW1jcHlIdG9EX3YyKGRwdHIsIGhwdHIsIChVSW50
>> "%TMPB%" echo UHRyKSh1bG9uZylTSVpFKTsKICAgICAgICAgICAgZWxzZSBjdU1lbWNweUR0b0hfdjIoaHB0ciwg
>> "%TMPB%" echo ZHB0ciwgKFVJbnRQdHIpKHVsb25nKVNJWkUpOwogICAgICAgIH0KICAgICAgICBjdUN0eFN5bmNo
>> "%TMPB%" echo cm9uaXplKCk7CiAgICAgICAgc3cuU3RvcCgpOwogICAgICAgIGRvdWJsZSBkdCA9IHN3LkVsYXBz
>> "%TMPB%" echo ZWQuVG90YWxTZWNvbmRzOwogICAgICAgIHJldHVybiBkdCA8PSAwID8gMC4wIDogUkVQUyAqIFNJ
>> "%TMPB%" echo WkUgLyBkdCAvIDFlOTsKICAgIH0KCiAgICBzdGF0aWMgdm9pZCBNYWluKCkKICAgIHsKICAgICAg
>> "%TMPB%" echo ICBpZiAoY3VJbml0KDApICE9IDApIEZhaWwoImN1SW5pdCBmYWlsZWQiKTsKICAgICAgICBpbnQg
>> "%TMPB%" echo ZGV2OwogICAgICAgIGlmIChjdURldmljZUdldChvdXQgZGV2LCAwKSAhPSAwKSBGYWlsKCJjdURl
>> "%TMPB%" echo dmljZUdldCBmYWlsZWQiKTsKICAgICAgICBpbnQgc20gPSAwOwogICAgICAgIGN1RGV2aWNlR2V0
>> "%TMPB%" echo QXR0cmlidXRlKG91dCBzbSwgMTYsIGRldik7CiAgICAgICAgSW50UHRyIGN0eDsKICAgICAgICBp
>> "%TMPB%" echo ZiAoY3VDdHhDcmVhdGVfdjIob3V0IGN0eCwgMCwgZGV2KSAhPSAwKSBGYWlsKCJjdUN0eENyZWF0
>> "%TMPB%" echo ZSBmYWlsZWQiKTsKCiAgICAgICAgaWYgKGN1TWVtQWxsb2NfdjIob3V0IGRwdHIsIChVSW50UHRy
>> "%TMPB%" echo KSh1bG9uZylTSVpFKSAhPSAwKSBGYWlsKCJjdU1lbUFsbG9jIGZhaWxlZCIpOwogICAgICAgIGlm
>> "%TMPB%" echo IChjdU1lbUhvc3RBbGxvYyhvdXQgaHB0ciwgKFVJbnRQdHIpKHVsb25nKVNJWkUsIDUpICE9IDAp
>> "%TMPB%" echo CiAgICAgICAgICAgIGlmIChjdU1lbUhvc3RBbGxvYyhvdXQgaHB0ciwgKFVJbnRQdHIpKHVsb25n
>> "%TMPB%" echo KVNJWkUsIDEpICE9IDApIEZhaWwoImN1TWVtSG9zdEFsbG9jIGZhaWxlZCIpOwoKICAgICAgICBk
>> "%TMPB%" echo b3VibGUgaGJ3ID0gMC4wOwogICAgICAgIGRvdWJsZSBkYncgPSAwLjA7CiAgICAgICAgZm9yIChp
>> "%TMPB%" echo bnQgcGFzcyA9IDA7IHBhc3MgPCAyOyBwYXNzKyspCiAgICAgICAgewogICAgICAgICAgICBkb3Vi
>> "%TMPB%" echo bGUgaCA9IFhmZXIodHJ1ZSk7CiAgICAgICAgICAgIGRvdWJsZSBkID0gWGZlcihmYWxzZSk7CiAg
>> "%TMPB%" echo ICAgICAgICAgIGlmIChoID4gaGJ3KSBoYncgPSBoOwogICAgICAgICAgICBpZiAoZCA+IGRidykg
>> "%TMPB%" echo ZGJ3ID0gZDsKICAgICAgICB9CgogICAgICAgIC8vIFNhbXBsaW5nIG5vdGU6IHRoZSBwZWFrIG9m
>> "%TMPB%" echo IHR3byBwYXNzZXMgaXMga2VwdCBmb3IgZXZlcnkgZmlndXJlIGJlbG93LCBiZWNhdXNlIGEKICAg
>> "%TMPB%" echo ICAgICAvLyAgIHNpbmdsZSBwYXNzIGNhbiBkaXAgKGJ1c3kgb3IgcG93ZXItc2F2ZWQgR1BVLCBh
>> "%TMPB%" echo bm90aGVyIENVREEgY2xpZW50KSBhbmQgd291bGQgdGhlbgogICAgICAgIC8vICAgdHJpcCBhIGJh
>> "%TMPB%" echo c2VsaW5lIG9uIGEgcGVyZmVjdGx5IGhlYWx0aHkgY2FyZC4KICAgICAgICBJbnRQdHIgYnB0cjsK
>> "%TMPB%" echo ICAgICAgICBkb3VibGUgdnJhbSA9IDAuMDsKICAgICAgICBpZiAoY3VNZW1BbGxvY192MihvdXQg
>> "%TMPB%" echo YnB0ciwgKFVJbnRQdHIpKHVsb25nKVNJWkUpID09IDApCiAgICAgICAgewogICAgICAgICAgICBj
>> "%TMPB%" echo dU1lbWNweUR0b0RfdjIoYnB0ciwgZHB0ciwgKFVJbnRQdHIpKHVsb25nKVNJWkUpOwogICAgICAg
>> "%TMPB%" echo ICAgICBmb3IgKGludCBwYXNzID0gMDsgcGFzcyA8IDI7IHBhc3MrKykKICAgICAgICAgICAgewog
>> "%TMPB%" echo ICAgICAgICAgICAgICAgU3RvcHdhdGNoIHN3ID0gU3RvcHdhdGNoLlN0YXJ0TmV3KCk7CiAgICAg
>> "%TMPB%" echo ICAgICAgICAgICBmb3IgKGludCBpID0gMDsgaSA8IERSRVBTOyBpKyspIGN1TWVtY3B5RHRvRF92
>> "%TMPB%" echo MihicHRyLCBkcHRyLCAoVUludFB0cikodWxvbmcpU0laRSk7CiAgICAgICAgICAgICAgICBjdUN0
>> "%TMPB%" echo eFN5bmNocm9uaXplKCk7CiAgICAgICAgICAgICAgICBzdy5TdG9wKCk7CiAgICAgICAgICAgICAg
>> "%TMPB%" echo ICBkb3VibGUgZHQgPSBzdy5FbGFwc2VkLlRvdGFsU2Vjb25kczsKICAgICAgICAgICAgICAgIGRv
>> "%TMPB%" echo dWJsZSB2ID0gZHQgPD0gMCA/IDAuMCA6IERSRVBTICogMi4wICogU0laRSAvIGR0IC8gMWU5Owog
>> "%TMPB%" echo ICAgICAgICAgICAgICAgaWYgKHYgPiB2cmFtKSB2cmFtID0gdjsKICAgICAgICAgICAgfQogICAg
>> "%TMPB%" echo ICAgIH0KCiAgICAgICAgdWludCBHUklEID0gKHVpbnQpKHNtICogOCk7CiAgICAgICAgdWludCBC
>> "%TMPB%" echo TE9DSyA9IDI1NjsKICAgICAgICBkb3VibGUgZnAzMiA9IEJlbmNoKEdldEtlcm5lbCgiZnAzMl9w
>> "%TMPB%" echo ZWFrIiwgUFRYX0ZQMzIpLCBHUklELCBCTE9DSywgNjAwMDAwMCwgMTYuMCk7CiAgICAgICAgZG91
>> "%TMPB%" echo YmxlIGZwMTYgPSBCZW5jaChHZXRLZXJuZWwoImZwMTZfcGVhayIsIFBUWF9GUDE2KSwgR1JJRCwg
>> "%TMPB%" echo QkxPQ0ssIDMwMDAwMDAsIDMyLjApOwogICAgICAgIGRvdWJsZSB0YyA9IEJlbmNoKEdldEtlcm5l
>> "%TMPB%" echo bCgidGNfcGVhayIsIFBUWF9UQyksIEdSSUQsIEJMT0NLLCAyMDAwMDAwLCAyNTYuMCk7CgogICAg
>> "%TMPB%" echo ICAgIEN1bHR1cmVJbmZvIGNpID0gQ3VsdHVyZUluZm8uSW52YXJpYW50Q3VsdHVyZTsKICAgICAg
>> "%TMPB%" echo ICBDb25zb2xlLldyaXRlTGluZSgiU00gIiArIHNtLlRvU3RyaW5nKGNpKSk7CiAgICAgICAgQ29u
>> "%TMPB%" echo c29sZS5Xcml0ZUxpbmUoIkNPUkVTICIgKyAoc20gKiA2NCkuVG9TdHJpbmcoY2kpKTsKICAgICAg
>> "%TMPB%" echo ICBDb25zb2xlLldyaXRlTGluZSgiRlAzMiAiICsgZnAzMi5Ub1N0cmluZygiRjIiLCBjaSkpOwog
>> "%TMPB%" echo ICAgICAgIENvbnNvbGUuV3JpdGVMaW5lKCJGUDMySU5UICIgKyAoKGludCkoZnAzMiAqIDEwMCkp
>> "%TMPB%" echo LlRvU3RyaW5nKGNpKSk7CiAgICAgICAgQ29uc29sZS5Xcml0ZUxpbmUoIkZQMTYgIiArIGZwMTYu
>> "%TMPB%" echo VG9TdHJpbmcoIkYyIiwgY2kpKTsKICAgICAgICBDb25zb2xlLldyaXRlTGluZSgiRlAxNklOVCAi
>> "%TMPB%" echo ICsgKChpbnQpKGZwMTYgKiAxMDApKS5Ub1N0cmluZyhjaSkpOwogICAgICAgIENvbnNvbGUuV3Jp
>> "%TMPB%" echo dGVMaW5lKCJUQyAiICsgdGMuVG9TdHJpbmcoIkYyIiwgY2kpKTsKICAgICAgICBDb25zb2xlLldy
>> "%TMPB%" echo aXRlTGluZSgiVENJTlQgIiArICgoaW50KSh0YyAqIDEwMCkpLlRvU3RyaW5nKGNpKSk7CiAgICAg
>> "%TMPB%" echo ICAgQ29uc29sZS5Xcml0ZUxpbmUoIlZSQU0gIiArIHZyYW0uVG9TdHJpbmcoIkYxIiwgY2kpKTsK
>> "%TMPB%" echo ICAgICAgICBDb25zb2xlLldyaXRlTGluZSgiVlJBTUlOVCAiICsgKChpbnQpdnJhbSkuVG9TdHJp
>> "%TMPB%" echo bmcoY2kpKTsKICAgICAgICBDb25zb2xlLldyaXRlTGluZSgiSDJEICIgKyBoYncuVG9TdHJpbmco
>> "%TMPB%" echo IkYyIiwgY2kpKTsKICAgICAgICBDb25zb2xlLldyaXRlTGluZSgiSDJESU5UICIgKyAoKGludCko
>> "%TMPB%" echo aGJ3ICogMTAwKSkuVG9TdHJpbmcoY2kpKTsKICAgICAgICBDb25zb2xlLldyaXRlTGluZSgiRDJI
>> "%TMPB%" echo ICIgKyBkYncuVG9TdHJpbmcoIkYyIiwgY2kpKTsKICAgICAgICAvLyBUaHJlc2hvbGQgdW5jaGFu
>> "%TMPB%" echo Z2VkICg0LjUgR0IvcykgYnV0IHRha2VuIGZyb20gdGhlIGJldHRlciBvZiB0aGUgdHdvIGRpcmVj
>> "%TMPB%" echo dGlvbnM6CiAgICAgICAgLy8gICBhIHNpbmdsZSBIMkQgc2FtcGxlIG9uIGEgaGVhbHRoeSBHZW4y
>> "%TMPB%" echo IGxpbmsgY2FuIGRpcCBjbG9zZSB0byB0aGUgdGhyZXNob2xkLgogICAgICAgIENvbnNvbGUuV3Jp
>> "%TMPB%" echo dGVMaW5lKCJWRVJESUNUICIgKyAoTWF0aC5NYXgoaGJ3LCBkYncpID49IDQuNSA/ICJHRU4yIiA6
>> "%TMPB%" echo ICJHRU4xIikpOwogICAgfQp9Cg==
if exist "%TMPCS%" del "%TMPCS%" >nul 2>&1
if exist "%TMPO%" del "%TMPO%" >nul 2>&1
if exist "%TMPE%" del "%TMPE%" >nul 2>&1
if exist "%TMPC%" del "%TMPC%" >nul 2>&1
rem 2026-10-04: 实测不再依赖 Python —— 改用 Windows 自带的 .NET 编译器 csc.exe 现场编译内置 C# 小程序,
rem   它直接调 nvcuda.dll 做同样的 CUDA 实测: 带宽 H2D/D2H 判 Gen2, 算力 FP32/FP16/张量 判核心是否被砍,
rem   输出的键名与旧版 Python 完全一致, 下面的解析与结论逻辑一行没改。
rem 2026-10-04 第三方审查 H1: 程序"起来了但一行读数都没有" - 被安全软件拦下、显存分配失败、驱动异常等 -
rem   以前会一路落到"结论: 存在异常", 让客户以为显卡坏了。这里显式区分:
rem   有 ERROR 行 = 程序真的跑了并自报失败, 属真异常, 保留原判定;
rem   一行预期读数都没有 = 环境性失败, 与编译失败同样降级为"部分未实测"。
certutil -f -decode "%TMPB%" "%TMPCS%" >nul 2>&1
if not exist "%TMPCS%" goto :buildfail
"%CSC%" /nologo /optimize+ /platform:x64 /out:"%TMPE%" "%TMPCS%" > "%TMPC%" 2>&1
if not exist "%TMPE%" goto :buildfail
rem 空日志先删掉: 失败时就不会打出一个空框 (复检 LOW-1; 空或只剩一个空行都算空)
for %%A in ("%TMPC%") do if not "%%~zA"=="" if %%~zA LSS 3 del "%TMPC%" >nul 2>&1
"%TMPE%" > "%TMPO%" 2>&1
rem 注：2>&1 而不是 2>nul —— 让错误信息留在同一个文件里（下面"原始输出"会回显）。
rem 一行输出都没有 = 被拦/静默失败, 与文件缺失同样按环境性失败处理 (复检 H1/LOW-1)
for %%A in ("%TMPO%") do if not "%%~zA"=="" if %%~zA LSS 3 del "%TMPO%" >nul 2>&1
if not exist "%TMPO%" goto :buildfail
findstr /B /C:"ERROR" "%TMPO%" >nul 2>&1
if not errorlevel 1 goto :bench_ready
rem   判据: SM 与 VERDICT 两条读数都要有才算"真的跑完"(半途被杀软打断只剩部分读数算环境失败, 降级更安全);
rem   若将来要放宽, 把下面两条 findstr 合并成一条即可。
findstr /B /C:"SM " "%TMPO%" >nul 2>&1
if errorlevel 1 goto :buildfail
findstr /B /C:"VERDICT" "%TMPO%" >nul 2>&1
if errorlevel 1 goto :buildfail
:bench_ready
for /f "usebackq tokens=1,2 delims= " %%a in ("%TMPO%") do (
  if /I "%%a"=="H2D" set "H2DT=%%b"
  if /I "%%a"=="D2H" set "D2HT=%%b"
  if /I "%%a"=="VERDICT" set "VERD=%%b"
  if /I "%%a"=="SM" set "SMN=%%b"
  if /I "%%a"=="CORES" set "CORES=%%b"
  if /I "%%a"=="FP32" set "FP32T=%%b"
  if /I "%%a"=="FP32INT" set "FP32I=%%b"
  if /I "%%a"=="FP16" set "FP16T=%%b"
  if /I "%%a"=="FP16INT" set "FP16I=%%b"
  if /I "%%a"=="TC" set "TCT=%%b"
  if /I "%%a"=="TCINT" set "TCI=%%b"
  if /I "%%a"=="VRAM" set "VRAMT=%%b"
  if /I "%%a"=="VRAMINT" set "VRAMI=%%b"
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
rem 2026-10-01b（第三方审查 H17）：实测程序失败时也会建出空的 %TMPO% → 以前直接落到"带宽测试失败"，
rem   真正的根因（nvcuda/驱动的 ERROR 行）从不显示。把原始输出回显出来，别让客户/经销商猜。
if not defined VERD if exist "%TMPO%" (
  echo     ---- 实测程序原始输出（定位根因用）----
  type "%TMPO%"
  echo     --------------------------------------
)
echo.

echo [4/6] 算力验证   (满血规格: 34 SM / 2176 CUDA 核心 / TC 未砍)
if not defined SMN set "SMN=0"
if not defined CORES set "CORES=0"
if not defined FP32I set "FP32I=0"
if not defined FP16I set "FP16I=0"
if not defined TCI set "TCI=0"
if not defined VRAMI set "VRAMI=0"
if not defined FP32T set "FP32T=失败"
if not defined FP16T set "FP16T=失败"
if not defined TCT set "TCT=失败"
if not defined VRAMT set "VRAMT=失败"
echo     SM 单元   : %SMN% 个   (CUDA 核心 %CORES%)
echo     FP32 算力 : %FP32T% TFLOPS    (判据下限 7.0 / 参考满血 8.3-8.4)
echo     FP16 算力 : %FP16T% TFLOPS    (判据下限 13.0 / 参考满血 ~16)
echo     FP16 张量 : %TCT% TFLOPS     (判据下限 40 / 参考满血 51+, TC 未砍)
echo     显存带宽  : %VRAMT% GB/s      (判据下限 330 / 参考满血 ~400)
if %SMN% GEQ 34 if %FP32I% GEQ 700 if %FP16I% GEQ 1300 if %TCI% GEQ 4000 if %VRAMI% GEQ 330 set "OKPOWER=1"
if "%OKPOWER%"=="1" echo     [OK] 核心未砍, 算力满血
if "%OKPOWER%"=="0" echo     [!!] 算力/显存低于判据下限, 可能被砍核心/降频/TC 被关
echo.
goto :gen2info

:nosmi
echo [1/6] 显卡与驱动
echo     [!!] nvidia-smi 无输出, 驱动可能异常
echo.
goto :summary

:nocompiler
set "NOCSC=1"
echo     [跳过] 本机没有可用的 .NET 编译器 csc.exe, 算力/带宽实测做不了
echo            ^(这不是显卡故障^) Windows 10/11 自带该组件, 精简系统或安全软件可能删掉它;
echo            想实测可用 工具-测试与修复\ 下的检测, 或手工跑厂商包里的 OpenCL.exe
echo            Gen2 是否落地请看下面 [5/6] 里有没有 "PASS: Gen2 reached on the new path"
echo.
goto :gen2info

:buildfail
set "NOCSC=1"
echo     [跳过] 内置实测程序没能跑起来 ^(解压/编译/运行失败^), 算力/带宽实测做不了
echo            ^(这不是显卡故障^) 多为安全软件拦截 %TEMP% 下的现场编译与运行;
echo            把 %TEMP% 加入杀软信任区后重跑即可, 不必重装本工具
rem 2026-10-04 复检 LOW-1: 失败可能发生在解压/编译/运行三段中的任何一段, 两段日志各自成框, 不出现空框。
if exist "%TMPC%" (
  echo     ---- 编译器输出 ----
  type "%TMPC%"
)
if exist "%TMPO%" (
  echo     ---- 运行输出 ----
  type "%TMPO%"
)
if not exist "%TMPC%" if not exist "%TMPO%" echo     ^(没留下错误信息: 多半是被安全软件静默拦下^)
echo     --------------------------
echo.
goto :gen2info

:gen2info
echo [5/6] 开机自动重训任务 (CMP40HXGen2)
if exist "%LOGP%" (
  powershell -NoProfile -Command "Select-String -Path '%LOGP%' -Pattern 'PostBind start','PostBind EXIT','PASS:','FAIL:' -Encoding Default | Select-Object -Last 3 | ForEach-Object { $_.Line }"
) else (
  echo     [--] 未找到日志 %LOGP%
)
echo.

echo [6/6] 解锁工具状态文件
set "NPASS="
if exist "%LOGP%" (
  findstr /C:"PASS: Gen2 reached on the new path" "%LOGP%" >nul 2>&1
  if not errorlevel 1 set "NPASS=1"
)
rem 2026-10-01b（审查 H17）：原来两行分开写，日志不存在时 errorlevel 沿用上一条命令（echo→0）
rem   → 会被误判成"厂商工具报过 PASS"。包进 if exist 块后就不会了。
if exist "%STAT%" (
  powershell -NoProfile -Command "$c = Get-Content '%STAT%' -Encoding UTF8; Write-Output ('    written: ' + (Get-Item '%STAT%').LastWriteTime); $c -replace ([char]0x2705),'[OK]' -replace ([char]0x274C),'[NG]' -replace ([char]0x2713),'v' -replace ([char]0x26A0),'!' -replace ([char]0xFE0F),''"
) else (
  echo     [--] 未找到 %STAT%
)
if defined NPASS (
  echo.
  echo     [说明] 上面这份是**厂商工具**的状态文件; 本包走新路径 ^(ECAM+inpoutx64, 不需要 ThrottleStop^),
  echo            它报"ThrottleStop 驱动未运行"属正常现象, 请以 [5/6] 的 PASS 为准
)
echo.

:summary
echo ============================================================
if defined NOCSC if "%OKMODE%"=="1" (
  echo   结论: 正常 ^(部分未实测^) -- WDDM 正常; 算力/带宽因本机无法编译实测程序未实测
  echo     - Gen2 以 [5/6] 的 "PASS: Gen2 reached on the new path" 为准
  echo ============================================================
  goto :selfcheck_end
)
rem 2026-10-04 实测: 算力/显存读数随 GPU 当时负载与时钟波动 - 同一张好卡空闲时 32C/1650MHz 测到 FP32 8.4,
rem   连续压测后 56C/1470MHz 只有 7.9; 显存带宽单次采样还曾低到 282 GB/s, 空闲复测 358-400。
rem   所以只有"性能类"读数不达标时结论写"需复核"而不是"存在异常", 免得客户以为解锁失败/硬件坏了。
rem   这里用顺序判断而不是 if/else 块, 免得踩块内 %VAR% 提前展开的坑。
set "SUMV=存在异常"
if "%OKMODE%%OKLINK%%OKPOWER%"=="111" set "SUMV=全绿 -- WDDM + PCIe Gen2 + 算力满血, 解锁正常"
if "%OKMODE%%OKLINK%"=="11" if "%OKPOWER%"=="0" if not defined NOCSC set "SUMV=需复核 -- WDDM 正常 + PCIe Gen2 已解锁, 但算力/显存读数低于判据下限"
echo   结论: %SUMV%
if "%OKMODE%%OKLINK%"=="11" if "%OKPOWER%"=="0" if not defined NOCSC echo     - 先空闲时重跑一次: 关掉占用 GPU 的程序, 等一两分钟再跑本脚本
if "%OKMODE%"=="0" echo     - 驱动模式不是 WDDM: 管理员执行 nvidia-smi -dm 0, 然后重启
if "%OKLINK%"=="0" if not defined NOCSC echo     - PCIe 未达 Gen2: 先重启让开机任务重训; 仍不行检查 ACE-BOOT 是否拦截
if "%OKPOWER%"=="0" if not defined NOCSC echo     - 算力/显存低于判据下限: 检查是否降频/高温, 或驱动未正常加载
echo ============================================================
:selfcheck_end
echo.
echo 按任意键退出...
pause >nul
