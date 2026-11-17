@echo off
rem DOWNSTREAM-FORK (2026-11-17): shared setup for the fork's test scripts in this folder (Windows). See README.md.
rem Every value has a default for this machine; set the variable before calling a script to use another.
rem   REPO          the repository (the default: two folders up from here)
rem   TEST_ROOT     where the scripts put what they make (the default is on D:, as CLAUDE.md asks)
rem   SWIFT_HOME, SWIFT_VERSION   the Swift toolchain (installed, not on PATH by default)
rem   VCVARS, VSINSTALLER         MSVC's environment script, and the folder with vswhere.exe it needs on PATH
rem   CARGO_BIN     rustup's bin folder
rem   MODELS        the model files (EmbeddingGemma 2), for the scripts that run the model
if not defined REPO for %%I in ("%~dp0..\..") do set "REPO=%%~fI"
if not defined TEST_ROOT set "TEST_ROOT=D:\Temp\digup-fork-tests"
if not defined SWIFT_HOME set "SWIFT_HOME=C:\Users\rahul\AppData\Local\Programs\Swift"
if not defined SWIFT_VERSION set "SWIFT_VERSION=6.4.1"
if not defined VCVARS set "VCVARS=D:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not defined VSINSTALLER set "VSINSTALLER=C:\Program Files (x86)\Microsoft Visual Studio\Installer"
if not defined CARGO_BIN set "CARGO_BIN=%USERPROFILE%\.cargo\bin"
if not defined MODELS set "MODELS=D:\Users\rahul\AppData\Local\DigUp\Models"
if not defined EDGE set "EDGE=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
set "DIGUP=%REPO%\.build\debug\digup.exe"
set "DIGUP_BACKENDS=%REPO%\Vendor\llama\lib"
set "PATH=%VSINSTALLER%;%SWIFT_HOME%\Runtimes\%SWIFT_VERSION%\usr\bin;%SWIFT_HOME%\Toolchains\%SWIFT_VERSION%+Asserts\usr\bin;%REPO%\Vendor\llama\lib;%REPO%\Vendor\pdfium\lib;%REPO%\Vendor\pdfium\bin;%REPO%\Vendor\ffmpeg\bin;%CARGO_BIN%;%PATH%"
call "%VCVARS%" >nul
if not exist "%TEST_ROOT%" mkdir "%TEST_ROOT%"
