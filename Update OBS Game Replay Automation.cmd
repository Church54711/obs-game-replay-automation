@echo off
setlocal
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" %*
)

set "UPDATE_EXIT=%errorlevel%"
if not "%UPDATE_EXIT%"=="0" echo Update failed with exit code %UPDATE_EXIT%.

echo.
pause
exit /b %UPDATE_EXIT%
