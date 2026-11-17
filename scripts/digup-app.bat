@echo off
rem DOWNSTREAM-FORK: starts the installed DigUp app with its index and models on D: (its default is %LOCALAPPDATA% on C:).
rem
rem   scripts\digup-app.bat                              the folders you chose in the app's own setup and Settings
rem   scripts\digup-app.bat --roots "D:\a;D:\b"          these folders instead (separated by ;)
rem
rem Set APP to the DigUp.exe if it is not where the installer usually puts it, INDEX or MODELS to use other folders.
rem A different INDEX (and SETTINGS) gives a separate set of folders and results.
setlocal

if not defined INDEX    set "INDEX=D:\Users\rahul\AppData\Local\DigUp\index"
if not defined MODELS   set "MODELS=D:\Users\rahul\AppData\Local\DigUp\Models"
if not defined SETTINGS set "SETTINGS="

if not defined APP (
  for %%P in ("D:\Users\rahul\AppData\Local\DigUp\DigUp.exe" "%LOCALAPPDATA%\DigUp\DigUp.exe" "%LOCALAPPDATA%\Programs\DigUp\DigUp.exe") do (
    if not defined APP if exist %%P set "APP=%%~P"
  )
)
if not defined APP (echo DigUp.exe not found. Set APP to its path. & exit /b 1)

if not exist "%INDEX%" mkdir "%INDEX%"
if defined SETTINGS (
  start "" "%APP%" --index "%INDEX%" --models "%MODELS%" --settings "%SETTINGS%" %*
) else (
  start "" "%APP%" --index "%INDEX%" --models "%MODELS%" %*
)
