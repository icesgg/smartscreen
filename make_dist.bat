@echo off
REM make_dist.bat - rebuild the distribution folder (dist\).
REM
REM Copying these by hand is how SmartScreen-test\ ended up shipping a README
REM that no longer matched the code. The exes must come from the same build as
REM the product, so they are copied from build\ every time.
REM
REM dist\README.txt is deliberately NOT touched. It is the tracked original
REM (see .gitignore) and having no second copy is what keeps it from drifting.
REM
REM ASCII only: cmd.exe reads .bat in the system codepage, so UTF-8 Korean here
REM gets mangled into stray commands.

setlocal
set SRC=%~dp0
set OUT=%SRC%dist

if not exist "%SRC%build\SmartScreen.exe" (
    echo [!] build\SmartScreen.exe not found. Run do_build.bat first.
    exit /b 1
)

if not exist "%OUT%\ios\SSBeacon" mkdir "%OUT%\ios\SSBeacon"

for %%F in (SmartScreen.exe BtCheck.exe AdvScan.exe ProbeScan.exe) do (
    copy /Y "%SRC%build\%%F" "%OUT%\%%F" >nul
    if errorlevel 1 exit /b 1
    echo   %%F
)

copy /Y "%SRC%ios\SSBeacon\SSBeaconApp.swift" "%OUT%\ios\SSBeacon\" >nul
if errorlevel 1 exit /b 1
copy /Y "%SRC%ios\SSBeacon\README.md" "%OUT%\ios\SSBeacon\" >nul
if errorlevel 1 exit /b 1
echo   ios\SSBeacon\

REM The threshold has to be measured on the machine it runs on, and chapter 4
REM of README.txt sends the reader to this script to do it. Shipping it is what
REM keeps that instruction true on a PC that has no checkout.
copy /Y "%SRC%tools\rssi-threshold.ps1" "%OUT%\" >nul
if errorlevel 1 exit /b 1
echo   rssi-threshold.ps1

REM Produced by running BtCheck on the user's PC; must not ship in the bundle.
if exist "%OUT%\BtCheck_result.txt" del "%OUT%\BtCheck_result.txt"

echo.
echo dist\ ready  (README.txt left alone)
endlocal
