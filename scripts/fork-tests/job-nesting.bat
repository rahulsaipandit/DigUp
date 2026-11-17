@echo off
rem DOWNSTREAM-FORK (2026-11-17): does the decode worker start inside a parent job object like the shell's? See job-nesting.py and README.md.
rem Runs each variant of the parent job in its own process. The shell's is "kill+ui". Needs the helper built and a PDF (TEST_PDF).
call "%~dp0env.bat"
set "FAILED=0"
for %%V in (none kill ui kill+ui) do (
  python "%~dp0job-nesting.py" %%V
  if errorlevel 1 set "FAILED=1"
)
exit /b %FAILED%
