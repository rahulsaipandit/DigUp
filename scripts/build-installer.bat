@echo off
rem DOWNSTREAM-FORK: builds DigUp's Windows installer on this machine (scripts/package-windows.sh, with the environment it needs).
rem
rem   scripts\build-installer.bat
rem
rem Output: shell\src-tauri\target\release\bundle\nsis\DigUp_<version>_x64-setup.exe
rem Needs Vendor\ filled already (fetch-vendor.sh, build-llama.sh, build-decode-rs.sh, build-ffmpeg.sh). See "Development
rem environment" in docs/design.md.
setlocal

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

"%GITBASH%" -c "scripts/package-windows.sh"
set "RC=%ERRORLEVEL%"

rem swift build deletes the tracked Package.resolved on Windows.
git restore Package.resolved
popd
exit /b %RC%
