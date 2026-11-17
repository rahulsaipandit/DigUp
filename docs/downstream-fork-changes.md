# Downstream fork changes

Every change this fork makes on top of upstream DigUp, newest first. When syncing with upstream, search the code for
`DOWNSTREAM-FORK` to find each change in place, and use this file for what it does and why.

Base: upstream `main` at `dc2651a` (Merge pull request #142).

Entry format: date and time (local), category, files, what changed, why, how it was checked, and what to do on a sync.

---

## 2026-11-17 (PST, late) — Rust readers for PSD, TGA and PNM; raw-byte pictures; escape and fuzz tests; advisory CI; PDFium 8152

- **Category:** security / robustness
- **Files:** `decode-rs/` (`src/lib.rs`, `Cargo.toml`, `Cargo.lock`, `fuzz/`), `Sources/DigUpKit/Platform/Portable/` (`Images+Portable.swift`,
  `DecodeIsolation.swift`, `DecodeIsolation+Media.swift`, `Sandbox+Windows.swift`), `Tests/DigUpKitTests/` (`DecodeIsolationTests.swift`,
  `FileReaderTests.swift`), `scripts/` (`check-advisories.py`, `advisories-acknowledged.txt`, `fetch-vendor.sh`, `vendor-checksums.json`),
  `.github/workflows/security.yml`, `shell/src-tauri/.cargo/audit.toml`, the docs.
- **What changed:**
  1. decode-rs reads PNM and TGA (`image` crate) and PSD (`psd` crate). On Windows `RGBImage.load` is the Rust reader and the worker no longer
     calls stb to look at or decode a file: what the Rust reader does not read goes to ffmpeg. Scaling and writing stay with stb (pixel
     arrays only). The pixel-comparison tests use `RGBImage.loadStb` as their reference.
     Review fix: a PSD whose header claims more pixels than any file of its length could hold (over 4096 per byte) is refused as corrupt before the
     `psd` crate allocates for it (it allocates from the header, and an allocation failure aborts the worker; it is not a caught panic). Tested.
  2. Pictures and rendered pages come back from the worker as raw bytes after the reply line (`blobs`), not base64, with caps on the client.
  3. Three more escape tests (write outside the work folder, open another process, write the user's registry), each with an unsandboxed control.
  4. Fuzzing: a seeded mutation fuzzer in `cargo test`, a Swift test of wrong-shaped requests, libFuzzer targets and a CI job.
  5. `FileReaderTests`: the `_open_osfhandle` leak fix is pinned (fails without the fix, checked by removing it).
  6. `security.yml`: `cargo audit` for both Rust projects, `check-advisories.py` for FFmpeg, dav1d, SQLite and PDFium.
  7. PDFium `chromium/8086` -> `chromium/8152` (published 2026-11-10, so past a 7-day age rule; 8165 was out a day). 8086 predated the fixes of
     Chrome 157.0.8103.38. The Windows archive was checked against its pin by `fetch-vendor.sh`; the other three pins are GitHub's published
     digests and those archives were not downloaded or run.
- **Checked:** 158 Swift tests plus 7 with the model pass on Windows; 14 decode-rs tests; `check-advisories.py` exits 0. **Not run:** the
  workflow in CI, the libFuzzer targets, PDFium 8152 on Linux or macOS.
- **On a sync:** keep `RGBImage.load` on Windows pointing at `RustDecode`, and keep the PDFium pin and its checksums together.

---

## 2026-11-17 (PST, late) — cargo audit: zip 9 in decode-rs, patch updates in the shell

- **Category:** security / dependencies
- **Files:** `decode-rs/Cargo.toml`, `decode-rs/Cargo.lock`, `shell/src-tauri/Cargo.lock`
- **What:** `zip` 2 → 9 in decode-rs (six advisories, none reachable since only `ZipArchive::new` and `by_name` are used, but
  fixed anyway). `cargo update` of rustls, rustls-webpki, webpki-root-certs, tokio and rustix in the shell.
- **Checked:** decode-rs unit tests (8), `cargo audit` clean for decode-rs, the decode library rebuilt and the full Swift suite
  (157 tests including the reference-vector test) passing. The shell was not built or run after the lock update.
- **Left:** `zip` 4.6.1 in the shell comes from `tauri-plugin-updater`.
- **On a sync:** keep the `zip` version in `decode-rs/Cargo.toml`.

---

## 2026-11-17 (PST, night) — Code-review fixes to the decoder sandbox and decode-rs

- **Category:** security / robustness
- **Files:** `decode-rs/src/lib.rs`, `Sources/DigUpKit/Platform/Portable/FileReader.swift`, `Sources/DigUpKit/Platform/Portable/AppContainer+Windows.swift`
- **What changed:** (1) decode-rs: a read callback that returns more bytes than it was asked for is an error (it moved the zip reader's position past its buffer); `max_bytes + 1` no longer wraps for a limit of `u64::MAX`; `dz_image_decode_rgb` clears `out` and `out_len` on every failure, as `dz_zip_entry` does. (2) `FileReader(passedHandle:)` no longer leaks the duplicated handle (or the passed one) when it fails after duplicating. (3) `AppContainer` loads `userenv.dll` with `LOAD_LIBRARY_SEARCH_SYSTEM32`, not the default search order (current folder, PATH).
- **How it was checked:** `cargo test --locked` in decode-rs (5 passed). The Swift changes were not built or run.
- **On a sync:** nothing special; these are inside fork-only files.

## 2026-11-17 (PST, night) — Fix: the decode worker's sandbox did not start under the shell (nested jobs)

- **Category:** security (a bug in the fork's own code, found by running the real shell)
- **Files:** [Sandbox+Windows.swift](../Sources/DigUpKit/Platform/Portable/Sandbox+Windows.swift); new:
  [job-nesting.py and .bat](../scripts/fork-tests/job-nesting.py); the check added to
  [shell-e2e/drive.mjs](../scripts/fork-tests/shell-e2e/drive.mjs)
- **What was wrong:** under the shell, every PDF, picture and document read failed with "PDF reader couldn't start: sandbox: assign to
  job failed (Windows error 50)". The shell puts each helper in a job object (helper.rs), and since the first entry in this file that
  job sets UI restrictions (no clipboard, desktop and so on). The worker is started in a job of its own, with the same UI restrictions.
  **Windows refuses to nest a job with UI restrictions inside one that has them.** Standalone runs, and every test, were fine, because
  a test runner is not inside such a job. It affected the sandboxed ffmpeg as well, which uses the same launcher.
- **How it was found:** the first run of the failed-files list in the real shell window. The list itself worked, and showed the
  failure: after "Retry all" the bad picture's reason was the sandbox error, not its own. The new check in `drive.mjs` is that reason.
- **Isolated with:** a process placed in jobs of each kind, running the helper under it (`job-nesting.bat`): no parent job: works;
  kill-on-close only: works; UI restrictions, with or without kill-on-close: **fails**. And with two levels of jobs: parent with UI
  restrictions and child without: works; parent without and child with: works; **both with: error 50**.
- **Fix:** the worker's job leaves out the UI restrictions when the helper is already in a job that has them (found with
  `QueryInformationJobObject` on the process's own job). The worker is bound by the parent's restrictions anyway, and when the helper
  is not in such a job (the command line, a test runner) the worker's job sets them as before, so nothing is lost either way.
- **Checked:** `job-nesting.bat` now passes for all four parent-job variants, including the shell's (kill-on-close plus UI
  restrictions); the real shell window passes all its checks and the index afterwards is right (the retried file done, the bad picture
  failed for its own reason). The unit tests cannot cover this: putting the test process into a UI-restricted job would restrict the
  whole run and cannot be undone, so the regression test is the script, run as its own processes.
- **A correction to an earlier claim:** the first entry in this file (UI restrictions on the helpers' job object) said it compiled and
  was not run. That was true, and this is what running it inside the shell showed: the restrictions on the shell's job and on the
  worker's job could not both be applied.
- **On a sync:** one block in `SandboxedProcess.init`.

## 2026-11-17 (PST, night) — Fixes from the owner's code review of the sandbox and Rust-reader code

- **Category:** security (fixes to the fork's own code)
- **Files:** [decode-rs/src/lib.rs](../decode-rs/src/lib.rs), [FileReader.swift](../Sources/DigUpKit/Platform/Portable/FileReader.swift),
  [AppContainer+Windows.swift](../Sources/DigUpKit/Platform/Portable/AppContainer+Windows.swift)
- **What the review found, and what was changed** (made by the owner; read and kept):
  - **Memory safety, zip reader** (`lib.rs`): the read callback's reply was trusted. A callback returning more bytes than it was
    asked for would have moved the reader's position past its buffer. It is now treated as a read error.
  - **Overflow** (`lib.rs`): `max_bytes + 1` would wrap or panic for a limit of `u64::MAX`; it is now `saturating_add`.
  - **Output pointers** (`lib.rs`): `dz_image_decode_rgb` left `out` and `out_len` unset on failure; they are now cleared on every
    failure path, as `dz_zip_entry` already did.
  - **Handle leaks** (`FileReader.swift`, `init?(passedHandle:)`): the duplicated handle leaked when `seekToEnd` failed, and the
    passed handle leaked when `_open_osfhandle` failed. Both are closed on those paths.
  - **DLL planting** (`AppContainer+Windows.swift`): `userenv.dll` was loaded with `LoadLibraryW`, which also looks in the current
    folder and on PATH. It now uses `LoadLibraryExW` with `LOAD_LIBRARY_SEARCH_SYSTEM32`. The shell already restricts its DLL search
    (see the first entry), but the `digup` helper does not, so this load needed it. No other `LoadLibrary` call is left in the code.
- **One more of the same kind, found while reading the fix:** if `DuplicateHandle` itself failed in `init?(passedHandle:)`, the passed
  handle was not closed. It is now.
- **Tests added** (in `lib.rs`): a callback that over-reports is an error and does not move the position; a limit of `u64::MAX` does
  not wrap or panic; `dz_image_decode_rgb` clears `out` and `out_len` on failure.
- **Checked:** the Rust tests (8, including the three above) pass. The Swift changes were not built or run in this step. The handle
  leaks (a failing `seekToEnd`, `_open_osfhandle` or `DuplicateHandle`) and the DLL load have no test: nothing here can make those fail.

## 2026-11-17 (PST, night) — A quiet list of files that could not be read, with Retry (Windows and Linux shell)

- **Category:** visibility / usability
- **Files:** changed: [IndexStore.swift](../Sources/DigUpKit/IndexStore.swift) (`failedCount`, `failedFiles`, `requeueFailed`),
  [SearchService.swift](../Sources/digup/SearchService.swift) (the `failures` and `retry` questions),
  [IndexService.swift](../Sources/digup/IndexService.swift) (the `retry` command), [helper.rs](../shell/src-tauri/src/helper.rs)
  (`IndexService::retry`), [main.rs](../shell/src-tauri/src/main.rs) (`failures` allowed, the `retry_failed` command),
  [settings.html](../shell/ui/settings.html), [settings.js](../shell/ui/settings.js), [settings.css](../shell/ui/settings.css).
  New: [FailedFilesTests.swift](../Tests/DigUpKitTests/FailedFilesTests.swift)
- **Change:** Settings → Folders shows one line, "N files couldn't be read. Review…", only when there are any. Review opens a list in
  the page: reasons grouped and counted, each file with its reason and a Retry, and Retry all. No notification, tray alert or dialog.
  Retry puts files back to waiting and has the index helper read them now.
- **Why:** with the decode worker on by default, one failure can fail every PDF, picture and document, and the app showed no per-file
  failures. See "Files that could not be read (in the app)" in [design.md](design.md).
- **Checked:** the store tests; the real `digup search-service` against an index with failed files (count, list, retry one, retry all);
  the real page in headless Edge with a mocked backend, in each state; `cargo check`.
- **Whole suite:** 150 tests pass with the worker off and forced on. The first full run had the new store tests fail while writing
  their own sample files (Windows error 32, a file in use, right after creating it): the same kind of failure as the unexplained
  `ImageTests` one earlier, and consistent with security software scanning new files in the temp folder, which is a guess. The tests
  now retry the write for a moment.
- **Checked with the real model** (files downloaded to `D:\Users\rahul\AppData\Local\DigUp\Models`): a good file marked failed was
  put back to waiting by `retry all`; `index-service` read nothing without the `retry` command (control) and read it with it; a
  genuinely bad picture failed again and was counted once.
- **Later checked in the real shell window** (`scripts/fork-tests/shell-e2e`); see the entries above. **Not checked:** the Mac app has no such list.
- **On a sync:** small additions in each of those files, each tagged `DOWNSTREAM-FORK`; the page's additions are one block in each of
  the three page files.

## 2026-11-17 (PST, late night) — Security: Rust readers for zip files and pictures in place of miniz and stb (Windows)

- **Category:** security
- **Files:** new: [decode-rs/](../decode-rs/) (Cargo.toml, Cargo.lock, src/lib.rs, include/digup_decode.h),
  [Sources/CDecode/module.modulemap](../Sources/CDecode/module.modulemap),
  [scripts/build-decode-rs.sh](../scripts/build-decode-rs.sh),
  [RustDecode+Windows.swift](../Sources/DigUpKit/Platform/Portable/RustDecode+Windows.swift). Changed:
  [Package.swift](../Package.swift) (Windows only: the `CDecode` module and its link flags),
  [Docs+Portable.swift](../Sources/DigUpKit/Platform/Portable/Docs+Portable.swift) (the miniz `ZipArchive` is not compiled on Windows),
  [DecodeIsolation+Media.swift](../Sources/DigUpKit/Platform/Portable/DecodeIsolation+Media.swift) (Rust first for pictures),
  [DecodeIsolation.swift](../Sources/DigUpKit/Platform/Portable/DecodeIsolation.swift) (a self-test operation),
  [packages.yml](../.github/workflows/packages.yml) and [package-windows.sh](../scripts/package-windows.sh) (build and check for it),
  [DecodeIsolationTests.swift](../Tests/DigUpKitTests/DecodeIsolationTests.swift)
- **Change:** on Windows, zip files are read by the Rust `zip` crate (in the helper and in the worker), and JPEG, PNG, GIF and BMP
  pictures by the Rust `image` crate in the decode worker. A picture the Rust reader recognizes and finds bad is refused and not
  handed to stb; formats it does not read still go to stb, in the sandbox. Nothing changes off Windows.
- **Why:** the readers that parse the most hostile bytes were C; this is step 3 of the plan in [design.md](design.md).
- **Pixels and vectors:** PNG and BMP are exact against stb; JPEG differs by a few levels (mean under 3 per value), which moves an
  embedding a little. Not checked against the reference vectors (no model files here): existing JPEG vectors may differ slightly
  from ones made after this change.
- **Supply chain:** 39 crates in `decode-rs/Cargo.lock`, built with `--locked`, not audited (`cargo audit` was not run). Larger than
  the two C source files it replaces.
- **Found while doing it:** Git's bash has a `link.exe` of its own that rustc runs instead of MSVC's (the build failed in a
  dependency's build script); `build-decode-rs.sh` names the MSVC one. CI already puts MSVC's tools first.
- **Checked:** 5 Rust tests and the Swift tests listed in design.md; the whole suite (147 tests) passes with the worker off and with
  it forced on. The Rust library was built by the script and rebuilt only when its inputs change. **Not run:** the CI workflow and
  the installer build.
- **Not done:** Rust readers off Windows; PSD, TGA and PNM still use stb; the video frames and ffmpeg's output are still read by
  stb in the helper.
- **On a sync:** `Package.swift` gets a Windows-only block and two small edits; `Docs+Portable.swift` wraps one class in `#if`.

## 2026-11-17 (PST, night, later still) — Security: ffmpeg and ffprobe in the sandbox (Windows)

- **Category:** security
- **Files:** new: [FFmpegSandbox+Windows.swift](../Sources/DigUpKit/Platform/Portable/FFmpegSandbox+Windows.swift). Changed:
  [Sandbox+Windows.swift](../Sources/DigUpKit/Platform/Portable/Sandbox+Windows.swift) (a file as the program's standard input, the
  folders to grant, `exitCode`), [Media+Portable.swift](../Sources/DigUpKit/Platform/Portable/Media+Portable.swift) (one guard in
  `FFmpeg.run`), [build-ffmpeg.sh](../scripts/build-ffmpeg.sh), [DecodeIsolationTests.swift](../Tests/DigUpKitTests/DecodeIsolationTests.swift)
- **Change:** with the worker in use, `FFmpeg.run` starts ffmpeg and ffprobe in the AppContainer under the job object and mitigation
  policies, handing over the one file they read as standard input (`-fd 0 -i fd:`); pictures they write as files go to a scratch
  folder in the container and are moved to the caller's folder. If the sandbox cannot be set up the call fails (and is written to
  `decode-worker.log`), with no fallback to running outside.
- **Why:** ffmpeg was the one decoder left outside the sandbox, and the one that parses the most hostile formats.
- **Build changes to ffmpeg:** `--enable-protocol=...,fd`, and the `image_*_pipe` demuxers. **Found while doing it:** the
  `webp_pipe tiff_pipe png_pipe jpeg_pipe bmp_pipe` names already in the script matched no component of this ffmpeg, and the
  script's check for such names did not report it. The ffmpeg stamp was updated for a comment-only change, to avoid a rebuild
  for nothing; the CI cache key for ffmpeg changes with the script, so CI rebuilds it once.
- **Found while testing:** this ffmpeg takes the descriptor as an option (`-fd 0 -i fd:`), and refuses `fd:0`; a bare environment
  made the launch fail with Windows error 203.
- **Checked:** new tests: a sandboxed ffprobe reads a handed file and cannot open the same path (with a control that a plain
  process can); durations and streams equal the outside; a frame written as a file reaches the caller's folder; a per-task
  launch counter shows ffmpeg is started in the sandbox exactly when the worker is in use (a call that works either way would
  prove nothing); the HEIC, AVIF, WebP and TIFF pictures come out as outside the sandbox. The whole suite (143 tests) passes
  with the worker off and with it forced on, which sends every video, audio and picture test through the sandboxed ffmpeg.
- **On a sync:** one guard in `FFmpeg.run`; the rest is in files that are new in the fork, and in the ffmpeg build script.

## 2026-11-17 (PST, night, later) — A worker that cannot start leaves a trace

- **Category:** security (visibility)
- **Files:** changed: [DecodeIsolation.swift](../Sources/DigUpKit/Platform/Portable/DecodeIsolation.swift) (`DecodeLog`, `logLine`),
  [main.swift](../Sources/digup/main.swift) (`digup status` prints the log's path),
  [DecodeIsolationTests.swift](../Tests/DigUpKitTests/DecodeIsolationTests.swift)
- **Why:** with the worker on by default, a worker that cannot start fails every PDF, picture and document, and the app shows no
  per-file failures. A file's failure is stored in the index (`failed` plus the reason, counted by `digup status`), but nothing
  in the app says so.
- **Change:** the reason a worker could not start is appended to `%LOCALAPPDATA%\DigUp\decode-worker.log`, once for each reason in
  each process. `digup status` prints the log's path once it exists.
- **Checked:** a test that the same reason is written once and a different one again; the existing "worker that cannot start"
  test now also checks the trace, writing to a temporary log, not the real one.
- **Not done:** a message in the app (needs the shell's status events changed).

## 2026-11-17 (PST, night) — Security: the worker is on by default (Windows); scratch-folder sweep; uninstall hook

- **Category:** security
- **Files:** changed: [DecodeIsolation.swift](../Sources/DigUpKit/Platform/Portable/DecodeIsolation.swift) (`enabled`, `resolve`),
  [AppContainer+Windows.swift](../Sources/DigUpKit/Platform/Portable/AppContainer+Windows.swift) (`sweepWorkFolder`),
  [Sandbox+Windows.swift](../Sources/DigUpKit/Platform/Portable/Sandbox+Windows.swift),
  [hooks.nsh](../shell/src-tauri/windows/hooks.nsh), [DecodeIsolationTests.swift](../Tests/DigUpKitTests/DecodeIsolationTests.swift)
- **Default on:** with `DIGUP_ISOLATE_DECODERS` unset, the worker is used on Windows when the running program is named `digup`.
  `=0` turns it off and `=1` on. Other systems and other programs (a test runner) are off by default, so `swift test` is
  unchanged. If the sandbox cannot be set up, the worker does not start and the files are reported unreadable with the reason.
- **Why:** the user chose it. The first-run risks (a machine-wide install, a non-NTFS drive, security software) are not
  tested yet and will be tried on a separate machine.
- **Checked in the real program:** `digup estimate` on a 7-page PDF with no switch set reads 7 pages through the worker (0.08 s
  against 0.01 s direct); with `=0` it reads 7; with the default on and the worker's program path made wrong it falls back to
  1 page, which shows the default does go through the worker. A unit test covers the decision (switch, program name, system).
- **Scratch sweep:** the container's scratch folder (`...\Packages\DigUp.DecodeWorker\AC\Temp`) is swept once per helper process,
  the first time a worker starts: files not changed for 10 minutes are removed. A worker deletes each file as soon as it has
  sent it, so only a worker killed mid-render leaves one; two helpers can have workers at once, so recent files are kept.
  A test checks that old files go and fresh ones stay.
- **Whole suite:** 138 tests pass with the worker off and with it forced on.
- **An unexplained failure in an existing test:** `ImageTests.preparedAsShown` (the direct code path: "unreadable" on the PNG
  it had just written) failed 3 times: in the first run after a rebuild twice, and once in a loop of 40 runs of that suite.
  An export of the last upstream commit, built separately, had 0 failures in 160 runs of the same suite, and so did this
  build in 100 interleaved runs afterwards, so it could not be tied to these changes or cleared of them. With the worker off,
  the changed code on that path is a check of the switch and a read of an unset task-local. If it comes back, run
  `swift test --filter ImageTests` in a loop on a build with and without these changes.
- **Uninstall:** `hooks.nsh` runs `helper\digup.exe sandbox-remove` before an uninstall removes files, and not on an update.
  **Not tested:** no installer was built, so the NSIS macro has not run.
- **On a sync:** `hooks.nsh` gets a new macro; the rest is in files that are new in the fork.

## 2026-11-17 (PST, later) — Security: taking the sandbox away (`digup sandbox-remove`)

- **Category:** security
- **Files:** changed: [AppContainer+Windows.swift](../Sources/DigUpKit/Platform/Portable/AppContainer+Windows.swift) (the
  profile and folder functions now take a profile name; a list of granted folders; revoke, check and remove),
  [main.swift](../Sources/digup/main.swift) (the `sandbox-remove` command),
  [DecodeIsolationTests.swift](../Tests/DigUpKitTests/DecodeIsolationTests.swift)
- **Change:** every folder the container is granted is written to `%LOCALAPPDATA%\DigUp\sandbox-grants.txt`.
  `digup sandbox-remove [folder...]` takes the container's access from those folders, from folders named on the command line
  and from the folders this program would grant itself, then deletes the container profile and the list. It reports each
  step, and a second run does nothing and does not fail.
- **Why:** the earlier stages left permission changes on folders and a profile with no way to undo them, and a clean first run
  cannot be tested without removing them. An uninstaller needs it too (the installer does not call it yet).
- **Used on this machine:** I ran it to undo what the earlier test runs had added, then ran the isolation tests again from
  scratch. The earlier changelog entry lists four folders that were granted; the list found three more that the test runs
  had granted without my noticing: `C:\Users\rahul\AppData\Local\Programs\Swift\Platforms\6.4.1\Windows.platform\Developer\Library\Testing-6.4.1\usr\bin64`,
  the same path with `XCTest-6.4.1`, and `D:\Github\DigUp\.build\out\Products\Debug-windows-x86_64`. All were revoked, and
  the profile was deleted. The tests have since made the profile and grants again, as they must.
- **Checked:** new tests with throwaway containers (never the real one): a grant can be seen and taken away; removal takes the
  grants (from the list and from the command line) and the profile away, deletes the list, and a second run succeeds; a
  grant to the real container is recorded in the list. First run from scratch: 21 isolation tests pass in about 4 seconds.
- **Whole suite:** 136 tests pass with the worker forced on, and with it off in 4 repeated runs. The first flag-off run after
  the rebuild had one failure in the existing `ImageTests.preparedAsShown` for the HEIC picture ("unreadable" on the PNG it
  had just written, in the direct code path, which this change does not touch). It did not repeat in 4 further runs. The
  cause is not known; a file scanned by security software right after it is written would look like this, but that is a guess.
- **Not tested:** another Windows user account, a machine-wide install, a non-NTFS drive, security software.
- **On a sync:** all in files that are new in the fork, plus one `case` in `main.swift`.

## 2026-11-17 (PST) — Security: pictures (stb) and zip-based documents (miniz) in the worker; network test

- **Category:** security
- **Files:** new: [DecodeIsolation+Media.swift](../Sources/DigUpKit/Platform/Portable/DecodeIsolation+Media.swift). Changed:
  [DecodeIsolation.swift](../Sources/DigUpKit/Platform/Portable/DecodeIsolation.swift) (the `image.prepare` and `doc.text`
  operations, a `tooSmall` error, self-test operations), [Sandbox+Windows.swift](../Sources/DigUpKit/Platform/Portable/Sandbox+Windows.swift)
  (the network probe), [Images+Portable.swift](../Sources/DigUpKit/Platform/Portable/Images+Portable.swift) (one guard in
  `ImageExtractor.prepare`), [Extractors.swift](../Sources/DigUpKit/Extractors.swift) (one guard in `DocExtractor.text`),
  [Docs+Portable.swift](../Sources/DigUpKit/Platform/Portable/Docs+Portable.swift) (`ZipArchive` reads a handed-over file),
  [EXIF.swift](../Sources/DigUpKit/Platform/Portable/EXIF.swift) (same, for EXIF's reader),
  [OfficeText.swift](../Sources/DigUpKit/OfficeText.swift) (the password check reads a handed-over file),
  [FileReader.swift](../Sources/DigUpKit/Platform/Portable/FileReader.swift) (`duplicateHandle`),
  [DecodeIsolationTests.swift](../Tests/DigUpKitTests/DecodeIsolationTests.swift)
- **Change:** with `DIGUP_ISOLATE_DECODERS=1`, `ImageExtractor.prepare` and `DocExtractor.text` (docx, odt, xlsx, pptx, ods, odp)
  ask the worker, as the PDF code does. The worker reads a picture whole into memory (at most 512 MB) and decodes it from
  there, since stb opens paths and the sandboxed worker has only its handle. A picture stb cannot read (HEIC, WebP, TIFF,
  AVIF) is reported as `route: ffmpeg`, and the helper runs ffmpeg as before, then scales and writes it with stb.
- **Why:** step 1 of the plan in [design.md](design.md), for the rest of the C decoders that run in the helper's process.
- **Not in the sandbox:** ffmpeg (it is a program, and the worker may not start programs), and stb as used on what ffmpeg
  produces: the scaling and writing in the helper for HEIC, WebP, TIFF and AVIF, and the frames ffmpeg writes for videos
  (`RGBImage.load` in Media+Portable.swift). Pictures stb reads itself are fully in the worker.
- **Found while testing:** `FileHandle.fileDescriptor` doesn't exist on Windows, and the handle `FileHandle(fileDescriptor:)`
  is given can't be duplicated afterwards (error 6, invalid handle), so `FileReader(passedHandle:)` keeps a duplicate of its
  own, made first. A blocked loopback connection takes about 20 seconds to give up, so the network probe is non-blocking with
  a 2-second limit. `FIONBIO` is a negative `Int32` in Swift: converting it to `UInt32` traps (a crash in the worker).
- **Also found:** the existing test for a password-protected spreadsheet failed with the worker forced on. `isCompoundFile`
  (the check for an encrypted Office file) opens the path itself, which the sandboxed worker may not, so it fell through to
  "not a zip file". It now reads the first bytes from the handed-over file.
- **Checked:** 133 tests pass with the worker off and with it forced on for every picture, document and PDF read (the forced-on
  run found the folders already granted by earlier runs, as before). New tests: the five test pictures come out as the direct code makes them (size, EXIF date, orientation and
  colors); a too-small picture is still skipped; a Word file reads the same; a zip that declares too much is refused and the
  worker lives on; the worker can read EXIF from its handle; and the network test (below).
- **Network test (stage 4):** a loopback listener in the test; the worker's connection attempt succeeds with the sandbox off
  (the control) and fails in the AppContainer.
- **On a sync:** upstream files changed are one guard each in `ImageExtractor.prepare` and `DocExtractor.text`, one line each
  in `ZipArchive.init` and `FileBytes.init`, and `duplicateHandle` in `FileReader`.

## 2026-11-16 (PST, late night) — Security: Windows sandbox, stages 2 and 3: AppContainer, handle passing

- **Category:** security
- **Files:** new: [AppContainer+Windows.swift](../Sources/DigUpKit/Platform/Portable/AppContainer+Windows.swift). Changed:
  [Sandbox+Windows.swift](../Sources/DigUpKit/Platform/Portable/Sandbox+Windows.swift),
  [DecodeIsolation.swift](../Sources/DigUpKit/Platform/Portable/DecodeIsolation.swift),
  [PDF+Portable.swift](../Sources/DigUpKit/Platform/Portable/PDF+Portable.swift) (one line: a worker reads the file it was
  handed, else the path), [FileReader.swift](../Sources/DigUpKit/Platform/Portable/FileReader.swift) (an initializer from a
  Windows handle), [DecodeIsolationTests.swift](../Tests/DigUpKitTests/DecodeIsolationTests.swift)
- **Change:** the Windows worker now also runs as an AppContainer (`DigUp.DecodeWorker`, no capabilities): no network access,
  and read access only where granted.
  - The helper grants the container read and execute on its own folder and on the folders its loaded DLLs are in (a module
    snapshot; Windows' folders skipped). `DIGUP_SANDBOX_DLL_DIRS` adds folders for a parent that is not the worker's program.
  - The helper opens the PDF and duplicates the handle into the worker, which reads through it; it can open no other file.
  - The worker renders into the container's own folder and returns the picture as base64 in the reply; the helper writes it
    where the caller asked.
  - If the container or a grant cannot be made, the worker does not start.
- **Why:** stages 2 and 3 of "Windows sandbox for the worker" in [design.md](design.md). An AppContainer cannot read the user's
  PDF by path or write to the output folder, so handle passing and returning pictures as bytes had to come with it.
- **Changes to the machine you should know about:** access entries for the container's SID were added to these folders, and
  stay: `Vendor\llama\lib`, `Vendor\pdfium\bin`, `.build\debug`, and the Swift runtime folder
  `C:\Users\rahul\AppData\Local\Programs\Swift\Runtimes\6.4.1\usr\bin`. The profile folder
  `%LOCALAPPDATA%\Packages\DigUp.DecodeWorker` was made. `digup sandbox-remove` (below) takes all of it away.
- **Checked:** the worker cannot open a file it was not handed, with a control showing the same open works with the sandbox off
  (`DIGUP_SANDBOX=0`); pages with little text come back as PNG files; the other PDF tests and the long-PDF indexing test pass
  through it. 127 tests pass with the worker off and with it forced on for every PDF read. The forced-on run found the
  folders already granted by earlier runs, so it did not test a first run on a clean machine.
- **Not done:** binary frames for pictures (base64 for now).
- **On a sync:** the upstream files changed are small: one line in `PDFium.withDocument` and one initializer in `FileReader`.

## 2026-11-16 (PST, night) — Security: Windows sandbox, stage 1: job object and mitigation policies for the worker

- **Category:** security
- **Files:** new: [Sandbox+Windows.swift](../Sources/DigUpKit/Platform/Portable/Sandbox+Windows.swift). Changed:
  [DecodeIsolation.swift](../Sources/DigUpKit/Platform/Portable/DecodeIsolation.swift) (the client talks to the worker
  through a `DecodeChannel`, with `ProcessChannel` for Foundation's `Process` and `SandboxedProcess` for Windows; the worker
  answers `selftest.*` only when a test asks), [DecodeIsolationTests.swift](../Tests/DigUpKitTests/DecodeIsolationTests.swift)
- **Change:** on Windows the decode worker is started with `CreateProcessW` (suspended, then into its own job object, then
  resumed), not Foundation's `Process`:
  - job: kill on close, one process only, a memory cap (4 GiB, `DIGUP_DECODE_MEMORY_MB`), die on unhandled exception, and UI
    restrictions (no clipboard, desktop, display settings, system parameters, global atoms, exit-windows);
  - process mitigation policies: heap corruption ends the process, bottom-up and high-entropy ASLR, strict handle checks, no
    legacy extension points, control-flow guard, no remote or low-integrity image loads, System32 preferred;
  - the child-process policy (no child processes), and only the worker's three standard handles are inherited.
  `DIGUP_SANDBOX=0` starts the worker with `Process` instead, for debugging. If any step fails the worker is not started:
  nothing falls back to a plain launch.
- **Why:** stage 1 of "Windows sandbox for the worker" in [design.md](design.md). The AppContainer and handle passing are
  the next stages. This stage limits a compromised worker to its one process, with no way to start another program or touch
  the user's clipboard and desktop, and moves the helper off `Process`, which the later stages need.
- **Left out on purpose:** dynamic-code prohibition, win32k lockdown, font disable and Microsoft-only binaries, none of which is
  known to be safe with PDFium or this program's unsigned DLLs.
- **Found while testing:** the first version ended the worker at once with `0xC0000142` (`STATUS_DLL_INIT_FAILED`). Turning
  off each restriction in turn showed the child-process policy was the cause: with `CREATE_NO_WINDOW` a console program gets
  a hidden console served by a `conhost.exe` child, which the policy refuses to start. `DETACHED_PROCESS` (no console) fixes
  it, since the worker uses its pipes. The error message now includes the worker's exit code.
- **Checked:** 3 new Windows tests: the worker's job has kill-on-close, a process limit of 1, a memory cap and the UI
  restrictions; the worker cannot start `cmd.exe`; `DIGUP_SANDBOX=0` really starts it outside the job. The existing PDF
  tests now run through this launch.
- **Not done:** the worker still has the user's rights and opens files by path (stages 2 and 3), and no escape test exists
  yet (stage 4).
- **On a sync:** this is all new files plus the channel change in `DecodeIsolation.swift`. Nothing in upstream's own files
  changes for this stage.

## 2026-11-16 (PST, evening) — Security: PDFium in a separate worker process (off by default)

- **Category:** security
- **Files:**
  - new: [DecodeIsolation.swift](../Sources/DigUpKit/Platform/Portable/DecodeIsolation.swift) (client and worker loop),
    [DecodeIsolationTests.swift](../Tests/DigUpKitTests/DecodeIsolationTests.swift), [decoder-worker.md](decoder-worker.md)
  - changed: [PDF+Portable.swift](../Sources/DigUpKit/Platform/Portable/PDF+Portable.swift) (a guard at the top of
    `PDFExtractor.pages`, `PDFExtractor.renderPage` and `Estimator.pages`),
    [main.swift](../Sources/digup/main.swift) (the `decode-worker` command, and it joins the modes that watch their parent)
- **Change:** with `DIGUP_ISOLATE_DECODERS=1`, the three places that read a PDF ask `digup decode-worker` over JSON lines
  instead of calling PDFium in the helper's process. The worker runs the same PDFium code. A crash or a hang (180 s,
  `DIGUP_DECODE_TIMEOUT`) costs one file: the request throws `ExtractError.unreadable` and the worker is started again.
  A worker that cannot start is an error, never a silent fallback to reading in process.
- **Why:** step 1 of the plan in [design.md](design.md). A bug in PDFium then takes down the worker and not the index or
  the model, and the worker is a process that can be sandboxed next.
- **Off by default,** so upstream's behavior and tests are unchanged until the worker is shown to match.
- **Not done:** no sandbox yet (the worker has the user's rights), paths and not handles, only PDF. See
  [decoder-worker.md](decoder-worker.md).
- **Checked:** 7 new tests (same pages, text, total and title as the direct code; range clamping; count and render; a
  non-PDF is `unreadable` and the worker lives on; a stopped worker is restarted; a worker that can't start is an error).
  The first version blocked forever reading the reply, because `readData(ofLength:)` waits to fill its length: fixed with
  `availableData`, as `EmbeddingWorker` does.
- **On a sync:** the guards in `PDF+Portable.swift` are three short `if DecodeIsolation.enabled { ... }` blocks, each tagged
  `DOWNSTREAM-FORK`. If upstream changes those functions' signatures, update the guards and the worker's `pdf.*` handlers
  in `DecodeIsolation.swift` to match.

## 2026-11-16 21:31 (PST) — Security: DLL search path in the Windows shell

- **Category:** security
- **Files:** [main.rs](../shell/src-tauri/src/main.rs) (`main`), [Cargo.toml](../shell/src-tauri/Cargo.toml)
  (`windows-sys` feature `Win32_System_LibraryLoader`)
- **Change:** the first thing `main` does on Windows is call `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)`.
  DLLs are then found only in the program's folder, System32 and folders added with `AddDllDirectory`, never in the
  current folder or on PATH.
- **Why:** DigUp installs per user, so its install folder is writable by the user. A DLL planted in the folder DigUp was
  started from, or on PATH, could otherwise load into the shell. See [design.md](design.md), "Shell and install".
- **Checked:** `cargo check` passes (Windows, MSVC). Not run: the shell has not been started with this change, and no
  test loads a planted DLL.
- **Not covered:** this is the Tauri shell only. The Swift helper loads llama.cpp's backends and CUDA DLLs from beside
  itself, and a default-directories change there could break that, so it was left alone.
- **On a sync:** keep the block at the top of `main`. If upstream adds early startup code, the call still goes first.

## 2026-11-16 21:31 (PST) — Security: UI restrictions on the helpers' job object

- **Category:** security
- **Files:** [helper.rs](../shell/src-tauri/src/helper.rs) (`mod job`, the `job()` function and its imports)
- **Change:** besides `KILL_ON_JOB_CLOSE`, the Windows job object that holds the helpers now sets UI restrictions: no
  desktop switching, display-setting changes, exiting Windows, global atoms, system-parameter changes, or clipboard
  read and write. Applied best effort: if the call fails, the job still works as before.
- **Why:** the helpers and their decoders (ffmpeg, PDFium, stb, miniz) are headless and parse untrusted files. If a
  decoder is exploited, it has no use for these, and each is a way to affect the user's session.
- **Not set on purpose:** `JOB_OBJECT_UILIMIT_HANDLES` (USER handles of processes outside the job), because GPU drivers
  can need them and this could not be tried against every driver. No job memory limit either: the embedding model's use
  is large and varies, and a wrong number would kill the helper.
- **Checked:** `cargo check` passes (Windows, MSVC). Not run: no helper was started under the new job, so a GPU or
  driver problem would show only at run time. If the helpers fail on a machine after this change, remove the UI
  restrictions block first.
- **Later found to conflict** with the decode worker's own job when the helper runs under the shell (Windows refuses a nested job with UI
  restrictions inside one that has them); the worker's job now leaves them out in that case. See "Fix: the decode worker's sandbox did not
  start under the shell" above.
- **On a sync:** if upstream changes `job()`, re-apply the block after the limits are set and before the job is returned.

---

## Reviewed and left as upstream

Checked while planning, and found already in place upstream, so no change is made:

- **ffmpeg's protocols and formats:** [build-ffmpeg.sh](../scripts/build-ffmpeg.sh) builds with `--disable-network`,
  `--enable-protocol=file,pipe` and allowlists of demuxers, decoders, parsers and filters.
- **Zip bombs:** `Zip.maxEntryBytes` and `ZipArchive.maxEntrySize` cap what an entry may declare.
- **Tauri:** a strict CSP (`default-src 'self'`, no `unsafe-eval`) and a minimal capability set (`core:default`).
- **Update signing:** the updater requires signed versions.

## Planned, not done

From [design.md](design.md). Not started because they need Swift or run-time testing that was not available when the
changes above were made (no Swift toolchain was on this machine):

- A Linux sandbox. (PDF, pictures, zip-based documents and ffmpeg are in the sandbox on Windows.)
- Windows sandbox for the workers (AppContainer or restricted token, mitigation policies, per-process limits).
- Rust replacements for stb and miniz.
- CI advisory checks, signed decoder bundles, fuzzing.
