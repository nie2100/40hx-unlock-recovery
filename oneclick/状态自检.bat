@echo off
rem Copyright 2026 nie2100 - All rights reserved; redistribution or resale not permitted.
rem Upstream MIT parts: CMP40HX-Unlock by PZH1gdmu / CMP40HX-Unlock-OnlyEFI by BardKing-CN.
chcp 936 >nul 2>&1
title 40HX 解锁状态检查
setlocal
rem 2026-10-10（审查低-2）：只读体检不需要管理员，但部分修复建议（如 nvidia-smi -dm 0）需要，先声明
fltmc >nul 2>&1
if errorlevel 1 echo     [提示] 当前不是管理员身份运行：体检照常，但若结论建议你执行修复命令，请先用管理员身份打开 cmd

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
rem 2026-10-06：逐项判定变量。1=实测通过 / 0=实测不通过 / 2=本机没测成(未实测)
rem   默认 2 = "还没测"：只有真跑出结果的分支才把它改成 1 或 0，避免拿"没测"当"通过"。
set "OK1=2"
set "OK2=2"
set "OK3=2"
set "OK4=2"
set "OK5=2"
set "NGN="
set "WAITN="
set "EARLY="
set "TASKV="
set "TMPT=%TEMP%\40hx_task.stat"
set "TMPCL=%TEMP%\40hx_check.lst"
set "TMPG=%TEMP%\40hx_gsp.txt"
set "TMPG2=%TEMP%\40hx_gsp_v.txt"
set "TMPG3=%TEMP%\40hx_c43.txt"
set "TMPW=%TEMP%\40hx_width.txt"

echo ============================================================
echo                 40HX 解锁状态检查
echo ============================================================
echo.

if not exist "%SMI%" (
  echo   [错误] 未找到 %SMI%
  set "OK1=0"
  set "EARLY=1"
  goto :summary
)

"%SMI%" --query-gpu=name,driver_version,memory.total,temperature.gpu,power.draw,power.limit,driver_model.current,driver_model.pending,pcie.link.width.current,pcie.link.width.max --format=csv > "%TMPQ%" 2>nul
if not exist "%TMPQ%" goto :nosmi
rem 2026-10-10（审查低-1）：> 重定向在命令失败时也会建 0 字节文件，体积为 0 同样按无输出处理
for %%A in ("%TMPQ%") do if "%%~zA"=="0" goto :nosmi
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
rem 2026-10-06：这一项以前只有读数、没有结论，末行照样写"全绿" —— 现在有结论且计入判定
set "OK1=0"
if not "%GPU%"=="" if not "%DRV%"=="" set "OK1=1"
rem 2026-10-06（审查 r1 低危）：nvidia-smi 拿不到版本时会给字面量 N/A / [N/A] —— 那不是"正常"
if /I "%DRV%"=="N/A" set "OK1=0"
if /I "%DRV%"=="[N/A]" set "OK1=0"
if "%OK1%"=="1" echo     [OK] 显卡与驱动已识别
if "%OK1%"=="0" echo     [!!] 上面型号/驱动版本是空的或是 N/A: nvidia-smi 没读到卡, 或驱动异常

rem 2026-10-10（用户要求）：GSP 固件状态提到这里查 —— GSP 关着 + 代码 43 时显卡已被驱动停用，
rem   后面的带宽/算力实测注定失败（CUDA 初始化不了），确诊就直接跳结论区，不白跑也不吓人。
set "GSPK=2"
set "GSPV="
if exist "%TMPG2%" del "%TMPG2%" >nul 2>&1
"%SMI%" -q > "%TMPG%" 2>nul
if exist "%TMPG%" powershell -NoProfile -Command "$q=[IO.File]::ReadAllText('%TMPG%');$m=[regex]::Match($q,'(?im)^\s*GSP Firmware Version\s*:\s*(.+?)\s*$');if(-not $m.Success){'UNKNOWN'}else{$v=$m.Groups[1].Value.Trim();if($v -match '^\d+(\.\d+)+'){'ON '+$v}else{'OFF '+$v}}" > "%TMPG2%" 2>nul
if exist "%TMPG2%" for /f "usebackq delims=" %%a in ("%TMPG2%") do set "GSPV=%%a"
if defined GSPV if "%GSPV:~0,2%"=="ON" set "GSPK=1"
if defined GSPV if "%GSPV:~0,3%"=="OFF" set "GSPK=0"
if "%GSPK%"=="1" echo     [OK] GSP 固件  : 已启用 (%GSPV:~3%)
if not defined GSPV echo     [--] GSP 固件  : 没能判定（nvidia-smi -q 被拦?）-- 不影响下面的实测
if defined GSPV if "%GSPV:~0,7%"=="UNKNOWN" echo     [--] GSP 固件  : nvidia-smi -q 里没有 GSP 行（驱动太老?）-- 不影响下面的实测
if not "%GSPK%"=="0" goto :gsp_ok
echo     [!!] GSP 固件  : 未启用 (%GSPV:~4%) -- 解锁后 nvlddmkm 认不了卡 = 黑屏 + 设备管理器代码 43
echo            处理: 双击 GSP体检.cmd 自动修, 然后【完全关机】（不是重启）再开机
rem GSP 没开时再看一眼是不是已经代码 43 了：是 → 跳过 [2/6]~[4/6] 实测
set "C43="
if exist "%TMPG3%" del "%TMPG3%" >nul 2>&1
powershell -NoProfile -Command "$d=Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match '40HX' -or $_.InstanceId -match 'DEV_1F0B' } | Select-Object -First 1; if($d){$pc=(Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data; if($pc -eq 43){'C43'}else{'OK'}}else{'NODEV'}" > "%TMPG3%" 2>nul
if exist "%TMPG3%" for /f "usebackq delims=" %%a in ("%TMPG3%") do set "C43=%%a"
if not "%C43%"=="C43" goto :gsp_ok
echo     [!!] 显卡当前就是代码 43（驱动停用了这张卡）-- [2/6]~[4/6] 的实测跳过（测了也必败）
echo            顺序: 先修 GSP（见上面），完全关机再开机，再跑本脚本复核
set "OK2=2"
set "OK3=2"
set "OK4=2"
goto :gen2info
:gsp_ok
echo.

echo [2/6] 驱动模式   (WDDM = WSL 直通可用)
echo     当前 : %DMC%     待生效 : %DMP%
if /I "%DMC%"=="WDDM" set "OKMODE=1"
if /I "%DMC%"=="WDDM" echo     [OK] WDDM 模式正常
if /I "%DMC%"=="TCC" echo     [!!] TCC 模式异常: WSL 直通会失效, PCIe 也会掉回 Gen1
set "OK2=0"
if "%OKMODE%"=="1" set "OK2=1"
if /I not "%DMC%"=="WDDM" if /I not "%DMC%"=="TCC" echo     [!!] 驱动模式既不是 WDDM 也不是 TCC: driver_model 没解析到
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
echo                （宽度不是 x16 时按比例折算: Gen2 x8 约 3.0-3.4, 与 Gen1 x16 重叠 —— 看下面宽度判定）
if /I "%VERD%"=="GEN2" set "OKLINK=1"
if /I "%VERD%"=="GEN2" echo     [OK] 判定: Gen2 已解锁
if /I "%VERD%"=="GEN1" echo     [!!] 判定: Gen1 未解锁
if not defined VERD echo     [!!] 判定: 带宽测试失败
rem 2026-10-06：只有真跑出 VERDICT 才算判定，跑不出来仍旧算"未实测"(2)
if /I "%VERD%"=="GEN2" set "OK3=1"
if /I "%VERD%"=="GEN1" set "OK3=0"
rem 2026-10-01b（第三方审查 H17）：实测程序失败时也会建出空的 %TMPO% → 以前直接落到"带宽测试失败"，
rem   真正的根因（nvcuda/驱动的 ERROR 行）从不显示。把原始输出回显出来，别让客户/经销商猜。
if not defined VERD if exist "%TMPO%" (
  echo     ---- 实测程序原始输出（定位根因用）----
  type "%TMPO%"
  echo     --------------------------------------
)

rem 2026-10-10（客户现场）：宽度判读 —— 没补电容的卡电气上限只有 x8；有些主板物理 x16 槽电气只有 x4/x8。
rem   Gen2 x8 ≈ 3.0-3.4 GB/s 与 Gen1 x16 的 3.1-3.4 重叠 → 总带宽分不清，按"每通道带宽"(H2D/宽度)复判：
rem   每通道不低于 0.34 GB/s = Gen2 速率。
set "WSTAT="
set "WLANE="
if exist "%TMPW%" del "%TMPW%" >nul 2>&1
powershell -NoProfile -Command "$c=0;$m=0;$h=0.0;[void][int]::TryParse('%LWC%',[ref]$c);[void][int]::TryParse('%LWM%',[ref]$m);[void][double]::TryParse('%H2DT%',[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$h);$o='UNK';if($m -gt 0){if($m -lt 16){$o='MAXLOW'}elseif($c -lt $m){$o='CURLOW'}else{$o='FULL'}};$lane='NA';if($h -gt 0 -and $c -gt 0){if($h/$c -ge 0.34){$lane='G2'}else{$lane='G1'}};$o+'|'+$lane+'|'+$c+'|'+$m" > "%TMPW%" 2>nul
if exist "%TMPW%" for /f "usebackq tokens=1-4 delims=|" %%a in ("%TMPW%") do (set "WSTAT=%%a" & set "WLANE=%%b")
if "%WSTAT%"=="FULL" echo     [OK] 链路宽度 x%LWC% 全满
if not "%WSTAT%"=="MAXLOW" goto :w_notmaxlow
echo     [!!] 该槽/该卡电气上限只有 x%LWM%（注意: 物理 x16 不等于电气 x16）
echo            两种可能: ①卡没补电容（40HX 要补电容才有 x16 电气）②插错槽（主板这条槽电气只有 x%LWM%）
echo            处理: 完全关机后换主板【第一条】x16 槽再测；还是 x%LWM% 就是卡没补电容
echo            （只影响带宽不影响算力: Gen2 x8 带宽上限约 3.3 GB/s, 到不了 x16 的 5.8+）
:w_notmaxlow
if not "%WSTAT%"=="CURLOW" goto :w_notcurlow
echo     [!!] 链路只协商到 x%LWC%（槽位上限 x%LWM%）—— 没插紧/金手指脏居多
echo            处理: 完全关机后重插显卡（橡皮擦一下金手指），不行换槽
:w_notcurlow
rem 宽度不够时总带宽低≠没解锁：Gen1 判定要按每通道带宽复核
if /I "%VERD%"=="GEN1" if "%WLANE%"=="G2" (
  echo     [说明] 按每通道带宽算其实是 Gen2 x%LWC%（宽度受限把总带宽拉低了）—— 不是没解锁, 按黄色"宽度受限"计
  set "OK3=2"
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
rem 2026-10-06：同样只有真跑出 VERDICT 才敢判"低/够"，没跑出来算未实测
if not defined VERD goto :power_done
if "%OKPOWER%"=="1" set "OK4=1"
if "%OKPOWER%"=="0" set "OK4=0"
:power_done
echo.
goto :gen2info

:nosmi
echo [1/6] 显卡与驱动
echo     [!!] nvidia-smi 无输出, 驱动可能异常
set "OK1=0"
set "EARLY=1"
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
echo            ^(这不是显卡故障^) 多为安全软件拦截 "%TEMP%" 下的现场编译与运行;
echo            把 "%TEMP%" 加入杀软信任区后重跑即可, 不必重装本工具
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
rem 2026-10-06：这一项以前只贴日志、不进结论 —— 于是"日志里是上一次开机的 PASS"也能配上"全绿"。
rem   现在按两条判：①日志是不是本次开机写的（LastWriteTime > LastBootUpTime）②最后一轮是不是
rem   EXIT=0 且带 PASS 行。刚开机 3 分钟内还没落日志的算"未实测"，不冤枉它。
rem   2026-10-08（客户机实测）：开机后**立刻**跑本脚本还会踩到"本轮已 start、还没落 EXIT 行" —— 原来这种也判 FAIL(红)，
rem   客户以为开机任务坏了（其实是那一轮要 1~3 分钟）。现在多一个 RUN 结论：日志在 4 分钟内刚更新过、本轮又没有 EXIT 行
rem   = 任务还在跑（黄/未实测）；超过 4 分钟还没 EXIT 行 = 真的没跑成（红）。
rem   2026-10-08（审查 Q1，中危）：FAIL: 也算"本轮已经出结论" —— 它只在失败分支写
rem   （payload\windows\RunPostBind.cmd 里 RC!=0 才 echo FAIL:），本机 36 轮日志里出现 0 次。
rem   不这么收的话，"已打 FAIL: 但进程被杀没落 EXIT"的轮次会被当黄(未实测)，等于把真失败藏起来。
rem   判定用 PowerShell 一次性给结论：命令行里只用单引号、不拼中文路径/参数（免得代码页把参数搞坏）。
set "OK5=0"
rem 同一个 %TMPT% 会被上一次运行留下 —— 先删掉, 免得拿上次的结论当本次的（本机实测踩到过）
if exist "%TMPT%" del "%TMPT%" >nul 2>&1
if exist "%LOGP%" powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='%LOGP%';$bt=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime;$f=Get-Item -LiteralPath $p;$t=[IO.File]::ReadAllText($p);$i=$t.LastIndexOf('PostBind start');$ok=$false;$done=$false;if($i -ge 0){$tail=$t.Substring($i);$done=(($tail -match 'PostBind EXIT') -or ($tail -match 'FAIL:'));if(($tail -match 'EXIT=0') -and ($tail -match 'PASS: Gen2 reached on the new path')){$ok=$true}};if($f.LastWriteTime -gt $bt){if($ok){'OK'}elseif((-not $done) -and (((Get-Date)-$f.LastWriteTime).TotalMinutes -lt 4)){'RUN'}else{'FAIL'}}else{if(((Get-Date)-$bt).TotalMinutes -lt 3){'WAIT'}else{'STALE'}}" > "%TMPT%" 2>nul
if exist "%TMPT%" for /f "usebackq delims=" %%a in ("%TMPT%") do set "TASKV=%%a"
if "%TASKV%"=="OK" set "OK5=1"
if "%TASKV%"=="OK" echo     [OK] 本次开机的任务跑过: 最后一轮 EXIT=0 + PASS
if "%TASKV%"=="FAIL" echo     [!!] 最近的日志轮次没有 EXIT=0 + PASS: 开机任务没跑成
if "%TASKV%"=="STALE" echo     [!!] 日志还停在"上一次开机": 本次开机的任务没跑成
if "%TASKV%"=="WAIT" set "OK5=2"
if "%TASKV%"=="WAIT" echo     [--] 本次开机的日志还没落下来(任务在进桌面后约 1 分钟内跑, 稍后重跑本脚本)
if "%TASKV%"=="RUN" set "OK5=2"
if "%TASKV%"=="RUN" echo     [--] 本次开机的任务本轮**还在跑**(日志已 start, 还没落 EXIT 行) -- 等 2~3 分钟再跑本脚本
if not exist "%LOGP%" echo     [!!] 没有开机任务日志: 可能没装开机任务(见 排查指引 第 5 节)
if not defined TASKV if exist "%LOGP%" echo     [!!] 没能判定: PowerShell 没给出结果(被拦或本机没有 PowerShell)
rem 2026-10-06（审查 r1 中危）：TASKV 空 = "测不成", 不是"未过" —— 计为未实测(2)，别报成假红
if not defined TASKV if exist "%LOGP%" set "OK5=2"
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
  rem 2026-10-06：这一项是厂商工具留下的文件, 本包不走它 —— 明确标"参考", 不计入结论
  echo     [参考] 上面是厂商工具的状态文件, 本包不用它: 过期或内容旧都不算异常
  if defined NPASS (
    echo.
    echo     [说明] 上面这份是**厂商工具**的状态文件; 本包走新路径 ^(ECAM+inpoutx64, 不需要 ThrottleStop^),
    echo            它报"ThrottleStop 驱动未运行"属正常现象, 请以 [5/6] 的 PASS 为准
  )
) else (
  rem 2026-10-10（用户要求）：新装机器本来就没有这个文件 —— 一句"正常"带过, 不再打"未找到"吓人
  echo     [OK] 本机没有厂商工具遗留的状态文件 ^(新装机器本来就没有, 正常^)
)
echo.

:summary
rem ---- 把 6 项的实测状态汇总成"未过/未实测"两个清单（顺序 if, 不用块; 必须放在这里 ——
rem   前面几条 goto :summary 的早退路径会跳过 [1/6]..[6/6] 之间的代码）----
if "%OK1%"=="0" set "NGN=%NGN% 显卡与驱动"
if "%OK2%"=="0" set "NGN=%NGN% 驱动模式"
if "%OK3%"=="0" set "NGN=%NGN% PCIe 链路"
if "%OK4%"=="0" set "NGN=%NGN% 算力/显存"
if "%OK5%"=="0" set "NGN=%NGN% 开机任务"
if "%GSPK%"=="0" set "NGN=%NGN% GSP固件未启用"
if "%OK1%"=="2" set "WAITN=%WAITN% 显卡与驱动"
if "%OK2%"=="2" set "WAITN=%WAITN% 驱动模式"
if "%OK3%"=="2" set "WAITN=%WAITN% PCIe 链路(算力/带宽没实测成)"
if "%OK4%"=="2" set "WAITN=%WAITN% 算力/显存"
if "%OK5%"=="2" set "WAITN=%WAITN% 开机任务(未实测: 本次没落日志/本轮还在跑, 或本机判不了)"
echo ============================================================
rem 2026-10-06（本次改造的核心）：结论不再由 WDDM/Gen2/算力 三个开关一句话拍出来，
rem   而是先把 6 项各自的实测结果摆成彩色清单，再按这 6 项算结论：
rem   [OK]=绿  [!!]=红  [--]=黄(未实测)；只要有一项是红的, 结论就不会是"全绿"。
rem   2026-10-04 实测记录（保留）：算力/显存读数随 GPU 当时负载与时钟波动 —— 同一张好卡空闲时 32C/1650MHz
rem   测到 FP32 8.4, 连续压测后 56C/1470MHz 只有 7.9；显存带宽单次采样还曾低到 282 GB/s, 空闲复测 358-400。
rem   所以只有"性能类"读数不达标时结论写"需复核"而不是"存在异常", 免得客户以为解锁失败/硬件坏了。
rem   这里用顺序判断而不是 if/else 块, 免得踩块内 %VAR% 提前展开的坑。
set "VERDICT=异常"
if "%OK1%%OK2%%OK3%%OK4%%OK5%"=="11111" set "VERDICT=全绿"
if "%OK1%%OK2%%OK3%%OK4%%OK5%"=="11101" set "VERDICT=需复核"
if "%VERDICT%"=="异常" if not defined NGN set "VERDICT=部分未实测"
set "VST=0"
set "SUMV=存在异常 -- 未过的项:%NGN%"
if "%VERDICT%"=="全绿" set "VST=1"
if "%VERDICT%"=="全绿" set "SUMV=全绿 -- WDDM + PCIe Gen2 + 算力满血, 解锁正常"
if "%VERDICT%"=="需复核" set "VST=2"
if "%VERDICT%"=="需复核" set "SUMV=需复核 -- WDDM 正常 + PCIe Gen2 已解锁, 但算力/显存读数低于判据下限"
if "%VERDICT%"=="部分未实测" set "SUMV=部分未实测 -- 已过的项都正常; 未实测:%WAITN%"
rem 2026-10-08：光有文案不够 —— VST 留在 0 会让这一行印成红色（上色脚本把非 1/0 的都当黄，只有 0 是红），
rem   客户看到"黄项 + 红结论"照样会以为解锁失败。这里让它跟"未实测"的语义一致：黄。
if "%VERDICT%"=="部分未实测" set "VST=2"
rem ---- 彩色逐项清单：标签+状态先落成文件, 再由 PowerShell 读文件上色 ----
rem   （-Command 里只有写死的几个中文字面量; 路径/参数一律不传中文, 实测 chcp 936 正常）
> "%TMPCL%" echo %OK1%;显卡与驱动
>> "%TMPCL%" echo %OK2%;驱动模式 WDDM
>> "%TMPCL%" echo %OK3%;PCIe 链路 Gen2
>> "%TMPCL%" echo %OK4%;算力与显存满血
>> "%TMPCL%" echo %OK5%;开机任务 本次开机
if defined GSPK >> "%TMPCL%" echo %GSPK%;GSP 固件
if exist "%STAT%" >> "%TMPCL%" echo 2;厂商工具状态文件 参考项
>> "%TMPCL%" echo V;%VST%;%SUMV%
powershell -NoProfile -ExecutionPolicy Bypass -Command "$cn=@{'1'='Green';'0'='Red';'2'='Yellow'};$sw=@{'1'='[OK]';'0'='[!!]';'2'='[--]'};foreach($l in ([IO.File]::ReadAllLines([string]'%TMPCL%',[Text.Encoding]::GetEncoding(936)))){$p=$l.Split([char]59);if($p.Count -lt 2){continue};if($p[0] -eq 'V'){$k=$p[1];if($k -ne '1'){if($k -ne '0'){$k='2'}};$tx=($p[2..($p.Count-1)] -join ';');Write-Host ('   结论: ' + $tx) -ForegroundColor $cn[$k]}else{$k=$p[0];if($k -ne '1'){if($k -ne '0'){$k='2'}};Write-Host ('   ' + $sw[$k] + ' ' + $p[1]) -ForegroundColor $cn[$k]}}"
if "%OK5%"=="0" echo     - 开机任务没跑成: 见 排查指引 第 5 节; 也可以直接重启一次再跑本脚本
if "%OK5%"=="2" if not defined EARLY echo     - 开机任务未实测: 本次还没落日志/本轮还在跑 -- 等进桌面 1~3 分钟再跑本脚本; 本机判不了就看 [5/6] 的说明
if "%OK1%"=="0" echo     - 没读到显卡/驱动: 先确认 nvidia-smi 能跑、驱动正常(设备管理器有没有感叹号)
if "%OK2%"=="0" echo     - 驱动模式不是 WDDM: 管理员执行 nvidia-smi -dm 0, 然后重启
if "%GSPK%"=="0" echo     - GSP 固件未启用: 双击 GSP体检.cmd 自动修, 然后【完全关机】再开机后复核
rem 2026-10-10（用户要求）：算力正常但 Gen2 没训上时，先排除"开机任务还没跑/还在跑"的时间窗（登录后约 1 分钟还有补跑轮），
rem   确定是任务没补上才引导跑修复脚本；ACE 已不碰（2026-10-10 起降级链移除），不再提 ACE-BOOT。
if "%OK3%"=="0" if not defined NOCSC if "%OK5%"=="2" echo     - PCIe 未达 Gen2: 但开机任务还没跑完（登录后约 1 分钟还有一轮补跑）—— 等 2~3 分钟重跑本脚本看 [5/6], 先别动
if "%OK3%"=="0" if not defined NOCSC if not "%OK5%"=="2" echo     - PCIe 未达 Gen2 且开机任务没补上: 双击 一键修复Gen2.cmd（自动重建开机任务 + 清卡住的轮锁 + 当场补训一次，结果存桌面）
if "%WSTAT%"=="MAXLOW" echo     - 链路上限只有 x%LWM%: 先换第一条 x16 槽排除插错; 依旧则是卡没补电容（硬件上限, 不影响算力）
if "%WSTAT%"=="CURLOW" echo     - 链路从 x%LWM% 掉到 x%LWC%: 完全关机重插显卡/擦金手指, 不行换槽
rem 2026-10-10（用户指出）：跑码必解锁 —— 算力没解锁 ≈ 本次开机没走 40HX Unlock 启动项（BIOS 没把它放第一）。
rem   形态区分：SM 满 34 但张量核被砍（TCI 远低于 4000=40T 判据，砍了的卡只剩零头）= 没跑码；略低于判据 = 降频/高温。
set "LOCKSIG="
if "%OK4%"=="0" if not defined NOCSC if %SMN% GEQ 34 if %TCI% LSS 2000 set "LOCKSIG=1"
if defined LOCKSIG echo     - 算力没解锁（SM 满血但张量核被砍的形态）: 最可能是本次开机没走 40HX Unlock 启动项（跑码必解锁）
if defined LOCKSIG echo       - 进 BIOS 把 40HX Unlock 设为第一启动项（或管理员跑 Install-40HXUnlock.ps1 -Mode MakeDefault）, 完全关机再开机后复核
if defined LOCKSIG echo       - 旁证: ESP 里 40hx_log.txt 时间不是本次开机 = 没跑码（管理员跑 -Mode Verify 可查）
if "%OK4%"=="0" if not defined NOCSC if not defined LOCKSIG echo     - 算力/显存低于判据下限: 检查是否降频/高温, 或驱动未正常加载
if "%VERDICT%"=="需复核" echo     - 先空闲时重跑一次: 关掉占用 GPU 的程序, 等一两分钟再跑本脚本
if defined NOCSC echo     - 本机没有可用的 csc.exe: 实测算力/带宽做不了(不是显卡故障), Gen2 以 [5/6] 的 PASS 为准
if defined EARLY echo     - 本次检查没跑完(上面已说明原因): 结论只覆盖已执行到的那部分
echo ============================================================
:selfcheck_end
echo.
echo 按任意键退出...
pause >nul
