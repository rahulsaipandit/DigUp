@echo off
rem DOWNSTREAM-FORK (2026-11-17): builds the Tauri shell (debug) into TEST_ROOT\shell-target, for run.bat. See ../README.md.
call "%~dp0..\env.bat"
cd /d "%REPO%\shell\src-tauri"
cargo build --target-dir "%TEST_ROOT%\shell-target"
exit /b %ERRORLEVEL%
