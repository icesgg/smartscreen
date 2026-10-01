@echo off
REM release-mac.bat - publish only the Mac build of a version, or retry the
REM Mac step after release.bat printed "[X] Mac: ...".
REM
REM The Mac app cannot be built on this PC. GitHub Actions builds the pushed
REM commit (.github/workflows/mac.yml); this waits for that run (or starts
REM one), downloads SmartScreen-mac.zip, checks the version inside it, copies
REM it to the repo root and runs build\Publish.exe --platform mac (browser
REM login, table mac_releases). The Windows release is never touched.
REM All the logic lives in tools\release.ps1 (-MacOnly).
REM
REM   release-mac.bat 1.1.8                 the number in client/version.h
REM   release-mac.bat 1.1.8 -DryRun         wait, download and check only
REM   release-mac.bat 1.1.8 -Notes "..."    default: the notes of Windows 1.1.8
REM
REM Needs the GitHub CLI (https://cli.github.com) and "gh auth login" once.
REM HEAD must be pushed, and build\Publish.exe must be built from the same
REM client/version.h. The server needs the mac_releases table: run
REM supabase/mac_releases.sql once in the Supabase SQL Editor. Without it this
REM stops at once, before waiting for CI (except with -DryRun).
REM
REM ASCII only: cmd.exe reads .bat in the system codepage.

if "%~1"=="" (
    echo usage: release-mac.bat VERSION    for example: release-mac.bat 1.1.8
    pause
    exit /b 2
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\release.ps1" -MacOnly -Version %*
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo [!] failed (exit %RC%) - see the step marked [X] above
pause
exit /b %RC%
