@echo off
setlocal
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
)

set "INSTALL_EXIT=%errorlevel%"
if not "%INSTALL_EXIT%"=="0" echo Setup failed with exit code %INSTALL_EXIT%.

echo.
pause
exit /b %INSTALL_EXIT%
