@echo off
chcp 936 >nul
title 40HX - ACE 反作弊体检/修复
cd /d "%~dp0"
set "PSARGS="
if /I "%~1"=="/fix" set "PSARGS=-Fix"
rem 2026-10-04: /fix -retirefile（或 -retirefile）= 另把 ThrottleStop 彻底退役（删服务 + .sys 挪进备份目录）
if /I "%~1"=="/fix" if /I "%~2"=="-retirefile" set "PSARGS=-Fix -RetireFile"
if /I "%~1"=="-retirefile" set "PSARGS=-Fix -RetireFile"
rem 2026-10-01b（第五轮建议③）：/acefirst 没带 on|off 时，原来会传一个"没有值的 -AceFirst"→ PowerShell 参数绑定直接报错，
rem   脚本里的用法提示反而看不到。这里补个占位符，让脚本自己打印"用法错误: -AceFirst 只能是 on / off"。
if /I "%~1"=="/acefirst" if "%~2"=="" ( set "PSARGS=-AceFirst ?" ) else ( set "PSARGS=-AceFirst %~2" )
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ACE修复.ps1" %PSARGS%
if not "%NO_PAUSE%"=="1" pause >nul
