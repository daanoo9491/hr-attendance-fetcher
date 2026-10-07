@echo off
rem ZKT Connector - start (or restart) the connector in the background
if not exist "%~dp0scripts\service.ps1" goto missing
net session >nul 2>&1
if errorlevel 1 goto elevate
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\service.ps1" -Action Start & echo. & pause & exit /b

:elevate
echo Asking for administrator permission...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
exit /b

:missing
echo scripts\service.ps1 not found. Extract the whole ZIP first, then try again.
pause
exit /b 1