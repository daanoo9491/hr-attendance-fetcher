@echo off
rem ZKT Connector - double-click to remove it from this PC (asks for administrator permission).
if not exist "%~dp0scripts\uninstall.ps1" goto missing
net session >nul 2>&1
if errorlevel 1 goto elevate
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall.ps1" & echo. & pause & exit /b

:elevate
echo Asking for administrator permission...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
exit /b

:missing
echo scripts\uninstall.ps1 not found. Extract the ZIP first.
pause
exit /b 1