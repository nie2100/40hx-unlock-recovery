@echo off
chcp 936 >nul
title 40HX - ACE ·´×÷±×Ìå¼ì/ÐÞ¸´
cd /d "%~dp0"
set "PSARGS="
if /I "%~1"=="/fix" set "PSARGS=-Fix"
if /I "%~1"=="/acefirst" set "PSARGS=-AceFirst %~2"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ACEÐÞ¸´.ps1" %PSARGS%
if not "%NO_PAUSE%"=="1" pause >nul
