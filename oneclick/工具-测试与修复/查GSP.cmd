@echo off
rem 2026-10-04: 双击入口 —— CMP 40HX 的 GSP（GPU 固件）诊断；加 /fix 才会写注册表。
chcp 936 >nul
title 40HX GSP 诊断 - 默认自动修复；/readonly 才只读
echo ============================================================
echo   CMP 40HX  GSP（GPU 固件）诊断    默认：体检 + 条件具备就自动修
echo     跑完会自动打开报告（记事本）
echo   只是不想让它写注册表（纯只读）: 查GSP.cmd /readonly
echo ============================================================
echo.
cd /d "%~dp0"

rem ---- 2026-10-04: preflight ------------------------------------------------------------
rem Single line + label at EOF on purpose: a parenthesised block breaks when the folder
rem   name contains ) or & (e.g. Windows unpacks twice -> "xxx (1)").
if not exist "%~dp0查GSP.ps1" goto nops1
set "PSARGS="
if /I "%~1"=="/fix" set "PSARGS=-Fix"
rem 2026-10-08: 默认就是“条件具备自动修”；/readonly（兼容 /ro、/nofix）才是纯只读
if /I "%~1"=="/readonly" set "PSARGS=-NoFix"
if /I "%~1"=="/ro" set "PSARGS=-NoFix"
if /I "%~1"=="/nofix" set "PSARGS=-NoFix"
rem 2026-10-04: NO_ELEVATE=1 时把 -NoElevate 传下去（无人值守 / 自动化验证用，不弹 UAC）
if "%NO_ELEVATE%"=="1" set "PSARGS=%PSARGS% -NoElevate"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0查GSP.ps1" %PSARGS%
set "RC=%ERRORLEVEL%"
if not "%NO_PAUSE%"=="1" pause >nul
rem 2026-10-04: carry the real exit code out (was implicit 0) and never fall into :nops1
exit /b %RC%

:nops1
echo ============================================================
echo  [注意] 没找到 查GSP.ps1
echo    本工具要靠同目录的这个 .ps1 干活；现在读不到它，所以什么都还没做
echo    （Windows 会因此显示 -196608，也就是 0xFFFD0000）
echo    1. 别在压缩包里直接运行 —— 先把 zip 完整解压到一个文件夹再运行
echo    2. 杀软可能把 .ps1 删了或隔离了 —— 到隔离区恢复它，并把本目录加进信任区
echo    3. .ps1 必须与本 .cmd 在同一个目录（只拷 .cmd 出来不管用）
echo    4. 包别放在映射的网络盘或共享目录上 —— 拷到本机硬盘再运行
echo 当前目录（可截图发回）
echo      "%~dp0"
echo ============================================================
if not "%NO_PAUSE%"=="1" pause >nul
exit /b 1
