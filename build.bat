@echo off
REM SmartScreen Build Script
REM Requires: Visual Studio 2022 with C++ Desktop workload
REM Run from "Developer Command Prompt for VS 2022"

echo === SmartScreen Build ===

if not exist build mkdir build
cd build

cmake .. -G "Visual Studio 17 2022" -A x64
if errorlevel 1 (
    echo.
    echo [ERROR] CMake configuration failed.
    echo Make sure CMake is installed and in PATH.
    pause
    exit /b 1
)

cmake --build . --config Release
if errorlevel 1 (
    echo.
    echo [ERROR] Build failed.
    pause
    exit /b 1
)

echo.
echo === Build Successful ===
echo Output: build\Release\SmartScreen.exe
echo.
pause
