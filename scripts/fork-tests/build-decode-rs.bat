@echo off
rem DOWNSTREAM-FORK (2026-11-17): builds the Rust readers (decode-rs) into Vendor\decode with the MSVC environment set up, by running
rem scripts/build-decode-rs.sh in Git's bash. It does nothing when the library is already built for the current sources. Run it after
rem a change to decode-rs, before swift-tests.bat (the Swift build links the library). See README.md.
call "%~dp0env.bat"
cd /d "%REPO%"
if not defined GIT_BASH set "GIT_BASH=D:\Program Files\Git\bin\bash.exe"
"%GIT_BASH%" scripts/build-decode-rs.sh
exit /b %ERRORLEVEL%
