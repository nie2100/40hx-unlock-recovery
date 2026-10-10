@echo off
rem Copyright 2026 nie2100 - All rights reserved; redistribution or resale not permitted.
rem Upstream MIT parts: CMP40HX-Unlock by PZH1gdmu / CMP40HX-Unlock-OnlyEFI by BardKing-CN.
rem 2026-10-08: 包根入口 —— 转发到 工具-测试与修复\查GSP.cmd（默认：体检 + 条件具备就自动写 GSP 开关；/readonly 才纯只读）
chcp 936 >nul
title 40HX GSP 体检（默认自动修；/readonly 只读）
if not exist "%~dp0工具-测试与修复\查GSP.cmd" (
  echo [!] 找不到 工具-测试与修复\查GSP.cmd
  echo     请保持包目录完整：GSP体检.cmd 必须和 工具-测试与修复\ 在同一层目录。
  if not "%NO_PAUSE%"=="1" pause >nul
  exit /b 1
)
echo ============================================================
echo   CMP 40HX  GSP（GPU 固件）体检      默认：体检 + 条件具备就自动修
echo     跑完会自动打开报告（记事本）
echo   只是不想让它写注册表（纯只读）: GSP体检.cmd /readonly
echo   说明文档: 工具-测试与修复\查GSP-怎么用.txt
echo ============================================================
echo.
call "%~dp0工具-测试与修复\查GSP.cmd" %*
