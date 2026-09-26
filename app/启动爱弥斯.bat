@echo off
rem 爱弥斯 v2 桌面宠 —— 双击本文件启动（会短暂出现一个黑窗口）
cd /d "%~dp0"
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0AemeathPet.ps1"
exit
