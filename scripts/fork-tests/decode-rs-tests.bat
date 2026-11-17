@echo off
rem DOWNSTREAM-FORK (2026-11-17): the Rust tests of decode-rs (the readers that replace stb and miniz). See README.md.
call "%~dp0env.bat"
cd /d "%REPO%\decode-rs"
cargo test --release --locked --target-dir "%TEST_ROOT%\decode-rs-target"
