@echo off
REM publish.bat - upload build\SmartScreen.exe to the server as a new release.
REM
REM Reads SUPABASE_URL / SUPABASE_ANON_KEY from .env (not committed; see
REM .env.example). Both exes must come from the same do_build.bat run, because
REM Publish.exe carries the version number it was compiled with
REM (client/version.h) and stamps that onto whatever SmartScreen.exe it is given.
REM
REM Usage: publish.bat [--notes "what changed"] [--channel beta] [--force]
REM        publish.bat --list [--platform mac]
REM        publish.bat --deactivate 1.2.3 [--platform mac]
REM
REM Mac build (the zip comes from CI, see release-mac.bat; --platform must be
REM the first argument so build\SmartScreen.exe is not added):
REM        publish.bat --platform mac --file SmartScreen-mac.zip [--notes "..."]
REM
REM ASCII only: cmd.exe reads .bat in the system codepage.

setlocal
set SRC=%~dp0

if not exist "%SRC%.env" (
    echo [!] .env not found. Copy .env.example to .env and fill it in.
    exit /b 1
)
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%SRC%.env") do set "%%a=%%b"
if "%SUPABASE_URL%"=="" ( echo [!] SUPABASE_URL missing in .env & exit /b 1 )
if "%SUPABASE_ANON_KEY%"=="" ( echo [!] SUPABASE_ANON_KEY missing in .env & exit /b 1 )

if not exist "%SRC%build\Publish.exe" (
    echo [!] build\Publish.exe not found. Run do_build.bat first.
    exit /b 1
)

REM One-line ifs, not ( ) blocks: inside a block %ERRORLEVEL% is expanded
REM before Publish.exe runs, so the block always returned 0; and %* may hold
REM notes with parentheses, which would end a block early.
set "MODE="
if "%~1"=="--list" set "MODE=--list"
if "%~1"=="--deactivate" set "MODE=--deactivate"
if defined MODE "%SRC%build\Publish.exe" %MODE% "%SUPABASE_URL%" "%SUPABASE_ANON_KEY%" %2 %3 %4
if defined MODE exit /b %ERRORLEVEL%

REM --platform first: pass everything through; the file comes from --file.
if /i "%~1"=="--platform" set "PASSTHRU=1"
if defined PASSTHRU "%SRC%build\Publish.exe" "%SUPABASE_URL%" "%SUPABASE_ANON_KEY%" %*
if defined PASSTHRU exit /b %ERRORLEVEL%

if not exist "%SRC%build\SmartScreen.exe" (
    echo [!] build\SmartScreen.exe not found. Run do_build.bat first.
    exit /b 1
)
"%SRC%build\Publish.exe" "%SUPABASE_URL%" "%SUPABASE_ANON_KEY%" "%SRC%build\SmartScreen.exe" %*
exit /b %ERRORLEVEL%
