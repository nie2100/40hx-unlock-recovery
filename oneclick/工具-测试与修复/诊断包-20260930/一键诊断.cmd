@echo off
chcp 936 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0"

rem ---- 2026-10-04: preflight ------------------------------------------------------------
rem Single line + label at EOF on purpose: a parenthesised block breaks when the folder
rem   name contains ) or & (e.g. Windows unpacks twice -> "xxx (1)").
if not exist "%~dp040HX诊断.ps1" goto nops1
title CMP 40HX 诊断采集（只读）

rem 已提权的那一份（带 elevated 标记）直接干活
echo %* | findstr /i "elevated" >nul && goto run

net session >nul 2>&1
if errorlevel 1 goto ask

:run
echo ==============================================================
echo   CMP 40HX 诊断采集（只读：不改任何设置）
echo ==============================================================
echo   会收集：显卡/显示状态、代码43、GSP 注册表、nvidia-smi、
echo           一键包日志、ESP 解锁固件、固件启动项、开机时间线
echo.
echo   完成后报告在：桌面 40HX诊断报告-机器名-时间.txt
echo   （同目录还有 40HX诊断-时间 文件夹和 .zip，一起发回去）
echo.
echo [*] 开始采集，大概 1-3 分钟，中途别关窗口...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp040HX诊断.ps1"
set "RC=%ERRORLEVEL%"
echo.
if errorlevel 1 (
  echo.
  echo [X] 采集脚本返回了错误码 %ERRORLEVEL% —— 报告可能没生成完整,
  echo     请把窗口里最后几行拍给经销商
) else (
  echo.
  echo [OK] 采集结束，报告已生成（退出码 0）
)
echo.
pause
rem 2026-10-01b（审查）：把真实退出码传给调用方（原来 goto :eof 恒返回 0）
exit /b %RC%

:ask
echo ==============================================================
echo   CMP 40HX 诊断采集   （只读，不改任何设置）
echo ==============================================================
echo   这台机器上会做：
echo     1) 读一遍显卡/显示/驱动/注册表/服务状态（只看不写）
echo     2) 读一键包的日志、ESP 上的解锁固件、固件启动项
echo     3) 读最近的开机事件时间线（用来定位"黑屏 1-2 分钟"卡在哪一步）
echo     4) 把结果写到桌面：40HX诊断报告-机器名-时间.txt
echo.
echo   不会做：不改注册表、不写 EFI/NVRAM、不加载驱动、不停/起反作弊
echo.
echo [*] 正在申请管理员权限（会弹 UAC + 一个新的黑窗口）
echo.
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
goto :eof

:nops1
echo ============================================================
echo  [注意] 没找到 40HX诊断.ps1
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
