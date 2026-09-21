@echo off
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
