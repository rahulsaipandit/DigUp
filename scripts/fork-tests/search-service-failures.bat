@echo off
rem DOWNSTREAM-FORK (2026-11-17): the real search-service answering the failed-files questions (no model needed). See README.md.
rem Needs the helper built first: swift-tests.bat (or `swift build --product digup`).
call "%~dp0env.bat"
python "%~dp0search-service-failures.py"
exit /b %ERRORLEVEL%
