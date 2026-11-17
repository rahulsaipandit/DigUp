@echo off
rem DOWNSTREAM-FORK (2026-11-17): the failed-files list in the REAL shell window, with the real helpers and the real model. See ../README.md.
rem   1. prep.py      a folder with a bad picture, an index of it, a good file marked failed, a settings file
rem   2. the shell    started with everything on D: (its settings, WebView2's profile) and WebView2's debugging port 9333
rem   3. drive.mjs    opens Settings -> Folders -> Review, clicks Retry all, waits, reads the page; screenshots go to %TEST_ROOT%\shell-e2e\shots
rem   4. check.py     the index afterwards
rem Needs: the model files (MODELS), the helper built (swift build --product digup), the shell built (build-shell.bat), Node 22+.
rem It opens a real DigUp window on the desktop for a minute. It never touches the real DigUp settings or index.
call "%~dp0..\env.bat"
set "DIGUP_MODELS=%MODELS%"
set "ROOT=%TEST_ROOT%\shell-e2e"
set "SHELL_EXE=%TEST_ROOT%\shell-target\debug\digup-shell.exe"
if not exist "%SHELL_EXE%" (echo the shell is not built: run build-shell.bat first & exit /b 2)
taskkill /IM digup-shell.exe /F /T >nul 2>&1

python "%~dp0prep.py"
if errorlevel 1 (echo prep failed & exit /b 1)
mkdir "%ROOT%\shots" 2>nul

rem WebView2's own profile on D: (it would go under C:\Users\...\AppData\Local\com.abdurrahim.DigUp), and its debugging port.
set "WEBVIEW2_USER_DATA_FOLDER=%ROOT%\webview"
set "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9333"
start "" /B "%SHELL_EXE%" --helper "%DIGUP%" --index "%ROOT%\index" --settings "%ROOT%\settings.json" --models "%MODELS%" --hotkey "Ctrl+Alt+Shift+F11" > "%ROOT%\shell.log" 2>&1

node "%~dp0drive.mjs" "%ROOT%\shots"
set "DRIVE=%ERRORLEVEL%"
taskkill /IM digup-shell.exe /F /T >nul 2>&1
rem (not `timeout`: Git's coreutils one is ahead of Windows' on PATH) wait for the helpers to exit and release the database
ping -n 4 127.0.0.1 >nul
python "%~dp0check.py"
set "CHECK=%ERRORLEVEL%"
echo drive=%DRIVE% check=%CHECK%
if not "%DRIVE%%CHECK%"=="00" exit /b 1
exit /b 0
