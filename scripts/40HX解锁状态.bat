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
set "PY="
if exist "%LOCALAPPDATA%\Programs\Python\Python311\python.exe" set "PY=%LOCALAPPDATA%\Programs\Python\Python311\python.exe"
if not defined PY if exist "C:\Windows\py.exe" set "PY=C:\Windows\py.exe"
if not defined PY for /f "delims=" %%p in ('where python 2^>nul') do if not defined PY set "PY=%%p"
if not defined PY goto :nopython
echo     正在实测链路与算力 (约 15 秒) ...
> "%TMPB%" echo aW1wb3J0IGN0eXBlcywgc3lzLCB0aW1lCgpkZWYgZmFpbChtc2cpOgogICAgcHJpbnQoIkVSUk9S
>> "%TMPB%" echo ICIgKyBtc2cpCiAgICBzeXMuZXhpdCgxKQoKdHJ5OgogICAgY3VkYSA9IGN0eXBlcy5XaW5ETEwo
>> "%TMPB%" echo Im52Y3VkYS5kbGwiKQpleGNlcHQgRXhjZXB0aW9uOgogICAgZmFpbCgibnZjdWRhLmRsbCBub3Qg
>> "%TMPB%" echo Zm91bmQiKQogICAgcmFpc2UgU3lzdGVtRXhpdCgxKQoKZGV2ID0gY3R5cGVzLmNfaW50KDApCmlm
>> "%TMPB%" echo IGN1ZGEuY3VJbml0KDApICE9IDA6CiAgICBmYWlsKCJjdUluaXQgZmFpbGVkIikKaWYgY3VkYS5j
>> "%TMPB%" echo dURldmljZUdldChjdHlwZXMuYnlyZWYoZGV2KSwgMCkgIT0gMDoKICAgIGZhaWwoImN1RGV2aWNl
>> "%TMPB%" echo R2V0IGZhaWxlZCIpCgpzbWNudCA9IGN0eXBlcy5jX2ludCgwKQpjdWRhLmN1RGV2aWNlR2V0QXR0
>> "%TMPB%" echo cmlidXRlKGN0eXBlcy5ieXJlZihzbWNudCksIDE2LCBkZXYpCgpjdHggPSBjdHlwZXMuY192b2lk
>> "%TMPB%" echo X3AoKQppZiBjdWRhLmN1Q3R4Q3JlYXRlX3YyKGN0eXBlcy5ieXJlZihjdHgpLCAwLCBkZXYpICE9
>> "%TMPB%" echo IDA6CiAgICBmYWlsKCJjdUN0eENyZWF0ZSBmYWlsZWQiKQoKU0laRSA9IDUxMiAqIDEwMjQgKiAx
>> "%TMPB%" echo MDI0CmRwdHIgPSBjdHlwZXMuY192b2lkX3AoKQppZiBjdWRhLmN1TWVtQWxsb2NfdjIoY3R5cGVz
>> "%TMPB%" echo LmJ5cmVmKGRwdHIpLCBjdHlwZXMuY19zaXplX3QoU0laRSkpICE9IDA6CiAgICBmYWlsKCJjdU1l
>> "%TMPB%" echo bUFsbG9jIGZhaWxlZCIpCmhwdHIgPSBjdHlwZXMuY192b2lkX3AoKQpyID0gY3VkYS5jdU1lbUhv
>> "%TMPB%" echo c3RBbGxvYyhjdHlwZXMuYnlyZWYoaHB0ciksIGN0eXBlcy5jX3NpemVfdChTSVpFKSwgNSkKaWYg
>> "%TMPB%" echo ciAhPSAwOgogICAgciA9IGN1ZGEuY3VNZW1Ib3N0QWxsb2MoY3R5cGVzLmJ5cmVmKGhwdHIpLCBj
>> "%TMPB%" echo dHlwZXMuY19zaXplX3QoU0laRSksIDEpCmlmIHIgIT0gMDoKICAgIGZhaWwoImN1TWVtSG9zdEFs
>> "%TMPB%" echo bG9jIGZhaWxlZCIpCgpSRVBTID0gMTAKZGVmIHhmZXIoZGlyZWN0aW9uKToKICAgIGlmIGRpcmVj
>> "%TMPB%" echo dGlvbiA9PSAiSDJEIjoKICAgICAgICBmbiwgc3JjLCBkc3QgPSBjdWRhLmN1TWVtY3B5SHRvRF92
>> "%TMPB%" echo MiwgaHB0ciwgZHB0cgogICAgZWxzZToKICAgICAgICBmbiwgc3JjLCBkc3QgPSBjdWRhLmN1TWVt
>> "%TMPB%" echo Y3B5RHRvSF92MiwgZHB0ciwgaHB0cgogICAgZm4oZHN0LCBzcmMsIGN0eXBlcy5jX3NpemVfdChT
>> "%TMPB%" echo SVpFKSkKICAgIHQwID0gdGltZS50aW1lKCkKICAgIGZvciBpIGluIHJhbmdlKFJFUFMpOgogICAg
>> "%TMPB%" echo ICAgIGZuKGRzdCwgc3JjLCBjdHlwZXMuY19zaXplX3QoU0laRSkpCiAgICBjdWRhLmN1Q3R4U3lu
>> "%TMPB%" echo Y2hyb25pemUoKQogICAgZHQgPSB0aW1lLnRpbWUoKSAtIHQwCiAgICByZXR1cm4gMC4wIGlmIGR0
>> "%TMPB%" echo IDw9IDAgZWxzZSBSRVBTICogU0laRSAvIGR0IC8gMWU5CgpoYncgPSB4ZmVyKCJIMkQiKQpkYncg
>> "%TMPB%" echo PSB4ZmVyKCJEMkgiKQoKYnB0ciA9IGN0eXBlcy5jX3ZvaWRfcCgpCmN1ZGEuY3VNZW1BbGxvY192
>> "%TMPB%" echo MihjdHlwZXMuYnlyZWYoYnB0ciksIGN0eXBlcy5jX3NpemVfdChTSVpFKSkKY3VkYS5jdU1lbWNw
>> "%TMPB%" echo eUR0b0RfdjIoYnB0ciwgZHB0ciwgY3R5cGVzLmNfc2l6ZV90KFNJWkUpKQpEUkVQUyA9IDUwCnQw
>> "%TMPB%" echo ID0gdGltZS50aW1lKCkKZm9yIGkgaW4gcmFuZ2UoRFJFUFMpOgogICAgY3VkYS5jdU1lbWNweUR0
>> "%TMPB%" echo b0RfdjIoYnB0ciwgZHB0ciwgY3R5cGVzLmNfc2l6ZV90KFNJWkUpKQpjdWRhLmN1Q3R4U3luY2hy
>> "%TMPB%" echo b25pemUoKQpkdCA9IHRpbWUudGltZSgpIC0gdDAKdnJhbSA9IDAuMCBpZiBkdCA8PSAwIGVsc2Ug
>> "%TMPB%" echo RFJFUFMgKiAyICogU0laRSAvIGR0IC8gMWU5CgpQVFhfRlAzMiA9IGIiIiIKLnZlcnNpb24gNy4w
>> "%TMPB%" echo Ci50YXJnZXQgc21fNzUKLmFkZHJlc3Nfc2l6ZSA2NAoKLnZpc2libGUgLmVudHJ5IGZwMzJfcGVh
>> "%TMPB%" echo aygKICAgIC5wYXJhbSAudTY0IHBfb3V0LAogICAgLnBhcmFtIC51MzIgcF9pdGVycwopCnsKICAg
>> "%TMPB%" echo IC5yZWcgLnByZWQgJXAxOwogICAgLnJlZyAuYjMyICVyMSwgJXIyLCAlcjMsICVyNDsKICAgIC5y
>> "%TMPB%" echo ZWcgLmI2NCAlcmQxLCAlcmQyOwogICAgLnJlZyAuZjMyICVmMSwgJWYyLCAlZjMsICVmNCwgJWY1
>> "%TMPB%" echo LCAlZjYsICVmNywgJWY4LCAlZjksICVmMTA7CgogICAgbGQucGFyYW0udTY0ICVyZDEsIFtwX291
>> "%TMPB%" echo dF07CiAgICBsZC5wYXJhbS51MzIgJXIxLCBbcF9pdGVyc107CiAgICBjdnRhLnRvLmdsb2JhbC51
>> "%TMPB%" echo NjQgJXJkMiwgJXJkMTsKICAgIG1vdi51MzIgJXIyLCAldGlkLng7CiAgICBtb3YudTMyICVyMywg
>> "%TMPB%" echo JWN0YWlkLng7CiAgICBtb3YudTMyICVyNCwgJW50aWQueDsKICAgIG1hZC5sby5zMzIgJXIyLCAl
>> "%TMPB%" echo cjMsICVyNCwgJXIyOwogICAgY3Z0LnJuLmYzMi51MzIgJWYxLCAlcjI7CiAgICBtb3YuZjMyICVm
>> "%TMPB%" echo MiwgMGYzRjgwMDAwMDsKICAgIG1vdi5mMzIgJWYzLCAwZjNGMDAwMDAwOwogICAgbW92LmYzMiAl
>> "%TMPB%" echo ZjQsICVmMTsKICAgIG1vdi5mMzIgJWY1LCAlZjE7CiAgICBtb3YuZjMyICVmNiwgJWYxOwogICAg
>> "%TMPB%" echo bW92LmYzMiAlZjcsICVmMTsKICAgIG1vdi5mMzIgJWY4LCAlZjE7CiAgICBtb3YuZjMyICVmOSwg
>> "%TMPB%" echo JWYxOwogICAgbW92LmYzMiAlZjEwLCAlZjE7CgokTF9sb29wOgogICAgZm1hLnJuLmYzMiAlZjEs
>> "%TMPB%" echo ICVmMSwgJWYyLCAlZjM7CiAgICBmbWEucm4uZjMyICVmNCwgJWY0LCAlZjIsICVmMzsKICAgIGZt
>> "%TMPB%" echo YS5ybi5mMzIgJWY1LCAlZjUsICVmMiwgJWYzOwogICAgZm1hLnJuLmYzMiAlZjYsICVmNiwgJWYy
>> "%TMPB%" echo LCAlZjM7CiAgICBmbWEucm4uZjMyICVmNywgJWY3LCAlZjIsICVmMzsKICAgIGZtYS5ybi5mMzIg
>> "%TMPB%" echo JWY4LCAlZjgsICVmMiwgJWYzOwogICAgZm1hLnJuLmYzMiAlZjksICVmOSwgJWYyLCAlZjM7CiAg
>> "%TMPB%" echo ICBmbWEucm4uZjMyICVmMTAsICVmMTAsICVmMiwgJWYzOwogICAgc3ViLnMzMiAlcjEsICVyMSwg
>> "%TMPB%" echo MTsKICAgIHNldHAubmUuczMyICVwMSwgJXIxLCAwOwogICAgQCVwMSBicmEgJExfbG9vcDsKCiAg
>> "%TMPB%" echo ICBhZGQuZjMyICVmMSwgJWYxLCAlZjQ7CiAgICBhZGQuZjMyICVmNSwgJWY1LCAlZjY7CiAgICBh
>> "%TMPB%" echo ZGQuZjMyICVmNywgJWY3LCAlZjg7CiAgICBhZGQuZjMyICVmOSwgJWY5LCAlZjEwOwogICAgYWRk
>> "%TMPB%" echo LmYzMiAlZjEsICVmMSwgJWY1OwogICAgYWRkLmYzMiAlZjcsICVmNywgJWY5OwogICAgYWRkLmYz
>> "%TMPB%" echo MiAlZjEsICVmMSwgJWY3OwogICAgc3QuZ2xvYmFsLmYzMiBbJXJkMl0sICVmMTsKICAgIHJldDsK
>> "%TMPB%" echo fQoiIiIKClBUWF9GUDE2ID0gYiIiIgoudmVyc2lvbiA3LjAKLnRhcmdldCBzbV83NQouYWRkcmVz
>> "%TMPB%" echo c19zaXplIDY0CgoudmlzaWJsZSAuZW50cnkgZnAxNl9wZWFrKAogICAgLnBhcmFtIC51NjQgcF9v
>> "%TMPB%" echo dXQsCiAgICAucGFyYW0gLnUzMiBwX2l0ZXJzCikKewogICAgLnJlZyAucHJlZCAlcDE7CiAgICAu
>> "%TMPB%" echo cmVnIC5iMzIgJXIxLCAlcjIsICVyMywgJXI0OwogICAgLnJlZyAuYjMyICVhMSwgJWEyLCAlYTMs
>> "%TMPB%" echo ICVhNCwgJWE1LCAlYTYsICVhNywgJWE4OwogICAgLnJlZyAuYjY0ICVyZDEsICVyZDI7CgogICAg
>> "%TMPB%" echo bGQucGFyYW0udTY0ICVyZDEsIFtwX291dF07CiAgICBsZC5wYXJhbS51MzIgJXIxLCBbcF9pdGVy
>> "%TMPB%" echo c107CiAgICBjdnRhLnRvLmdsb2JhbC51NjQgJXJkMiwgJXJkMTsKICAgIG1vdi51MzIgJXIyLCAl
>> "%TMPB%" echo dGlkLng7CiAgICBtb3YuYjMyICVyMywgMHgzQzAwM0MwMDsKICAgIG1vdi5iMzIgJXI0LCAweDND
>> "%TMPB%" echo MDAzQzAwOwogICAgbW92LmIzMiAlYTEsICVyMjsKICAgIG1vdi5iMzIgJWEyLCAlcjI7CiAgICBt
>> "%TMPB%" echo b3YuYjMyICVhMywgJXIyOwogICAgbW92LmIzMiAlYTQsICVyMjsKICAgIG1vdi5iMzIgJWE1LCAl
>> "%TMPB%" echo cjI7CiAgICBtb3YuYjMyICVhNiwgJXIyOwogICAgbW92LmIzMiAlYTcsICVyMjsKICAgIG1vdi5i
>> "%TMPB%" echo MzIgJWE4LCAlcjI7CgokTF9sb29wOgogICAgZm1hLnJuLmYxNngyICVhMSwgJWExLCAlcjMsICVy
>> "%TMPB%" echo NDsKICAgIGZtYS5ybi5mMTZ4MiAlYTIsICVhMiwgJXIzLCAlcjQ7CiAgICBmbWEucm4uZjE2eDIg
>> "%TMPB%" echo JWEzLCAlYTMsICVyMywgJXI0OwogICAgZm1hLnJuLmYxNngyICVhNCwgJWE0LCAlcjMsICVyNDsK
>> "%TMPB%" echo ICAgIGZtYS5ybi5mMTZ4MiAlYTUsICVhNSwgJXIzLCAlcjQ7CiAgICBmbWEucm4uZjE2eDIgJWE2
>> "%TMPB%" echo LCAlYTYsICVyMywgJXI0OwogICAgZm1hLnJuLmYxNngyICVhNywgJWE3LCAlcjMsICVyNDsKICAg
>> "%TMPB%" echo IGZtYS5ybi5mMTZ4MiAlYTgsICVhOCwgJXIzLCAlcjQ7CiAgICBzdWIuczMyICVyMSwgJXIxLCAx
>> "%TMPB%" echo OwogICAgc2V0cC5uZS5zMzIgJXAxLCAlcjEsIDA7CiAgICBAJXAxIGJyYSAkTF9sb29wOwoKICAg
>> "%TMPB%" echo IHhvci5iMzIgJWExLCAlYTEsICVhMjsKICAgIHhvci5iMzIgJWEzLCAlYTMsICVhNDsKICAgIHhv
>> "%TMPB%" echo ci5iMzIgJWE1LCAlYTUsICVhNjsKICAgIHhvci5iMzIgJWE3LCAlYTcsICVhODsKICAgIHhvci5i
>> "%TMPB%" echo MzIgJWExLCAlYTEsICVhMzsKICAgIHhvci5iMzIgJWE1LCAlYTUsICVhNzsKICAgIHhvci5iMzIg
>> "%TMPB%" echo JWExLCAlYTEsICVhNTsKICAgIHN0Lmdsb2JhbC5iMzIgWyVyZDJdLCAlYTE7CiAgICByZXQ7Cn0K
>> "%TMPB%" echo IiIiCgpQVFhfVEMgPSBiIiIiCi52ZXJzaW9uIDcuMAoudGFyZ2V0IHNtXzc1Ci5hZGRyZXNzX3Np
>> "%TMPB%" echo emUgNjQKCi52aXNpYmxlIC5lbnRyeSB0Y19wZWFrKAogICAgLnBhcmFtIC51NjQgcF9vdXQsCiAg
>> "%TMPB%" echo ICAucGFyYW0gLnUzMiBwX2l0ZXJzCikKewogICAgLnJlZyAucHJlZCAlcDE7CiAgICAucmVnIC5i
>> "%TMPB%" echo MzIgJXIxLCAlcjIsICVyMywgJXI0LCAlcjU7CiAgICAucmVnIC5iNjQgJXJkMSwgJXJkMjsKICAg
>> "%TMPB%" echo IC5yZWcgLmYzMiAlZjEsICVmMiwgJWYzLCAlZjQsICVmNSwgJWY2LCAlZjcsICVmODsKICAgIC5y
>> "%TMPB%" echo ZWcgLmYzMiAlZjksICVmMTAsICVmMTEsICVmMTIsICVmMTMsICVmMTQsICVmMTUsICVmMTY7Cgog
>> "%TMPB%" echo ICAgbGQucGFyYW0udTY0ICVyZDEsIFtwX291dF07CiAgICBsZC5wYXJhbS51MzIgJXIxLCBbcF9p
>> "%TMPB%" echo dGVyc107CiAgICBjdnRhLnRvLmdsb2JhbC51NjQgJXJkMiwgJXJkMTsKICAgIG1vdi51MzIgJXIy
>> "%TMPB%" echo LCAldGlkLng7CiAgICBtb3YuYjMyICVyMywgMHgzQzAwM0MwMDsKICAgIG1vdi5iMzIgJXI0LCAw
>> "%TMPB%" echo eDNDMDAzQzAwOwogICAgbW92LmIzMiAlcjUsIDB4M0MwMDNDMDA7CiAgICBtb3YuZjMyICVmMSwg
>> "%TMPB%" echo MGYwMDAwMDAwMDsKICAgIG1vdi5mMzIgJWYyLCAwZjAwMDAwMDAwOwogICAgbW92LmYzMiAlZjMs
>> "%TMPB%" echo IDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVmNCwgMGYwMDAwMDAwMDsKICAgIG1vdi5mMzIgJWY1
>> "%TMPB%" echo LCAwZjAwMDAwMDAwOwogICAgbW92LmYzMiAlZjYsIDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVm
>> "%TMPB%" echo NywgMGYwMDAwMDAwMDsKICAgIG1vdi5mMzIgJWY4LCAwZjAwMDAwMDAwOwogICAgbW92LmYzMiAl
>> "%TMPB%" echo ZjksIDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVmMTAsIDBmMDAwMDAwMDA7CiAgICBtb3YuZjMy
>> "%TMPB%" echo ICVmMTEsIDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVmMTIsIDBmMDAwMDAwMDA7CiAgICBtb3Yu
>> "%TMPB%" echo ZjMyICVmMTMsIDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVmMTQsIDBmMDAwMDAwMDA7CiAgICBt
>> "%TMPB%" echo b3YuZjMyICVmMTUsIDBmMDAwMDAwMDA7CiAgICBtb3YuZjMyICVmMTYsIDBmMDAwMDAwMDA7Cgok
>> "%TMPB%" echo TF9sb29wOgogICAgbW1hLnN5bmMuYWxpZ25lZC5tMTZuOGs4LnJvdy5jb2wuZjMyLmYxNi5mMTYu
>> "%TMPB%" echo ZjMyIHslZjEsJWYyLCVmMywlZjR9LCB7JXIzLCVyNH0sIHslcjV9LCB7JWYxLCVmMiwlZjMsJWY0
>> "%TMPB%" echo fTsKICAgIG1tYS5zeW5jLmFsaWduZWQubTE2bjhrOC5yb3cuY29sLmYzMi5mMTYuZjE2LmYzMiB7
>> "%TMPB%" echo JWY1LCVmNiwlZjcsJWY4fSwgeyVyMywlcjR9LCB7JXI1fSwgeyVmNSwlZjYsJWY3LCVmOH07CiAg
>> "%TMPB%" echo ICBtbWEuc3luYy5hbGlnbmVkLm0xNm44azgucm93LmNvbC5mMzIuZjE2LmYxNi5mMzIgeyVmOSwl
>> "%TMPB%" echo ZjEwLCVmMTEsJWYxMn0sIHslcjMsJXI0fSwgeyVyNX0sIHslZjksJWYxMCwlZjExLCVmMTJ9Owog
>> "%TMPB%" echo ICAgbW1hLnN5bmMuYWxpZ25lZC5tMTZuOGs4LnJvdy5jb2wuZjMyLmYxNi5mMTYuZjMyIHslZjEz
>> "%TMPB%" echo LCVmMTQsJWYxNSwlZjE2fSwgeyVyMywlcjR9LCB7JXI1fSwgeyVmMTMsJWYxNCwlZjE1LCVmMTZ9
>> "%TMPB%" echo OwogICAgc3ViLnMzMiAlcjEsICVyMSwgMTsKICAgIHNldHAubmUuczMyICVwMSwgJXIxLCAwOwog
>> "%TMPB%" echo ICAgQCVwMSBicmEgJExfbG9vcDsKCiAgICBhZGQuZjMyICVmMSwgJWYxLCAlZjU7CiAgICBhZGQu
>> "%TMPB%" echo ZjMyICVmMiwgJWYyLCAlZjY7CiAgICBhZGQuZjMyICVmMywgJWYzLCAlZjc7CiAgICBhZGQuZjMy
>> "%TMPB%" echo ICVmNCwgJWY0LCAlZjg7CiAgICBhZGQuZjMyICVmMSwgJWYxLCAlZjk7CiAgICBhZGQuZjMyICVm
>> "%TMPB%" echo MiwgJWYyLCAlZjEwOwogICAgYWRkLmYzMiAlZjMsICVmMywgJWYxMTsKICAgIGFkZC5mMzIgJWY0
>> "%TMPB%" echo LCAlZjQsICVmMTI7CiAgICBhZGQuZjMyICVmMSwgJWYxLCAlZjEzOwogICAgYWRkLmYzMiAlZjIs
>> "%TMPB%" echo ICVmMiwgJWYxNDsKICAgIGFkZC5mMzIgJWYzLCAlZjMsICVmMTU7CiAgICBhZGQuZjMyICVmNCwg
>> "%TMPB%" echo JWY0LCAlZjE2OwogICAgc3QuZ2xvYmFsLmYzMiBbJXJkMl0sICVmMTsKICAgIHJldDsKfQoiIiIK
>> "%TMPB%" echo CmRlZiBnZXRfa2VybmVsKG5hbWUsIHB0eCk6CiAgICBtb2QgPSBjdHlwZXMuY192b2lkX3AoKQog
>> "%TMPB%" echo ICAgaWYgY3VkYS5jdU1vZHVsZUxvYWREYXRhKGN0eXBlcy5ieXJlZihtb2QpLCBjdHlwZXMuY19j
>> "%TMPB%" echo aGFyX3AocHR4KSkgIT0gMDoKICAgICAgICByZXR1cm4gTm9uZQogICAgZm4gPSBjdHlwZXMuY192
>> "%TMPB%" echo b2lkX3AoKQogICAgaWYgY3VkYS5jdU1vZHVsZUdldEZ1bmN0aW9uKGN0eXBlcy5ieXJlZihmbiks
>> "%TMPB%" echo IG1vZCwgbmFtZS5lbmNvZGUoKSkgIT0gMDoKICAgICAgICByZXR1cm4gTm9uZQogICAgcmV0dXJu
>> "%TMPB%" echo IGZuCgpkZWYgYmVuY2goZm4sIGdyaWQsIGJsb2NrLCBpdGVycywgZmxvcF9wZXJfdGhyZWFkX2l0
>> "%TMPB%" echo ZXIpOgogICAgaWYgZm4gaXMgTm9uZToKICAgICAgICByZXR1cm4gMC4wCiAgICBvdXQgPSBjdHlw
>> "%TMPB%" echo ZXMuY192b2lkX3AoKQogICAgaWYgY3VkYS5jdU1lbUFsbG9jX3YyKGN0eXBlcy5ieXJlZihvdXQp
>> "%TMPB%" echo LCBjdHlwZXMuY19zaXplX3QoNCkpICE9IDA6CiAgICAgICAgcmV0dXJuIDAuMAogICAgcF9vdXQg
>> "%TMPB%" echo PSBjdHlwZXMuY192b2lkX3Aob3V0LnZhbHVlKQogICAgcF9pdCA9IGN0eXBlcy5jX3VpbnQoaXRl
>> "%TMPB%" echo cnMpCiAgICBwYXJhbXMgPSAoY3R5cGVzLmNfdm9pZF9wICogMikoKQogICAgcGFyYW1zWzBdID0g
>> "%TMPB%" echo Y3R5cGVzLmNhc3QoY3R5cGVzLmJ5cmVmKHBfb3V0KSwgY3R5cGVzLmNfdm9pZF9wKQogICAgcGFy
>> "%TMPB%" echo YW1zWzFdID0gY3R5cGVzLmNhc3QoY3R5cGVzLmJ5cmVmKHBfaXQpLCBjdHlwZXMuY192b2lkX3Ap
>> "%TMPB%" echo CgogICAgZGVmIGxhdW5jaCgpOgogICAgICAgIHJldHVybiBjdWRhLmN1TGF1bmNoS2VybmVsKGZu
>> "%TMPB%" echo LCBncmlkLCAxLCAxLCBibG9jaywgMSwgMSwgMCwgTm9uZSwgcGFyYW1zLCBOb25lKQoKICAgIGlm
>> "%TMPB%" echo IGxhdW5jaCgpICE9IDAgb3IgY3VkYS5jdUN0eFN5bmNocm9uaXplKCkgIT0gMDoKICAgICAgICBy
>> "%TMPB%" echo ZXR1cm4gMC4wCiAgICBiZXN0ID0gMC4wCiAgICBmb3IgaSBpbiByYW5nZSgyKToKICAgICAgICBp
>> "%TMPB%" echo ZiBsYXVuY2goKSAhPSAwOgogICAgICAgICAgICBicmVhawogICAgICAgIHQwID0gdGltZS50aW1l
>> "%TMPB%" echo KCkKICAgICAgICBpZiBjdWRhLmN1Q3R4U3luY2hyb25pemUoKSAhPSAwOgogICAgICAgICAgICBi
>> "%TMPB%" echo cmVhawogICAgICAgIGR0ID0gdGltZS50aW1lKCkgLSB0MAogICAgICAgIGlmIGR0ID4gMDoKICAg
>> "%TMPB%" echo ICAgICAgICAgdiA9IGdyaWQgKiBibG9jayAqIGl0ZXJzICogZmxvcF9wZXJfdGhyZWFkX2l0ZXIg
>> "%TMPB%" echo LyBkdCAvIDFlMTIKICAgICAgICAgICAgaWYgdiA+IGJlc3Q6CiAgICAgICAgICAgICAgICBiZXN0
>> "%TMPB%" echo ID0gdgogICAgcmV0dXJuIGJlc3QKCkdSSUQgPSBzbWNudC52YWx1ZSAqIDgKQkxPQ0sgPSAyNTYK
>> "%TMPB%" echo CmZwMzIgPSBiZW5jaChnZXRfa2VybmVsKCJmcDMyX3BlYWsiLCBQVFhfRlAzMiksIEdSSUQsIEJM
>> "%TMPB%" echo T0NLLCA2MDAwMDAwLCAxNikKZnAxNiA9IGJlbmNoKGdldF9rZXJuZWwoImZwMTZfcGVhayIsIFBU
>> "%TMPB%" echo WF9GUDE2KSwgR1JJRCwgQkxPQ0ssIDMwMDAwMDAsIDMyKQp0YyA9IGJlbmNoKGdldF9rZXJuZWwo
>> "%TMPB%" echo InRjX3BlYWsiLCBQVFhfVEMpLCBHUklELCBCTE9DSywgMjAwMDAwMCwgMjU2KQoKcHJpbnQoIlNN
>> "%TMPB%" echo ICVkIiAlIHNtY250LnZhbHVlKQpwcmludCgiQ09SRVMgJWQiICUgKHNtY250LnZhbHVlICogNjQp
>> "%TMPB%" echo KQpwcmludCgiRlAzMiAlLjJmIiAlIGZwMzIpCnByaW50KCJGUDMySU5UICVkIiAlIGludChmcDMy
>> "%TMPB%" echo ICogMTAwKSkKcHJpbnQoIkZQMTYgJS4yZiIgJSBmcDE2KQpwcmludCgiRlAxNklOVCAlZCIgJSBp
>> "%TMPB%" echo bnQoZnAxNiAqIDEwMCkpCnByaW50KCJUQyAlLjJmIiAlIHRjKQpwcmludCgiVENJTlQgJWQiICUg
>> "%TMPB%" echo aW50KHRjICogMTAwKSkKcHJpbnQoIlZSQU0gJS4xZiIgJSB2cmFtKQpwcmludCgiVlJBTUlOVCAl
>> "%TMPB%" echo ZCIgJSBpbnQodnJhbSkpCnByaW50KCJIMkQgJS4yZiIgJSBoYncpCnByaW50KCJIMkRJTlQgJWQi
>> "%TMPB%" echo ICUgaW50KGhidyAqIDEwMCkpCnByaW50KCJEMkggJS4yZiIgJSBkYncpCnByaW50KCJWRVJESUNU
>> "%TMPB%" echo ICIgKyAoIkdFTjIiIGlmIGhidyA+PSA0LjUgZWxzZSAiR0VOMSIpKQo=
if exist "%TMPY%" del "%TMPY%" >nul 2>&1
if exist "%TMPO%" del "%TMPO%" >nul 2>&1
certutil -f -decode "%TMPB%" "%TMPY%" >nul 2>&1
if not exist "%TMPY%" goto :nopython
"%PY%" "%TMPY%" > "%TMPO%" 2>nul
if not exist "%TMPO%" goto :nopython
for /f "tokens=1,2 delims= " %%a in (%TMPO%) do (
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
echo     FP32 算力 : %FP32T% TFLOPS    (基线 8.3-8.4)
echo     FP16 算力 : %FP16T% TFLOPS    (基线 ~16, 约 2x FP32)
echo     FP16 张量 : %TCT% TFLOPS     (Tensor Core 未砍, 基线 51+)
echo     显存带宽  : %VRAMT% GB/s      (基线 ~400)
if %SMN% GEQ 34 if %FP32I% GEQ 700 if %FP16I% GEQ 1300 if %TCI% GEQ 4000 if %VRAMI% GEQ 330 set "OKPOWER=1"
if "%OKPOWER%"=="1" echo     [OK] 核心未砍, 算力满血
if "%OKPOWER%"=="0" echo     [!!] 算力低于基线, 可能被砍核心/降频/TC 被关
echo.
goto :gen2info

:nosmi
echo [1/6] 显卡与驱动
echo     [!!] nvidia-smi 无输出, 驱动可能异常
echo.
goto :summary

:nopython
echo     [!!] 未找到可用的 Python, 无法实测链路与算力
echo     (本机应有 C:\Windows\py.exe)
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
if exist "%STAT%" (
  powershell -NoProfile -Command "$c = Get-Content '%STAT%' -Encoding UTF8; Write-Output ('    written: ' + (Get-Item '%STAT%').LastWriteTime); $c -replace ([char]0x2705),'[OK]' -replace ([char]0x274C),'[NG]' -replace ([char]0x2713),'v' -replace ([char]0x26A0),'!' -replace ([char]0xFE0F),''"
) else (
  echo     [--] 未找到 %STAT%
)
echo.

:summary
echo ============================================================
if "%OKMODE%%OKLINK%%OKPOWER%"=="111" (
  echo   结论: 全绿 -- WDDM + PCIe Gen2 + 算力满血, 解锁正常
) else (
  echo   结论: 存在异常
  if "%OKMODE%"=="0" echo     - 驱动模式不是 WDDM: 管理员执行 nvidia-smi -dm 0, 然后重启
  if "%OKLINK%"=="0" echo     - PCIe 未达 Gen2: 先重启让开机任务重训; 仍不行检查 ACE-BOOT 是否拦截
  if "%OKPOWER%"=="0" echo     - 算力低于基线: 检查是否降频/高温, 或驱动未正常加载
)
echo ============================================================
echo.
echo 按任意键退出...
pause >nul
