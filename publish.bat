@echo off
REM publish.bat - upload build\SmartScreen.exe to the server as a new release.
REM
REM Reads SUPABASE_URL / SUPABASE_ANON_KEY from .env (not committed; see
REM .env.example). Both exes must come from the same do_build.bat run, because
REM Publish.exe carries the version number it was compiled with
REM (client/version.h) and stamps that onto whatever SmartScreen.exe it is given.
REM
REM Usage: publish.bat [--notes "what changed"] [--channel beta] [--force]
REM        publish.bat --list
REM        publish.bat --deactivate 1.2.3
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

if "%~1"=="--list" (
    "%SRC%build\Publish.exe" --list "%SUPABASE_URL%" "%SUPABASE_ANON_KEY%"
    exit /b %ERRORLEVEL%
)
if "%~1"=="--deactivate" (
    "%SRC%build\Publish.exe" --deactivate "%SUPABASE_URL%" "%SUPABASE_ANON_KEY%" %2
    exit /b %ERRORLEVEL%
)

if not exist "%SRC%build\SmartScreen.exe" (
    echo [!] build\SmartScreen.exe not found. Run do_build.bat first.
    exit /b 1
)
"%SRC%build\Publish.exe" "%SUPABASE_URL%" "%SUPABASE_ANON_KEY%" "%SRC%build\SmartScreen.exe" %*
exit /b %ERRORLEVEL%
