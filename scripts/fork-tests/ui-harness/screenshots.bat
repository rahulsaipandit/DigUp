@echo off
rem DOWNSTREAM-FORK (2026-11-17): a picture of the real Settings page (with a mock backend, see make_harness.py) in each state of the
rem failed-files list, taken with headless Edge: none, count, open, retried, many. They go to %TEST_ROOT%\ui-harness\shots. See ../README.md.
call "%~dp0..\env.bat"
python "%~dp0make_harness.py"
if errorlevel 1 exit /b 1
set "SHOTS=%TEST_ROOT%\ui-harness\shots"
mkdir "%SHOTS%" 2>nul
for %%S in (none count open retried many) do (
  "%EDGE%" --headless=new --disable-gpu --hide-scrollbars --window-size=860,980 --virtual-time-budget=6000 --screenshot="%SHOTS%\%%S.png" "file:///%TEST_ROOT:\=/%/ui-harness/harness.html?tab=folders&s=%%S" >nul 2>&1
)
dir /b "%SHOTS%"
