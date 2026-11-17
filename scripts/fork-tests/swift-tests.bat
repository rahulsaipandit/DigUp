@echo off
rem DOWNSTREAM-FORK (2026-11-17): the Swift tests, on Windows. See README.md.
rem   swift-tests.bat              builds the helper, then runs the whole suite twice: with the decode worker off (what a test
rem                                runner gets by default) and with DIGUP_ISOLATE_DECODERS=1 for every read
rem   swift-tests.bat NAME         builds, then runs only the tests whose name matches NAME (for example DecodeIsolationTests)
call "%~dp0env.bat"
cd /d "%REPO%"
swift build --product digup
if errorlevel 1 exit /b 1
if "%~1"=="" goto both
swift test --filter %1
goto done
:both
echo === worker off
swift test
echo run-off exit=%ERRORLEVEL%
echo === worker forced on
set "DIGUP_ISOLATE_DECODERS=1"
set "DIGUP_DECODE_HELPER=%DIGUP%"
swift test
echo run-on exit=%ERRORLEVEL%
:done
rem swift build deletes the tracked Package.resolved on Windows.
git restore Package.resolved 2>nul
