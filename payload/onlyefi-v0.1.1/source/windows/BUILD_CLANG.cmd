@echo off
setlocal
cd /d "%~dp0"
where clang.exe >nul 2>&1 || (echo clang.exe not found & exit /b 2)
where lld-link.exe >nul 2>&1 || (echo lld-link.exe not found & exit /b 3)

clang --target=x86_64-pc-windows-msvc -O2 -ffreestanding -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -c CMP40HXGen2_prod.c -o CMP40HXGen2_prod.obj || exit /b 10
lld-link /entry:entry /subsystem:console,6.01 /nodefaultlib /machine:x64 /dynamicbase /highentropyva:no /nxcompat /out:CMP40HXGen2.exe CMP40HXGen2_prod.obj || exit /b 11

echo Built CMP40HXGen2.exe
