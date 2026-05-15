@echo off
setlocal

cd /d "%~dp0"
python scripts\build_windows_release.py
set BUILD_EXIT_CODE=%ERRORLEVEL%

if %BUILD_EXIT_CODE% EQU 0 (
    echo.
    echo Build completed successfully.
    echo Release executable: build\windows\x64\runner\Release\hakurei_terminal.exe
) else (
    echo.
    echo Build failed with exit code %BUILD_EXIT_CODE%.
)

pause
exit /b %BUILD_EXIT_CODE%
