# Tests for the fork's changes (Windows)

Scripts to run the checks that were made while building the fork's security and failed-files changes, so they can be run again after
an upstream sync or a change. The unit tests themselves are in `Tests/DigUpKitTests` (Swift) and `decode-rs/src/lib.rs` (Rust); these
scripts run them, and add the end-to-end checks that need real helpers, a real model, or the real shell window.

Everything is run from a normal `cmd` window (or by double-click): `env.bat` sets up Swift, MSVC and the other tools, so none needs to
be on PATH. Everything they make goes to `TEST_ROOT` (default `D:\Temp\digup-fork-tests`; D: as `CLAUDE.md` asks) and never touches the
real DigUp settings, index or models. To use other locations, set `REPO`, `TEST_ROOT`, `SWIFT_HOME`, `SWIFT_VERSION`, `VCVARS`,
`VSINSTALLER`, `CARGO_BIN`, `MODELS` or `EDGE` before running (their defaults, for this machine, are in `env.bat`).

## Before running

- Build the vendored pieces once: `scripts/fetch-vendor.sh`, `scripts/build-llama.sh`, `scripts/build-decode-rs.sh`, and
  `scripts/build-ffmpeg.sh` (in MSYS2). See "Development environment" in `docs/design.md`.
- The two real-model scripts need the model files in `MODELS` (`digup download-model --to ...`).

## The scripts

| Script | What it checks | Needs | Passing looks like |
|---|---|---|---|
| `swift-tests.bat` | The whole Swift suite, twice: with the decode worker off (a test runner's default) and with `DIGUP_ISOLATE_DECODERS=1` for every read. `swift-tests.bat NAME` runs the tests matching NAME. | Swift, MSVC, the vendored pieces | `run-off exit=0` and `run-on exit=0`, each with "Test run with N tests ... passed" |
| `decode-rs-tests.bat` | The Rust readers' own tests (pictures, zip entries, size limits, garbage input). | Rust, MSVC | `test result: ok. 8 passed` |
| `search-service-failures.bat` | The real `digup search-service` answering `failures` and `retry`, against an index made with failed files. No model. | the helper built | `PASS` |
| `retry-e2e.bat` | Retrying failed files with the real model: a file marked failed is put back to waiting, **not** read without the `retry` command (the control), read with it; a truly bad picture fails again, counted once. | the helper, the model files | `PASS` |
| `job-nesting.bat` | The decode worker starts when its helper is inside a job object like the shell's (kill-on-close plus UI restrictions). A bug here made the sandbox fail to start under the shell, and no unit test could see it. Runs the helper inside each kind of parent job. | the helper built, a PDF (`TEST_PDF`) | four lines each ending "the worker started" |
| `ui-harness\screenshots.bat` | The real Settings page, with a mock backend, in each state of the failed-files list, as pictures from headless Edge (`TEST_ROOT\ui-harness\shots`): `none`, `count`, `open`, `retried`, `many`. | Edge, Python | five PNG files to look at (nothing is asserted) |
| `shell-e2e\build-shell.bat` | Builds the Tauri shell (debug) into `TEST_ROOT\shell-target`. | Rust, MSVC | the build finishes |
| `shell-e2e\run.bat` | The failed-files list in the **real shell window**: opens Settings, Folders, Review, clicks Retry all, waits for the real helpers to read the files again, and reads the page over WebView2's debugging port. It also fails if the retry fails because the worker could not start under the shell. | the shell built, the helper, the model files, Node 22+, WebView2 | `ok` for each check, then `drive=0 check=0` |

## Notes

- `shell-e2e\run.bat` opens a real DigUp window and a tray icon for about a minute, with an obscure global hotkey
  (`Ctrl+Alt+Shift+F11`), update checks off, its settings and WebView2's profile on D:, and its own index. Screenshots of the real
  page are in `TEST_ROOT\shell-e2e\shots`.
- Running the model in a dev build needs `DIGUP_MODELS` and `DIGUP_BACKENDS` (`env.bat` sets the second; the real-model scripts
  set the first). Without `DIGUP_BACKENDS` the helper reports "no backends are loaded".
- A failure that is a Windows "file in use" error (code 32) while a test writes its own sample file has been seen a few times, and
  is thought to be security software scanning a new file; the tests that write files retry for a moment. A real failure repeats.
- What these scripts cover, and what was checked and what was not, is written down in `docs/design.md` and
  `docs/downstream-fork-changes.md`.
