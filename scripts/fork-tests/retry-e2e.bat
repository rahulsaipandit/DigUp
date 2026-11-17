@echo off
rem DOWNSTREAM-FORK (2026-11-17): retrying failed files with the real model. See README.md.
rem Needs the model files in %MODELS% (digup download-model --to ...) and the helper built.
call "%~dp0env.bat"
set "DIGUP_MODELS=%MODELS%"
python "%~dp0retry-e2e.py"
exit /b %ERRORLEVEL%
