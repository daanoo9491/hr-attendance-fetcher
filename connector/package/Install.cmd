@echo off
rem ZKT Connector - double-click to install or update (asks for administrator permission).
if not exist "%~dp0scripts\install.ps1" goto notextracted
net session >nul 2>&1
if errorlevel 1 goto elevate
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" & echo. & pause & exit /b

:elevate
echo Asking for administrator permission...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
exit /b

:notextracted
echo.
echo  Please extract the ZIP first:
echo    1. Right-click the downloaded ZIP file and choose "Extract All..."
echo    2. Open the extracted folder and double-click Install.cmd again.
echo.
pause
exit /b 1