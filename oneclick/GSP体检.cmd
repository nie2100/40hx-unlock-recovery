@echo off
rem 2026-10-04: 包根入口 —— 转发到 工具-测试与修复\查GSP.cmd（默认只读诊断；加 /fix 才写 GSP 开关）
chcp 936 >nul
title 40HX GSP 体检（只读；/fix 才写注册表）
if not exist "%~dp0工具-测试与修复\查GSP.cmd" (
  echo [!] 找不到 工具-测试与修复\查GSP.cmd
  echo     请保持包目录完整：GSP体检.cmd 必须和 工具-测试与修复\ 在同一层目录。
  if not "%NO_PAUSE%"=="1" pause >nul
  exit /b 1
)
echo ============================================================
echo   CMP 40HX  GSP（GPU 固件）体检      默认只读
echo     跑完会自动打开报告（记事本）
echo   要顺手修复（GSP 没开时写 EnableGpuFirmware=1）: GSP体检.cmd /fix
echo   说明文档: 工具-测试与修复\查GSP-怎么用.txt
echo ============================================================
echo.
call "%~dp0工具-测试与修复\查GSP.cmd" %*
