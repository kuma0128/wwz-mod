@echo off
setlocal
chcp 65001 >nul

set "MOD_SCRIPT=%~dp0WWZ_X90_Offline_Mod.ps1"

if not exist "%MOD_SCRIPT%" goto :not_extracted

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%MOD_SCRIPT%" -Action Verify
set "MOD_EXIT=%ERRORLEVEL%"
echo.
if not "%MOD_EXIT%"=="0" echo [ERROR] Verification did not complete. Check the message above.
pause
exit /b %MOD_EXIT%

:not_extracted
echo [ERROR] Required MOD files were not found.
echo.
echo Do not run this CMD directly inside the ZIP file.
echo Right-click the ZIP, select "Extract All", then run
echo Verify_Mod.cmd from the extracted folder.
echo.
echo Current location: %~dp0
echo No game files were changed.
echo.
pause
exit /b 2
