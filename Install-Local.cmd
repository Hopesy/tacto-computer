@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Tacto.ps1" -Action Install -Mode Local
echo.
pause
