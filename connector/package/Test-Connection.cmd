@echo off
rem ZKT Connector - reads the attendance machine once and shows what it finds.
rem Read-only: nothing is uploaded and nothing on the machine is changed.
net session >nul 2>&1
if errorlevel 1 goto elevate
cd /d "%~dp0"
where node >nul 2>&1 && goto run
if exist "%ProgramFiles%\nodejs\node.exe" set "PATH=%ProgramFiles%\nodejs;%PATH%" & goto run
echo.
echo  Node.js is not installed yet. Run Install.cmd first (it installs Node.js).
echo.
pause
exit /b 1

:run
node src\read-device.js & echo. & pause & exit /b

:elevate
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
exit /b