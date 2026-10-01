@echo off
REM CMake finds header dependencies by matching the /showIncludes prefix as
REM bytes. On this PC cl.exe prints it in Korean even with VSLANG=1033 (no
REM English language pack), and the bytes depend on the console codepage:
REM release.ps1 runs with a UTF-8 console, a hand-run cmd uses CP949. When the
REM codepage differs from the one the prefix was cached under, every object
REM compiled in that run gets an empty .obj.d, and from then on a header-only
REM change (version.h) rebuilds nothing. A stale exe shipped twice that way:
REM 1.1.0 (2026-09-30) and 1.1.8 (2026-10-01, update.cpp still said 1.1.7).
REM VSLANG stays in case an English pack is ever installed.
set VSLANG=1033
REM Self-heal: an empty .obj.d means dependency tracking is broken for that
REM object, so configure from scratch (rebuilds everything once, under the
REM codepage of this run). release.ps1 also wipes the cache before every
REM release build and then checks the exe itself.
set "SS_BUILD=c:\work\smartscreen\build"
set SS_RESET=
if exist "%SS_BUILD%\CMakeFiles" (
  for /r "%SS_BUILD%\CMakeFiles" %%f in (*.obj.d) do (
    if "%%~zf"=="0" set SS_RESET=1
  )
)
if defined SS_RESET (
  echo RESET_CMAKE_CACHE empty .obj.d found - header dependencies were not tracked, configuring from scratch
  rd /s /q "%SS_BUILD%\CMakeFiles"
  del /q "%SS_BUILD%\CMakeCache.txt"
)
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64
if errorlevel 1 (echo VCVARS_FAILED & exit /b 1)
echo VCVARS_OK
if not exist "c:\work\smartscreen\build" mkdir "c:\work\smartscreen\build"
cd /d "c:\work\smartscreen\build"
"C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" .. -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release
if errorlevel 1 (echo CMAKE_FAILED & exit /b 1)
echo CMAKE_OK
nmake
if errorlevel 1 (echo NMAKE_FAILED & exit /b 1)
echo BUILD_SUCCESS
