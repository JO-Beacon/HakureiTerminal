@echo off
setlocal

cd /d "%~dp0"

echo Starting HakureiTerminal Flutter Windows client...
flutter run -d windows
set RUN_EXIT_CODE=%ERRORLEVEL%

if %RUN_EXIT_CODE% NEQ 0 (
    echo.
    echo Flutter run failed with exit code %RUN_EXIT_CODE%.
    pause
)

exit /b %RUN_EXIT_CODE%
