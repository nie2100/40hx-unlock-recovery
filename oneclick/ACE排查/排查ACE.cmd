@echo off
chcp 936 >nul
title ACE / CMP40HX 排查采集
cd /d "%~dp0"
echo ============================================================
echo   ACE 初始化失败 / 一键解锁包 Gen2  —— 现场排查采集
echo ============================================================
echo.
echo   1) 报告会写到你的桌面: ACE排查报告-电脑名-时间.txt
echo   2) 只读采集，不改任何东西（约 20 秒）
echo   3) 想顺手修复，就这样跑:   排查ACE.cmd -Fix
echo      （-Fix 只会做三件事：ACE-BOOT 启动类型改回 System、启动没在跑的 ACE-BOOT、
echo        把你桌面会话里的 ACE 托盘重启一次）
echo.
echo   需要管理员权限：会弹一次 UAC，请点“是”
echo ------------------------------------------------------------
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ACE-Diag.ps1" %*
echo.
echo ------------------------------------------------------------
echo   提权后的那个窗口跑完会自动关；报告在桌面，用记事本打开即可。
echo   把报告整份发回给 Hermes。
echo.
pause
