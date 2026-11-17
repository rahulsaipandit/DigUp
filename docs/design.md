# Plan: safer file readers on Windows and Linux

## Background

DigUp turns each file into something the model can read (text, a picture, audio), embeds it with llama.cpp and stores the
vectors in SQLite. On macOS the readers are Apple's frameworks. On Windows and Linux they are C libraries in
`Sources/DigUpKit/Platform/Portable/`:

| Job | Library | Runs |
|---|---|---|
| Pictures | stb (JPEG, PNG, BMP, GIF, PSD, TGA, PNM); FFmpeg for HEIC, WebP, TIFF, AVIF | stb in the engine process; FFmpeg as a separate process |
| PDFs | PDFium | in the engine process |
| Audio and video | FFmpeg and ffprobe | separate process |
| `.docx` and `.odt` | miniz | in the engine process |

DigUp opens files nobody chose to open (downloads, attachments, files from other people), and these libraries parse
hostile input in C or C++. A memory bug in stb, miniz or PDFium is a bug in the process that holds the index and the model.
FFmpeg is already a separate process, but it is not sandboxed. Fixes arrive only with a DigUp release.

How the processes are arranged today (read from the code, not assumed):

- The Tauri shell starts the `digup` helper ([helper.rs](../shell/src-tauri/src/helper.rs)) with piped stdin and stdout and
  talks to it in JSON lines. The helper has several modes (`index-service`, search, `worker`, and others in
  [main.swift](../Sources/digup/main.swift)).
- The decoders run inside the helper's index service, in the same process as the SQLite index. llama.cpp is linked in as a
  library ([Package.swift](../Package.swift)), so the embedding model lives in the process that parses files too.
- `digup worker` is the embedding model as its own process, speaking JSON lines
  ([WorkerService.swift](../Sources/digup/WorkerService.swift)). It is not a decoder worker, but it is the pattern to copy
  for one.
- The only isolation on Windows is a job object that ends the helpers with the shell. The launch sets only
  `CREATE_NO_WINDOW` and a lower priority. There is no restricted token, AppContainer or integrity level.
- Audio is decoded by FFmpeg to 16 kHz mono PCM in windows and fed to the embedding model (`embedAudio`), not to a speech
  recognizer. Video frames are sampled the same way. FFmpeg runs as `ffmpeg -nostdin -i <path> ...` with its output read as a
  stream ([Media+Portable.swift](../Sources/DigUpKit/Platform/Portable/Media+Portable.swift)).

Goal: a compromised decoder can read one file and do nothing else.

## What upstream already does

Checked in the code, so these are not part of the plan:

- FFmpeg is built decode-only with `--disable-network`, `--enable-protocol=file,pipe`, and allowlists of demuxers, decoders,
  parsers and filters ([build-ffmpeg.sh](../scripts/build-ffmpeg.sh)).
- Zip entries are capped by what they declare (`Zip.maxEntryBytes`).
- The Tauri CSP is strict (`default-src 'self'`, no `unsafe-eval`) and the capability set is `core:default` only.
- The updater requires signed versions.
- The helper watches its parent and exits when it goes (`ParentWatch`), and on Windows the job object does the same.

## Target architecture

```
Tauri UI (WebView2, no file access)
        | typed IPC only
Coordinator (engine core: index, embeddings, search)
        | pipe or stdio, length-prefixed messages
Decoder workers (PDFium, FFmpeg, image and zip readers)   <- sandboxed
```

- The coordinator owns the database, the model, the crawler and the UI. It never parses file contents.
- A worker gets an open read-only file handle and a request ("extract text", "frame at 3s") and returns plain data: UTF-8
  text, a bounded bitmap, PCM audio.
- The UI sends result IDs, not paths. The coordinator looks up the real path.
- Extracted text is untrusted: parameterized SQL, escaped when shown.

## Steps

1. **Worker process.** Move stb, miniz and PDFium out of the engine into a worker with the handle-passing protocol above.
   FFmpeg already runs as its own process, so it moves under the same protocol. Add a per-file timeout and a crash budget: a
   file that crashes a worker is marked unreadable and not retried forever.
2. **Windows sandbox for the worker.** AppContainer with no capabilities, handle passing, process mitigation policies, and a
   job object with a memory cap, kill-on-close and a process limit of 1. Today the job object only closes the helpers with
   the shell. The detail, the stages and what is not covered are in "Windows sandbox for the worker" below. On Linux:
   seccomp-bpf with namespaces or Landlock.
3. **Memory-safe readers where they exist.**
   - Images: `image` with `png`, `zune-jpeg`, `gif`, `tiff`, `image-webp`; `jxl-oxide` for JPEG XL; `kamadak-exif` for EXIF.
     HEIC and AVIF keep using a C decoder inside the sandbox.
   - Compression: `flate2` (with `miniz_oxide`) and `zip`. Upstream already caps what a zip entry may declare
     (`Zip.maxEntryBytes`); keep that, and add a cap on total size and compression ratio.
   - Audio: `symphonia` for common formats. FFmpeg stays for video and rare audio.
   - PDF: try `lopdf` or `pdf-extract` for text first and fall back to PDFium. PDFium stays for rendering.
   - Check each crate's advisories, release cadence and fuzzing before adopting it.
4. **Tighter FFmpeg.** Already done upstream: [build-ffmpeg.sh](../scripts/build-ffmpeg.sh) builds decode-only with
   `--disable-network`, `--enable-protocol=file,pipe` and allowlists of demuxers, decoders, parsers and filters. Nothing to
   add except to run ffmpeg inside the worker sandbox (step 2).
5. **Updates.** Ship the decoders as a separately updatable, signed component. Fail CI when a pinned FFmpeg or PDFium has a
   known critical advisory.
6. **Verification.** Fuzz the worker protocol and decoders. Add tests where a deliberately malicious worker tries to open a
   file, open a socket, or spawn `cmd.exe` and must fail.

Step 1 matters most: the later steps depend on it.

## Windows sandbox for the worker

Step 2 of the plan, in detail. Not built yet. The worker from [decoder-worker.md](decoder-worker.md) is a separate process
but runs with the user's full rights, so an exploited decoder can still read any file the user can. This section is how to
take those rights away.

### Which Windows

Developed on Windows 11 Home (build 26300). Everything below works on every edition, Home included. Windows Sandbox,
Hyper-V isolation, Application Guard and AppLocker or WDAC policy need Pro or higher and are not used: they would not be
there for most users, and a virtual machine is too heavy for a helper that opens thousands of files.

### Approach

Five features that exist on every edition, the same primitives browsers build their sandboxes from:

1. **AppContainer.** The worker runs as a low-privilege app identity with no capabilities. By default it has no network
   access and can read only what its identity has been granted. This is the main boundary.
2. **Handle passing.** The helper opens the file read-only and hands the worker that open handle (a handle list at launch).
   The worker can read that one file and cannot open any other path. This also replaces "the worker opens by path".
3. **Process mitigation policies** set at launch: control-flow guard, no child processes, image loads only from trusted
   places (no remote or low-integrity images), and strict handle checks. No dynamic-code ban: it is not known to be safe
   with PDFium, and it would be turned on only after testing.
4. **A job object:** a memory cap, kill-on-close, `ACTIVE_PROCESS_LIMIT` of 1, and the UI restrictions already set on the
   shell's job.
5. **A launch the Swift side controls.** Foundation's `Process` cannot set any of the above, so the helper starts the worker
   with `CreateProcessW` through `WinSDK`, using a security-capabilities attribute, a handle list and the mitigation
   attributes. The Windows code lives in its own file, separate from the shared client.

### What makes it hard

- **The worker's own files.** A per-user install is in `%LOCALAPPDATA%`, which an AppContainer cannot read by default, so the
  worker cannot load its own `digup.exe` and DLLs. The helper has to grant the AppContainer read and execute on the install
  folder (and on `Vendor\` and `.build\` in development). Expect most of the debugging here.
- **Output.** The worker now writes rendered pages into a temp folder. In an AppContainer it is better to send the image
  bytes back through the pipe than to grant write access anywhere. That moves the protocol from JSON lines to a
  length-prefixed binary frame for images.
- **PDFium's reader.** `FileReader` opens a URL. It needs a variant that wraps an inherited handle.
- **Failure policy.** If the sandbox cannot be created, the worker does not run and the error says why, as with the existing
  rule of no silent fallback. One setting turns the sandbox off for debugging. It is read from the environment, never from
  a file the worker could write.
- **Other software.** Some antivirus products and unusual folder permissions interfere with AppContainers, so it is not the
  default until it has run on more than one machine.

### Stages

Each stage is testable by itself:

1. **Launch through `CreateProcessW`** with the job object and mitigation policies, no AppContainer yet. The smallest step. It
   also moves the helper off `Process`, which the later stages need. **Done.**
2. **Add the AppContainer** and the access grants for the worker's own files. The first real boundary. **Done.**
3. **Add handle passing and image frames.** After this the worker cannot open paths at all. **Done.** Pictures come back as raw bytes after
   the reply line (the line lists their lengths as `blobs`; the client caps each at 256 MB and all at 1 GB), not as base64.
4. **Escape test.** A hostile worker mode that tries to open an unrelated file, make a network connection and start
   `cmd.exe`. It passes only if all three are denied. Without it there is no evidence the sandbox works. **Done:** the
   worker is tested against opening a file it was not handed (with a control that shows the open works outside the
   sandbox), against starting `cmd.exe`, and against a loopback connection (a listener in the test, with the same control).

What stages 2 and 3 do, as built:

- The worker runs as the container `DigUp.DecodeWorker`, with no capabilities.
- The helper grants the container read and execute on the program's own folder and on the folders its loaded DLLs come from
  (found with a module snapshot of the helper, which is the same program as the worker). Windows' own folders are skipped.
  For a parent that is not the worker's program (development, tests), `DIGUP_SANDBOX_DLL_DIRS` names more folders.
- The helper opens the PDF and duplicates the handle into the worker. The worker reads through that handle
  (`FileReader(passedHandle:)`).
- The worker renders into the container's own folder (`AC\Temp` under its profile), sends the picture back, and deletes the
  file. The helper writes it where the caller asked.
- If the container or a grant cannot be made, the worker does not start.

Side effects on the machine, and how to undo them:

- The grants stay on the folders after the run. They name this container only. Each folder granted is written to
  `%LOCALAPPDATA%\DigUp\sandbox-grants.txt`.
- The profile lives in `%LOCALAPPDATA%\Packages\DigUp.DecodeWorker`.
- `digup sandbox-remove [folder...]` takes both away: the container's access from the folders on the list, from any folder
  named on the command line, and from the folders this program would grant itself (which finds grants made before the list
  existed), then deletes the profile and the list. It says what it did, and running it again does nothing and does not fail.
  An installer's uninstall step can call it. The installer does not call it yet.

#### First run on a clean machine

Nothing set up yet: no profile, no grants. What the first run does that later runs do not: make the profile, grant access
on each folder (which needs the right to change that folder's permissions), and make the container's work folder. It can fail
where the user cannot change a folder's permissions (a machine-wide install under `C:\Program Files`), where the drive has no
permissions at all (FAT32, exFAT), or where security software blocks the profile or the permission change. If it fails the
worker does not start, so no PDF, picture or document is indexed with the worker on. The worker is on by default on Windows
anyway (see "Switch" in decoder-worker.md); `DIGUP_ISOLATE_DECODERS=0` turns it off. This will be tested on a separate machine.

Tested here: after `digup sandbox-remove` took everything away, the isolation tests were run again from scratch. They passed in
the same time as before (about 4 seconds), made the profile again, and wrote the list. Not tested: another Windows user
account, a machine-wide install, a non-NTFS drive, security software.

### ffmpeg in the sandbox

ffmpeg and ffprobe (audio, video, and the pictures stb cannot read) run in the same AppContainer, under the same job object and
mitigation policies, as their own process (`FFmpegSandbox+Windows.swift`). When the worker is in use, `FFmpeg.run` does this
instead of starting the program with Foundation's `Process`; if the sandbox cannot be set up, the call fails, with no fallback.

- **The one file it reads is handed over, not opened by path.** The helper opens it and gives the process that handle as its
  standard input, and the call's input argument becomes `-fd 0 -i fd:`. ffmpeg's `fd` protocol reads that descriptor and can
  seek in it, which `pipe:` cannot (an MP4 with its index at the end needs to). In this ffmpeg the descriptor is an option
  (`-fd 0`), not part of the URL (`fd:0` is refused).
- **Output.** What goes to stdout comes back on a pipe, as before. The two calls that write picture files (a video's frames, and
  the frame for a preview) write into a scratch folder inside the container, and the helper moves the files to where the caller
  asked, even when ffmpeg ends with an error (it does for frames it could not decode on the way).
- **Build changes** ([build-ffmpeg.sh](../scripts/build-ffmpeg.sh)): the `fd` protocol is enabled, and the demuxers that recognize
  a picture by its content (`image_webp_pipe`, `image_tiff_pipe`, `image_png_pipe`, `image_jpeg_pipe`, `image_bmp_pipe`). The
  existing `webp_pipe` and the like in that list matched no component of this ffmpeg (its `-demuxers` listed only `image2pipe`),
  and the script's check for names that match nothing did not catch it. Reading a WebP or TIFF by path still worked, through
  `image2`, which goes by the file extension; a handed-over file has none.
- **The environment.** A bare environment made the launch fail with Windows error 203; the process gets the whole environment,
  with `TEMP` and `TMP` pointed at the container's folder.
- **What it is tested against:** the sandboxed ffprobe reads a file it is handed and cannot open the same file by path (with a
  control that shows a plain process can); durations and streams match the outside; a frame written as a file reaches the
  caller's folder; and the HEIC, AVIF, WebP and TIFF pictures come out as they do outside the sandbox.
- **Not covered:** ffmpeg runs with the user's whole environment, and the sandbox limits what a compromised decoder can reach, not
  whether it can corrupt its own output (a wrong picture or sound). No time limit is set on an ffmpeg run, as before (a long
  podcast legitimately takes a while); the job's memory cap (4 GiB) applies.

### Rust decoders (stb and miniz)

`decode-rs/` is a small Rust static library with a C interface ([digup_decode.h](../decode-rs/include/digup_decode.h)) that reads what
stb_image and miniz read for DigUp. They parse files from anywhere, which is what makes a memory-safe language worth having here.
**Windows only for now**: the Swift package links it only there, so macOS and Linux builds are unchanged.

- **Zip files** (docx, odt, xlsx, pptx, ods, odp): `ZipArchive` on Windows is backed by the `zip` crate, with the same interface as
  the miniz class, which is not compiled on Windows. A zip entry comes out as the same bytes whatever reads it, so there is nothing
  to compare except that. The declared size is checked against the limit before anything is allocated, and what is read is cut at
  the limit too, since a declared size can lie. This applies everywhere on Windows, in the helper as in the worker.
- **Pictures** (JPEG, PNG, GIF, BMP, PNM and PSD by their first bytes, TGA by a header the decoder accepts), in the decode worker and
  wherever else `RGBImage.load` is used on Windows: decoded by the `image` crate (`zune-jpeg` for JPEG) and, for PSD, the `psd` crate
  (the merged picture the file carries). A picture the Rust reader recognizes and finds bad is **refused**, and what it does not read
  at all goes to ffmpeg in its sandbox: **stb no longer parses any file on Windows.** What is left of stb there is `stbir` (scaling) and
  `stb_image_write` (PNG and JPEG writing), which work on pixel arrays the Swift code already holds. The PPM that ffmpeg writes and a
  video's frame files are read by the Rust reader too. A PSD in a mode the `psd` crate does not read (CMYK, 16 bits) is reported
  as unreadable, where stb read some of those; the `psd` crate also panics on some malformed files (found by the fuzz test), which is
  caught at the boundary and costs that one file.
- **JPEG vectors (measured 2026-11-17).** `JPEGDecoderVectorTests` prepares each JPEG as the indexer does, once with stb's decoder and once
  with the Rust one, and embeds both. On 39 pictures (Windows' own wallpapers and the test pictures) the cosine between the two vectors is
  0.9995 on average and 0.9987 at worst, with the prepared pictures 0.05 to 0.6 levels apart per value on average. The same picture twice
  gives 1.0000, so this is the decoder and not the model. That is under the 0.999 asked of runtimes for 8 of the 39, and it is a change
  too small to alter what a search returns, so `vectorVersion` stays and an existing index keeps its stb-made vectors beside new
  Rust-made ones. `DIGUP_JPEG_CORPUS` (folders, `;`) measures other pictures.
- **Pixels.** PNG and BMP come out exactly as stb's; GIF is expected to; a JPEG is decoded by another decoder, so its pixels differ by
  a few levels (the test allows a mean difference of under 3 per value). That moves an embedding slightly. The reference-vector test
  does not measure this: it hands the JPEG to llama.cpp's own decoder, so it never goes through decode-rs. Existing indexes are
  therefore still not known to be unaffected; to measure it, embed the same JPEGs through both paths and compare cosines.
- **Memory limits:** a picture of more than 400 million pixels is refused, and the decoder's allocation is capped to match.
- **Build:** `scripts/build-decode-rs.sh` (cargo, in the MSVC environment) builds it into `Vendor/decode`, with `--locked` so only the
  versions in `decode-rs/Cargo.lock` are used. It names MSVC's `link.exe` itself, because Git's bash has a `link.exe` of its own ahead
  of it. The CI workflow and `package-windows.sh` run it (not run in CI here).
- **Supply chain.** 39 crates are in the lock file (`image`, `zip`, `png`, `zune-jpeg`, `flate2`, `miniz_oxide` and their
  dependencies), where the C readers were two vendored source files. `cargo audit` (2026-11-17, advisory DB of that day) found six
  advisories on `zip` 2.6.1, all in `extract`, the stream reader or AES, none of which DigUp uses (it only calls `ZipArchive::new`
  and `by_name`, with only the deflate feature); `zip` is now 9.x anyway and the audit is clean. The crates are pinned, so an update
  is a deliberate change to `Cargo.lock`.
- **Reviewed.** The owner's code review found and fixed five issues in this crate and the Swift around it (a read callback that
  over-reports, an overflow at a limit of `u64::MAX`, output pointers left unset on failure, two handle leaks, and `userenv.dll`
  loaded from a searched path); see the changelog. The three in the Rust crate have a test each; the handle leaks and the DLL load
  have none (no test here can make `seekToEnd` or `_open_osfhandle` fail).
- **A panic does not cross the interface:** each entry point catches it and returns an error code. The crate has a few lines of
  `unsafe` at that boundary (pointers in, a buffer handed out and freed with its length).
- **Tested:** 8 Rust tests (the crate's own: a PNG without its alpha, garbage and truncated files do not panic, a header that
  claims a huge picture is refused, a zip entry is read and a missing one reported, an entry over the limit is refused, a callback that over-reports is an error, a limit of `u64::MAX` does not wrap, and the output
  pointers are cleared on a failed picture); and in the
  Swift tests: which reader handles which format, PNG and BMP pixel-exact against stb, JPEG within the tolerance, a truncated PNG
  refused, and zip entries equal to the bytes that went in.

### Files that could not be read (in the app)

With the worker on by default, one failure can fail every PDF, picture and document, and the app showed no per-file failures. A file
that failed is stored in the index as `failed` with its reason; what was missing was a way to see them and read them again, without
filling the screen with warnings.

**What the user sees** (Settings → Folders, the Windows and Linux shell; the Mac app is not changed):

- Nothing when no file failed.
- One line under the indexing status when some did: "5 files couldn't be read. Review…" No notification, no tray alert, no dialog.
- **Review…** opens a panel in the page: the count, the reasons grouped ("2 × PDF reader couldn't start: sandbox: make container
  failed (Windows error 5)", so a failure with one cause reads as one line), and the files, each with its folder, its reason and a
  **Retry**. **Retry all** reads all of them again, not only those listed. **Close** closes it.
- After a retry, a line in the panel says "Reading 3 files again…" for a few seconds (or "will be read again when indexing runs" while
  indexing is paused or outside its hours). A file that fails again is counted again, once.
- A long list shows the first 500 (the reasons are labelled "Among the first 500"), and says so; Retry all still means all.
- The count is asked together with the folder summaries (when the tab is shown, and at most every two seconds while indexing
  changes), as a plain `COUNT(*)`; the list only while the panel is open. A refresh that changes nothing leaves the list, and its
  scroll position, alone.

**How it works**

- `search-service` answers two new questions: `failures` (the count; the files, up to a limit, only if asked) and `retry` (all, or
  named files, in the main index or the code index), which puts failed files back to waiting with their reason cleared, and returns
  which. `IndexStore` gets `failedCount`, `failedFiles` and `requeueFailed`; only files that are failed are touched.
- The shell's `retry_failed` command asks for the retry, then tells `index-service` (`retry 1,2,3` and `retry code 4,5` on its
  standard input) to read those files now, whether or not backfilling is allowed. If indexing is paused or outside its hours they stay
  waiting and are read when it runs.
- The page is `settings.html`, `settings.js`, `settings.css`. It builds the list with `textContent`, never `innerHTML`, since file names
  and reasons can contain anything.

**Checked**

- 3 Swift tests of the store (counted and listed by path with reasons; only failed files are put back; a file that fails again is
  counted once), and a run of the real `digup search-service` against an index made with failed files: the count alone, the list, retry
  of one file, retry of all, and the database after each.
- The real Settings page, loaded in headless Edge with a stand-in for the Tauri backend: nothing shown with no failures, the line
  with a count, the open panel, a retry of one file (the list and count update, the confirmation shows), and a list of 4,000. That
  harness is not kept in the repository.
- `cargo check` passes for the shell.
- **The retry, with the real model** (EmbeddingGemma 2 from `D:\Users\rahul\AppData\Local\DigUp\Models`, an index under
  `D:\Temp`): three text files and one truncated PNG were indexed (three done; the PNG failed with "can't decode image"); one good
  file was marked failed by hand, as a transient worker failure would leave it; `search-service` listed both failed files and
  `retry all` put both back to waiting. **Control:** `index-service` with background indexing off and no `retry` command read
  nothing, and both stayed waiting. **With** `retry 2,3`: the good file was read and became done, and the bad picture failed again
  and is counted once.

- **In the real shell window** (Tauri's WebView2, driven over its debugging port by `scripts/fork-tests/shell-e2e`): the line "2 files
  couldn't be read" is there, **Review** opens the list with the reasons grouped, **Retry all** closes the panel and says the files are
  being read again, the line comes back with only the picture that is really bad, and the index afterwards is right. Screenshots of
  the real page are in `TEST_ROOT\shell-e2e\shots`. This run found a bug in the sandbox (next section).

**Not checked**

- Not on the Mac, and not in the search panel or tray.

### Under the shell: nested jobs

The shell puts every helper in a job (to end them with it), so the worker's job is nested inside it. Windows refuses to nest a job with
UI restrictions inside one that has them (error 50, "assign to job failed"), and the first version of the sandbox set them in both, so
it did not start at all under the shell, though every standalone run and test was fine. The worker's job now leaves the UI restrictions
out when the helper's own job has them (the worker is bound by the parent's). `scripts/fork-tests/job-nesting.bat` is the regression
test: it runs the helper inside jobs configured like the shell's. It had to be found by running the real shell; a unit test cannot put
its own process in such a job and take it out again.

### Not covered

- A sandbox does not make PDFium correct. It limits what a compromised worker can do: read one file, answer, and be killed.
- The helper itself, which holds the index and the model, is not sandboxed by this.
- A kernel or driver bug can still escape an AppContainer. This lowers the risk a great deal and does not remove it.

## Shell and install

- Tauri: minimal capabilities, strict CSP, no remote content. Upstream already has a strict CSP and `core:default` only.
  Launch outside programs with argument arrays, never shell strings.
- Windows: `SetDefaultDllDirectories` in the shell is done (see [downstream-fork-changes.md](downstream-fork-changes.md)).
  The Swift helper still loads backends from its own folder and is not changed.
- Sign the installer and binaries (Authenticode).

## Status

Done, on top of upstream (each is tagged `DOWNSTREAM-FORK` in the code and listed in
[downstream-fork-changes.md](downstream-fork-changes.md)):

- `SetDefaultDllDirectories` in the shell.
- UI restrictions on the helpers' job object.
- Step 1, first slice: PDFium in a separate `digup decode-worker` process, behind `DIGUP_ISOLATE_DECODERS=1` and off by
  default ([decoder-worker.md](decoder-worker.md)). The full test suite passes with it off and with it forced on for every
  PDF read (122 tests each).

- Windows sandbox, stage 1: the worker is started with `CreateProcessW` under a job object (one process, a memory cap, UI
  restrictions, kill on close) and mitigation policies, with no child processes allowed. Tested: the worker is in the job with
  those limits and cannot start `cmd.exe`.

- Windows sandbox, stages 2 and 3: the worker is an AppContainer, reads only the file it is handed, and writes only in its
  own folder. Stage 4: tested that it cannot open a file it was not handed, start `cmd.exe`, or connect to the loopback
  address, each with a control that shows the action works with the sandbox off.
- Step 1 for pictures (stb) and zip-based documents (miniz): `image.prepare` and `doc.text` in the same worker. The HEIC,
  WebP, TIFF and AVIF pictures go through ffmpeg in the helper, because a sandboxed worker may not start a program. The full
  suite (133 tests) passes with the worker off and forced on.

The two shell changes compile (`cargo check`) but have not been run. The access grants the sandbox adds to folders stay until `digup sandbox-remove` is run (see "Windows sandbox for the worker").

**Visibility of failures is poor** (see "What the user sees when a file fails" in [decoder-worker.md](decoder-worker.md)): the
app shows no per-file failures, so a worker that cannot start fails every PDF, picture and document with no message in the app.
It is written to `decode-worker.log`, and a warning in the app is not built yet.

The worker is **on by default on Windows** in the `digup` program (see "Switch" in [decoder-worker.md](decoder-worker.md)); the
first-run risks below are accepted for now, and will be tested on a separate machine.

**Pending** (what is not done, as of 2026-11-17; the plan's steps are the numbered list under "Steps"):

- **Installer (2026-11-17):** built for the first time (`scripts/package-windows.sh`, `DigUp_0.7.0-beta.3_x64-setup.exe`, 54 MB), installed
  silently to D: (`/S /D=...`), used to index a PNG, a JPEG and a PDF (the sandbox set up from the installed helper folder), and uninstalled
  silently: the install folder, `sandbox-grants.txt` and the `DigUp.DecodeWorker` profile were gone afterwards and the models were not
  touched, so the uninstall hook works. Not tried: the installer's own interface, an update over an older install, the
  "delete the application data" box. To build it here the shell's cargo needs `CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER` set to MSVC's
  `link.exe` (Git's bash has one of its own first on PATH), and `scripts/notices.py` wants `Vendor/llama.cpp/LICENSE`, which a build with
  `LLAMA_SOURCE` set does not make (copy the LICENSE from that clone). **Never run:** the CI workflows' new steps (decode-rs, security).
- **First run on another machine:** the sandbox's setup on a Windows account, a machine-wide install, a non-NTFS drive, or with
  security software, none of which has been tried. Planned as a test on a separate machine.
- **In the app:** the failed-files list is in the Windows and Linux shell's Settings only; not the Mac app, not the search panel or tray.
- **Sandbox:** no Linux sandbox (seccomp or Landlock around the same worker). Scaling and writing what ffmpeg produced is still stb's
  (pixel arrays only, in the helper); it was not moved into ffmpeg, which would change the resampling and so the vectors.
- **Rust readers (step 3):** Windows only (Linux and macOS still use stb or ImageIO); JPEG vectors: measured on 2026-11-17 (see
  "JPEG vectors" under "Rust decoders"): the Rust decoder moves them by a cosine of 0.9987 at worst and 0.9995 on average, below the
  0.999 the reference test asks of runtimes for 8 of 39 pictures. `vectorVersion` was not bumped; old and new vectors of one photo are
  that close.
- **Shell dependencies:** `cargo audit` on `shell/src-tauri` still reports six `zip` 4.6.1 advisories (pulled in by
  `tauri-plugin-updater`, which is not ours to bump; updates are signature-checked) and unmaintained/unsound notes in the GTK/zbus
  stack (Linux only). The rustls, rustls-webpki, webpki-root-certs, tokio and rustix advisories were fixed by `cargo update`.
- **Step 5 (advisories):** `.github/workflows/security.yml` runs `cargo audit` (decode-rs, shell) and `scripts/check-advisories.py` (FFmpeg,
  dav1d, SQLite and PDFium against NVD) on changes and weekly. It has not run in CI; each step was run by hand. Every CVE found for
  the pinned FFmpeg and SQLite is looked at and listed with a reason in `scripts/advisories-acknowledged.txt`; one (FFmpeg
  CVE-2026-107678, a stack exhaustion through the mov demuxer) is reachable and left because the damage is one file in a sandboxed process.
  PDFium was pinned at `chromium/8086`, behind three PDF fixes in Chrome 157.0.8103.38; it is now `chromium/8152` (see the changelog).
- **Step 6 (not done):** signed and separately updatable decoder bundles. Fuzzing: `cargo test` runs a seeded mutation fuzzer over every
  picture format and the zip reader (420,000 inputs run clean on 2026-11-17; the `psd` panics noted above are the only finding), a Swift
  test sends the worker requests of the wrong shape, and `decode-rs/fuzz` has libFuzzer targets that CI runs. The libFuzzer targets compile
  but have not been run. The worker's escape tests now cover a file not handed, a child process, the network, writing a file outside its
  folder, opening another process, writing the user's registry, connecting to a named pipe and opening another process's shared memory;
  each has a control that shows the same worker doing it unsandboxed. The clipboard is covered by the job's UI limits (asserted), not
  tried: `OpenClipboard` succeeds in the worker, and trying to read it would need text on the user's real clipboard. Not covered:
  window and desktop handles, and objects of other users.
- **Smaller:** the `seekToEnd` leak fix in `FileReader` has no test (no handle was found that opens as a descriptor and cannot seek;
  the `_open_osfhandle` fix is tested by handle counting, and that test fails without the fix); Authenticode signing of the installer (needs a certificate). The
  intermittent failure of an existing image test (and of two new ones writing sample files) was not reproduced: eight runs of the
  suite in a row on 2026-11-17 all passed, so the guess that security software scanning new files caused it is neither confirmed nor
  ruled out.

## Development environment

Where the tools are on this machine, since several are installed but not on PATH:

| Tool | Where | Used for |
|---|---|---|
| Swift 6.4.1 | `C:\Users\rahul\AppData\Local\Programs\Swift\Toolchains\6.4.1+Asserts\usr\bin` | the engine and helper (CI uses 6.4.0; the package needs tools 6.2 or later) |
| Rust (stable, MSVC) | `C:\Users\rahul\.cargo\bin` | the Tauri shell |
| MSVC Build Tools 2022 | `D:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` | `vcvars64.bat` for Swift, Rust and llama.cpp |
| MSYS2 | `D:\msys64` (MINGW64 shell) | only `scripts/build-ffmpeg.sh` |
| llama.cpp | built by `scripts/build-llama.sh` from its own pinned tag (`b11461`, patched) | embedding runtime |

Swift needs three things on PATH, none of which are there by default: the toolchain's `usr\bin`, the runtime DLLs in
`C:\Users\rahul\AppData\Local\Programs\Swift\Runtimes\6.4.1\usr\bin` (without them the package manifest's helper program
exits silently and SwiftPM reports "Missing or empty JSON output from manifest compilation"), and the MSVC environment from
`vcvars64.bat`. `vcvars64.bat` also needs `vswhere.exe` on PATH, from `C:\Program Files (x86)\Microsoft Visual Studio\Installer`.
Working order in a `.bat` file:

```
set "SW=C:\Users\rahul\AppData\Local\Programs\Swift"
set "PATH=C:\Program Files (x86)\Microsoft Visual Studio\Installer;%SW%\Runtimes\6.4.1\usr\bin;%SW%\Toolchains\6.4.1+Asserts\usr\bin;%PATH%"
call "D:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cd /d D:\Github\DigUp
swift package dump-package
```

`swift package dump-package` was run this way and loads the manifest. A full `swift build` was not tried: it needs
`Vendor/` from `scripts/fetch-vendor.sh` and `scripts/build-llama.sh` first.

Built so far (2026-11-16): `scripts/fetch-vendor.sh` filled `Vendor/` (SQLite, stb, miniz, PDFium) and
`scripts/build-llama.sh` built llama.cpp `b11461`, patched, CUDA flavor, with MSVC, into `Vendor/llama`. Both ran from Git
for Windows' bash inside the `vcvars64` environment, with `LLAMA_SOURCE=D:\Github\llamaCPP-digup` (a `git clone --shared`
of `D:\Github\llamaCPP`). `scripts/build-ffmpeg.sh` then built ffmpeg 9.0.2 and dav1d 1.5.2 in the MSYS2 MINGW64 shell
(`MSYSTEM=MINGW64 bash -lc scripts/build-ffmpeg.sh`) into `Vendor/ffmpeg/bin`. `swift build --product digup` builds, and
`.build\debug\digup.exe --help` runs with `Vendor\llama\lib` and `Vendor\pdfium\lib` on PATH. `swift test` (with
`Vendor\llama\lib`, `Vendor\pdfium\lib` and `Vendor\ffmpeg\bin` on PATH) is the baseline: 115 tests in 16 suites pass, and
`ReferenceVectorTests.vectorsMatchTheReference` was skipped until the model files were on this machine. It was then run
(2026-11-17, `DIGUP_MODELS` and `DIGUP_BACKENDS` set, CUDA and CPU) and passed: this llama.cpp build (`b11461`) makes the
vectors the reference holds, at cosine 0.999 or more. The full suite with the model is 157 tests, all passing.

On Windows `swift build` deletes the tracked `Package.resolved` (it pins Sparkle, which only the macOS manifest uses). Run
`git restore Package.resolved` after a build so it does not end up in a commit.

To run the model in a dev build (the experiments above): the files are in `D:\Users\rahul\AppData\Local\DigUp\Models` (got with
`digup download-model --to ...`; checked by size and SHA-256), and the helper needs two variables: `DIGUP_MODELS` (that folder) and
`DIGUP_BACKENDS` (`D:\Github\DigUp\Vendor\llama\lib`). Without the second, a dev build finds no compute backends ("no backends are
loaded") because it looks for llama.cpp's backend DLLs beside its own executable, and in a dev build they are in `Vendor`. With both,
the model loads on CUDA and CPU in about 7 seconds.

`D:\Github\llamaCPP` is a separate, newer llama.cpp clone. Do not point `LLAMA_SOURCE` at it: the script checks out its
pinned tag there with `--force`.

The index is in your local app data folder, and the engine cleans up its own scratch files well. The one stranded-file risk is a hard kill, and the real leftover on this machine comes from the project's tests.

## Where the index is stored

On Windows it's `%LOCALAPPDATA%\DigUp\index`, which on this machine is `C:\Users\rahul\AppData\Local\DigUp\index`. The shell can pass a different folder with `--index`.
- **Index files:** `index.sqlite` is the main index, and `code.sqlite` is a separate index for code.
- **Other files beside them:** `costs.json` (measured speeds), the helper logs, and a `previews` folder.
- **Other systems:** on a Mac it's `~/Library/Application Support/DigUp/index.noindex`, and on Linux it's `~/.local/share/digup/index`.
- **Models:** they are looked up in the DigUp folder's `Models` area, then the Hugging Face cache.
- **This machine:** no index exists yet, because we've only run tests. The DigUp folder currently holds only my `sandbox-grants.txt`.

## Temporary files while indexing

- **Per file or batch:** each job's decoded pictures, audio pieces and video frames go in a scratch folder under `%TEMP%\DigUp-<process id>\...`. The code deletes that folder as soon as the job is done.
- **When it exits normally:** the indexer's own scratch folder is removed. What's left is an empty `DigUp-<process id>` shell folder.
- **If the helper is killed or crashes:** files from the job in progress can remain. The next time the index service starts, it deletes the scratch folders of processes that no longer exist (`removeStaleScratchFolders`), and that works on Windows. So they're cleaned up eventually, but only if you index again.
- **Search previews:** they live in `<index>\previews` and are wiped and recreated each time the search service starts. They're bounded in size.

## What's actually on this machine

I counted the `DigUp*` entries in `D:\Temp`: 2,280 of them, about 170 MB.
- **`DigUpTests-*` (1,088 folders, about 164 MB):** these come from the project's own image tests, which never delete their folders. My many test runs produced them. The engine doesn't make them.
- **Other test folders:** `DigUp-PortableDocs-*`, 34 folders, about 1 MB.
- **`DigUp-<process id>` (17 folders, 68 KB):** these are the empty shell folders from the engine. They hold no files.
- **My isolation tests:** they delete their own folders. One empty `DigUp-Decode-*` folder is left from the test run I had to kill earlier.

## The new sandbox's scratch folder

The worker deletes each rendered image right after sending it, and the folder (`…\Packages\DigUp.DecodeWorker\AC\Temp`) has 0 files now. If the worker is killed in the middle of a render, one file could stay there, and nothing sweeps that folder. `sandbox-remove` deletes it, but that's not routine cleanup.

You can delete the test leftovers safely. I haven't deleted anything, since they're in your temp folder. If you want, I can clear the `DigUp*` test folders from `D:\Temp`, and also add a small sweep of the worker's scratch folder when the worker starts.

## Open questions

- Can the existing shell-to-helper protocol carry decoder requests? Probably not as it is: it is one JSON line per request
  to a long-lived service. A decoder worker is a different shape (a file handle in, bytes out, many per second), so it needs
  its own small protocol, modelled on `digup worker`.
- Does the engine's Swift code need to change to pass an open handle, not a path? Today every decoder takes a path (stb and
  FFmpeg) or reads through `FileReader` (PDFium). Handle passing is a change in each of them.
- **Is `lopdf` worth using as a first pass for PDF text? Not evaluated.** It was suggested from memory, and nothing has been
  tested on DigUp's files.
  - *What it is:* a pure-Rust PDF library for structure (merge, split, rotate, metadata). `pdf-extract` is built on it.
  - *Why it can't replace PDFium:* the engine uses PDFium for page text and to render pages as images when they are scans
    or slides ([PDF+Portable.swift](../Sources/DigUpKit/Platform/Portable/PDF+Portable.swift)). `lopdf` does no rendering.
  - *Known weaknesses:* complex fonts (missing or garbled text, which quietly hurts search), and strictness about malformed
    PDFs, which are the files DigUp meets most. Those would fall back to PDFium, so they still reach the C++ parser. Pure
    Rust also does not rule out hangs or huge allocations on hostile input.
  - *Best case:* a text-only fast path that keeps well-formed PDFs away from PDFium. The sandboxed worker (steps 1 and 2)
    matters more.
  - *How to decide:*
    1. Collect a PDF corpus: the testbed from `scripts/make-testbed.sh` plus real files.
    2. Extract text with `lopdf` or `pdf-extract` and with PDFium. Compare coverage (empty or failed results) and quality
       (garbled text).
    3. Count how many files fall back to PDFium.
    4. Measure time and memory, and test malformed files for hangs and blow-ups.
    5. Check its advisory history and release cadence.
  - *Outcome:* if the fallback rate is high or the text is clearly worse, drop it and keep PDFium alone inside the sandbox.
- Whether the workers are written in Swift or Rust. Rust removes Swift and C interop from the sensitive boundary but adds a
  second language to the engine.
