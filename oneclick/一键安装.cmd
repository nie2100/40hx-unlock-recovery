@echo off
chcp 936 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title CMP 40HX 一键安装

rem 已提权的那一份（带 elevated 标记）直接干活，不再问第二次
echo %* | findstr /i "elevated" >nul && goto run

net session >nul 2>&1
if errorlevel 1 goto ask

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-40HXUnlock.ps1" -Mode Install -Yes
echo.
echo 安装退出码 = %ERRORLEVEL%   (0 表示步骤全部成功)
echo.
echo ============================================================
echo   现在请【完全关机】再开机（必须，不是重启）：算力解锁靠每次开机的解锁固件生效；
echo   重启清不掉显卡残留状态，残留状态不对 = 开机黑屏一段时间 + 设备管理器代码 43；
echo   做法：开始菜单-关机，最好拔电 10 秒再开机
echo   开机后双击 状态自检.bat 看结论；出问题看 排查指引.md
echo   上面若列了"重启前请先处理"的事项，请先处理再重启
echo   回滚见 README-使用说明.md
echo ============================================================
echo.
pause
goto :eof

:ask
echo ==============================================================
echo   CMP 40HX 算力解锁 + PCIe Gen2  一键安装 / 迁移
echo ==============================================================
echo   将要做的改动：
echo     1) 两个内核驱动复制到 System32\drivers 并注册服务
echo     2) OnlyEFI 解锁固件写入 EFI 分区（原文件自动备份到 backup\）
echo     3) 写入固件启动项 "40HX Unlock" 并排到启动顺序第一位
echo     4) 注册开机任务：每次开机自动落地 PCIe Gen2 + 处理腾讯 ACE
echo.
echo   随时可回滚：
echo     powershell -ExecutionPolicy Bypass -File "%~dp0Install-40HXUnlock.ps1" -Mode Uninstall -Yes
echo.
echo   想先只看不改：Install-40HXUnlock.ps1 -Mode Check
echo.
set /p ANS=回车开始安装，输入 n 退出: 
if /i "%ANS%"=="n" goto quit
echo.
echo [*] 正在申请管理员权限：会弹 UAC 和一个新的黑窗口，装完按任意键关闭
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
goto :eof

:quit
echo 已取消，什么都没改。
pause
