@echo off
rem DOWNSTREAM-FORK: builds DigUp's Windows installers on this machine (scripts/package-windows.sh, with the environment it needs).
rem
rem   scripts\build-installer.bat local          "DigUp Local": its own install folder and settings, indexes in D:\Temp, built cheaper
rem   scripts\build-installer.bat production     "DigUp": the real app, the permanent index on D:, built as upstream ships it
rem   scripts\build-installer.bat both           one after the other
rem
rem Each installer is copied to scripts\scratch\ (git-ignored): the next build of the same profile deletes the bundle folder it came from.
rem Needs Vendor\ filled already (fetch-vendor.sh, build-llama.sh, build-decode-rs.sh, build-ffmpeg.sh). See "Development
rem environment" in docs/design.md.
setlocal

set "PROFILE=%~1"
if /i "%PROFILE%"=="both" goto :both
if /i "%PROFILE%"=="local" goto :setup
if /i "%PROFILE%"=="production" goto :setup
echo usage: scripts\build-installer.bat local^|production^|both
exit /b 2

:both
call "%~f0" local
if errorlevel 1 exit /b 1
call "%~f0" production
exit /b %ERRORLEVEL%

:setup
rem The folders each build defaults to (compiled into the shell; --index and --models still win). They are paths on this
rem machine: an installer built here is for this machine.
set "DIGUP_BUILD_MODELS=D:\Users\rahul\AppData\Local\DigUp\Models"
if /i "%PROFILE%"=="local" goto :local

set "DIGUP_PROFILE=production"
set "DIGUP_BUILD_INDEX=D:\Users\rahul\AppData\Local\DigUp\index"
set "BUNDLE_DIR=shell\src-tauri\target\release\bundle\nsis"
goto :environment

:local
set "DIGUP_PROFILE=local"
set "DIGUP_BUILD_INDEX=D:\Temp\digup-dev-index"
rem Cheaper to build: thin LTO and 16 code-generation units instead of full LTO and one (see shell/src-tauri/Cargo.toml), and
rem zlib in the installer (package-windows.sh). The result is a little bigger and slower, which a trial app does not mind. It gets
rem its own target folder: a changed profile makes cargo rebuild every dependency, so one shared folder would redo them all each
rem time you switched.
set "CARGO_PROFILE_RELEASE_LTO=thin"
set "CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16"
set "CARGO_TARGET_DIR=D:\Temp\digup-shell-target-local"
set "BUNDLE_DIR=D:\Temp\digup-shell-target-local\release\bundle\nsis"

:environment
set "SW=C:\Users\rahul\AppData\Local\Programs\Swift"
set "VS=D:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
set "GITBASH=D:\Program Files\Git\bin\bash.exe"
set "LLAMA_CLONE=D:\Github\llamaCPP-digup"

set "PATH=C:\Program Files (x86)\Microsoft Visual Studio\Installer;%SW%\Runtimes\6.4.1\usr\bin;%SW%\Toolchains\6.4.1+Asserts\usr\bin;C:\Users\rahul\.cargo\bin;%PATH%"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1

pushd "%~dp0.." || exit /b 1

rem Git's bash has its own link.exe ahead of MSVC's on PATH: cargo must use MSVC's.
for /f "delims=" %%L in ('where link.exe') do (
  if not defined MSVC_LINK echo %%L | findstr /i /c:"MSVC" >nul && set "MSVC_LINK=%%L"
)
if not defined MSVC_LINK (echo MSVC link.exe not found & popd & exit /b 1)
set "CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER=%MSVC_LINK%"

rem scripts/notices.py wants this, and a build with LLAMA_SOURCE set does not make it.
if not exist "Vendor\llama.cpp\LICENSE" copy "%LLAMA_CLONE%\LICENSE" "Vendor\llama.cpp\LICENSE" >nul

echo Building the %PROFILE% installer (index %DIGUP_BUILD_INDEX%), started %TIME%
"%GITBASH%" -c "scripts/package-windows.sh"
if errorlevel 1 (set "FAILED=1") else (set "FAILED=")

rem swift build deletes the tracked Package.resolved on Windows.
git restore Package.resolved

if defined FAILED (popd & exit /b 1)
if not exist "scripts\scratch" mkdir "scripts\scratch"
copy /y "%BUNDLE_DIR%\*-setup.exe" "scripts\scratch\" >nul
if errorlevel 1 (echo could not copy the installer & popd & exit /b 1)
echo Copied to %CD%\scripts\scratch, finished %TIME%
popd
exit /b 0
