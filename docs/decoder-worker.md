# Decoder worker: design

Step 1 of [design.md](design.md). Run the C decoders in a separate, killable process, so a bug in one cannot touch the
index or the model, and so a later step can sandbox that process. This document covers the first slice (PDF) and what comes
after it.

## What exists today

PDFs are read in three places, all through `PDFium` in
[PDF+Portable.swift](../Sources/DigUpKit/Platform/Portable/PDF+Portable.swift), in the helper's own process:

| Call | Used by | What it does |
|---|---|---|
| `PDFExtractor.pages(of:range:minText:renderPixels:to:)` | `Indexer` (indexing) | page text, or a rendered PNG for scans, plus the page count and title |
| `PDFExtractor.renderPage(_:of:pixels:to:)` | `PreviewImages` (search-service) | one page as a JPEG |
| `Estimator.pages(of:)` | the estimate | the page count |

`pages` takes a closure for the page range, because the range depends on the page count. A closure cannot cross a process
boundary, so the protocol splits it: ask for the count, then ask for an explicit range.

## Shape

```
helper process (index-service, search-service, estimate)        decode worker (digup decode-worker)
  PDFExtractor.pages(...)  --  DecodeClient  --JSON lines-->      DecodeWorker.run()
                                (one child, restarted)             runs the same PDFium code, in its own process
```

- The worker is the same `digup` executable run as `digup decode-worker`, like `digup worker` is for the model.
- The worker runs the **existing** PDFium code unchanged. The client is a thin layer in front of three functions. Each
  function gets a short guard at its top: if isolation is on, ask the worker, else run as before. That keeps the diff
  small and easy to re-apply after an upstream sync, and keeps upstream's behavior as the default.
- The worker is started with isolation turned off in its own environment, so it runs the direct code and never starts a
  worker of its own.

## Protocol

One JSON object per line, in each direction, one request at a time (the PDFium code is already serialized by a lock).

Requests (`id` is echoed back):

| `op` | Fields | Reply fields |
|---|---|---|
| `pdf.count` | `path` | `total` |
| `pdf.pages` | `path`, `from`, `to`, `minText`, `pixels`, `folder` | `pages`, `total`, `title` |
| `pdf.render` | `path`, `page`, `pixels`, `out` | `image` (with a work folder) |
| `image.prepare` | `path`, `maxPixel`, `minSide`, `png`, `folder` | `width`, `height`, `taken`, and `image` or `path`; or `route: ffmpeg` |
| `doc.text` | `path` | `text` |
| `quit` | | `ok` |

`pdf.pages` returns `pages` as `[{number, text, imagePath, ocr, garbled}]`. Rendered page images are written by the worker
into `folder`, which the coordinator made, and are returned by path, as today. Sending pixels through the pipe would add
megabytes of base64 per page for no gain.

A picture the worker has to send back (it has a folder of its own and cannot write where the helper reads) follows the reply line as
raw bytes. The line lists the lengths as `blobs` (an array of integers) and each page item that has a picture says which one (`blob`,
an index); `image.prepare` and `pdf.render` have one. The client reads exactly those bytes, and refuses a list with a negative or
oversized entry (256 MB each, 1 GB together, 4096 entries) or bytes that do not arrive.

Every reply has `ok`. On failure: `{ok: false, kind: "locked" | "unreadable" | "other", error: "..."}`. The client turns
`locked` into `ExtractError.locked` and the rest into `ExtractError.unreadable`, so the indexer's existing handling applies.

## Failure handling

- **Crash or exit.** The pipe closes before a reply. The client throws `ExtractError.unreadable("PDF reader stopped")`,
  drops the child, and starts a new one on the next request. The indexer already records `unreadable` and goes on, so a
  poison PDF costs one file and not the run.
- **Hang.** Each request has a timeout (default 180 s, `DIGUP_DECODE_TIMEOUT` to change it). On expiry the client kills the
  child and throws as above.
- **Start failure.** If the worker cannot be started, the request throws `unreadable`. It does not fall back to reading in
  process: a silent fallback would turn the isolation off exactly when something is wrong.
- **Parent exit.** The worker uses `ParentWatch` like the other helper modes, so it ends when the helper does.

## What the user sees when a file fails

Not much, and that is a gap, not a design:

- A file the worker cannot read is recorded in the index as `failed` with the reason (`unreadable: ...`). `digup status` shows
  counts by state. The desktop app shows no per-file failures: its "No access" label is for folders, not files. The user
  documentation says only that an unreadable file "is skipped, and the rest go on."
- A worker that **cannot start** (the sandbox cannot be set up, the helper cannot be found) fails every PDF, picture and
  document in the same way, one by one, with nothing in the app to say so. To leave a trace, the reason is written to
  `decode-worker.log` in DigUp's folder (`%LOCALAPPDATA%\DigUp` on Windows), once for each reason in each process, with the
  time; `digup status` prints the log's path once there is one.
- The page count in an estimate falls back to one page, quietly, as it did when a PDF would not open.
- **In the app (Windows and Linux shell):** Settings → Folders shows one quiet line, "N files couldn't be read. Review…", only when
  there are any, and a list to open: each file with its reason, a Retry for it, and Retry all (see "Files that could not be read" in
  [design.md](design.md)). Not on the Mac, whose app has no such list yet. Nothing interrupts: no notification, no tray alert.

## Switch

`DIGUP_ISOLATE_DECODERS` decides: `1` is on, `0` is off. With it unset, the worker is **on by default on Windows, in the
program named `digup`** (the helper and its command line), and off everywhere else:

- **Not on other systems:** Linux has the separate process and a timeout but no sandbox yet, and has not been run here.
- **Not in other programs:** a test runner would start itself as the worker. So `swift test` is unchanged, and the tests
  that use the worker turn it on for themselves.
- **A worker starts with `0`,** so it reads in its own process.

If the sandbox cannot be set up, the worker does not start, and the files it would have read are reported as unreadable
with the reason (for example "PDF reader couldn't start: sandbox: make container failed (Windows error N)"). Set
`DIGUP_ISOLATE_DECODERS=0` to index without the worker. The page count in an estimate is the one place a failure is quiet:
it falls back to one page, as it always did when a PDF would not open.

## What this slice does not do

- **The sandbox is Windows only.** On Windows the worker is an AppContainer under a job object and mitigation policies,
  reads only the file it is handed, and writes only in its own folder (see "Windows sandbox for the worker" in
  [design.md](design.md)). On other systems it is a separate process with a timeout and nothing more, until a Linux sandbox
  exists.
- **Images come back as base64 in the JSON reply,** not as binary frames. It works, and a page picture can make a reply of a
  few megabytes. Binary frames are a later change if that shows up as slow.
- **PDF, pictures and zip-based documents are in the worker; ffmpeg runs in a sandbox of its own.** `image.prepare` (stb) and
  `doc.text` (zip-based documents) follow the PDF's shape. On Windows those readers are Rust (see "Rust decoders" in
  [design.md](design.md)), not stb and miniz, for JPEG, PNG, GIF, BMP and zip files. A picture is read whole into the worker's memory
  (at most 512 MB) and decoded from there, because stb opens paths. What stb cannot read (HEIC, WebP, TIFF, AVIF) needs ffmpeg,
  which is a program of its own and not something a sandboxed worker may start: the worker says so (`route: ffmpeg`), and the
  helper runs ffmpeg, in its own container process on Windows (see "ffmpeg in the sandbox" in [design.md](design.md)), then
  scales and writes the result with stb in the helper. So stb still runs in the helper on what ffmpeg produces, and on the
  frames ffmpeg writes for videos.
- **One worker.** Requests are serialized. That matches today's lock around PDFium. A pool is a later change if PDF reading
  becomes the bottleneck.

## Checks

- A test reads the same PDF directly and through the worker and compares pages, text, total and title.
- The existing long-PDF indexing test runs with isolation on and must give the same results.
- A test kills the worker mid-run (or points the client at a missing executable) and checks the error is `unreadable`, the
  next request still works, and nothing hangs.
