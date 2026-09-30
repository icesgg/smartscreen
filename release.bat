@echo off
REM release.bat - one click: bump the version, close the app, build, publish,
REM refresh dist\ + SmartScreen-desktop.zip, commit + push, relaunch the app.
REM
REM All the logic lives in tools\release.ps1 (Korean messages need UTF-8 BOM,
REM which a .bat cannot carry). This file only launches it so it can be
REM double-clicked and stays open at the end.
REM
REM   release.bat              bump patch (1.1.1 -> 1.1.2), asks for release notes
REM   release.bat 1.2.0        set this exact version
REM   release.bat -NoGit       skip commit/push
REM   release.bat -DryRun      build only, no publish/commit, version restored
REM
REM ASCII only: cmd.exe reads .bat in the system codepage.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\release.ps1" %*
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo [!] failed (exit %RC%) - see the step marked [X] above
pause
exit /b %RC%
