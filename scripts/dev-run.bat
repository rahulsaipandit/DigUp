@echo off
rem DOWNSTREAM-FORK: Windows dev runner (the upstream scripts/dev-run.sh is macOS only).
rem
rem Sets up the environment from "Development environment" in docs/design.md, builds the digup CLI if asked, and runs it
rem against a throwaway index under D:\Temp (never the real index).
rem
rem   scripts\dev-run.bat --help
rem   scripts\dev-run.bat status
rem   set BUILD=1 && scripts\dev-run.bat --help     (build first; unset BUILD to skip)
rem
rem Every argument goes to digup.exe after "--index %INDEX%". Override INDEX or MODELS in the environment to change them.
setlocal

if not defined INDEX  set "INDEX=D:\Temp\digup-dev-index"
if not defined MODELS set "MODELS=D:\Users\rahul\AppData\Local\DigUp\Models"

set "REPO=%~dp0.."
set "SW=C:\Users\rahul\AppData\Local\Programs\Swift"
set "VCVARS=D:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

set "PATH=C:\Program Files (x86)\Microsoft Visual Studio\Installer;%SW%\Runtimes\6.4.1\usr\bin;%SW%\Toolchains\6.4.1+Asserts\usr\bin;%PATH%"
call "%VCVARS%" >nul
if errorlevel 1 exit /b 1

pushd "%REPO%" || exit /b 1
set "REPO=%CD%"
set "PATH=%REPO%\Vendor\llama\lib;%REPO%\Vendor\pdfium\bin;%REPO%\Vendor\ffmpeg\bin;%PATH%"
set "DIGUP_MODELS=%MODELS%"
set "DIGUP_BACKENDS=%REPO%\Vendor\llama\lib"

if defined BUILD (
  swift build --product digup
  set "RC=%ERRORLEVEL%"
  rem swift build deletes the tracked Package.resolved on Windows.
  git restore Package.resolved
  if not "%RC%"=="0" (popd & exit /b %RC%)
)

if not exist ".build\debug\digup.exe" (
  echo .build\debug\digup.exe not found. Run again with BUILD=1 set.
  popd & exit /b 1
)

".build\debug\digup.exe" --index "%INDEX%" %*
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
