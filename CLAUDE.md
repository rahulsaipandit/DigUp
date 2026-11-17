# Notes for Claude on this repository

## Use the D: drive, not C:

The owner prefers that anything a program lets you place with a path parameter, option or environment variable goes on **D:**,
in a folder that mirrors the C: location. On this machine D: already mirrors C: (for example, Python is under
`D:\Users\rahul\AppData\Local\Programs`), so the pattern is `C:\Users\rahul\...` → `D:\Users\rahul\...`.

Where this applies, and what has been used:

| What | C: default | Use instead |
|---|---|---|
| DigUp's model files (about 865 MB) | `%LOCALAPPDATA%\DigUp\Models` | `D:\Users\rahul\AppData\Local\DigUp\Models` (`digup download-model --to ...`; point DigUp at it with `DIGUP_MODELS`) |
| DigUp's index | `%LOCALAPPDATA%\DigUp\index` | `D:\Users\rahul\AppData\Local\DigUp\index` (`--index DIR` on any `digup` command) |
| Build output, scratch, caches | — | `D:\Temp` and this repository's `.build` and `Vendor` (already on D:); pass `--target-dir D:\Temp\...` to cargo |
| MSYS2 | `C:\msys64` | `D:\msys64` (installed there) |

Not movable by a parameter, so left where Windows or the program puts it (say so instead of working around it):

- `%LOCALAPPDATA%\DigUp\sandbox-grants.txt` and `decode-worker.log`: DigUp's own folder is fixed by `AppPaths`, which reads
  `LOCALAPPDATA`. Changing that variable would move everything else too, so don't set it just for this.
- The decode worker's AppContainer profile (`%LOCALAPPDATA%\Packages\DigUp.DecodeWorker`): Windows decides where it goes.
- Rust's `~/.cargo` and `~/.rustup`, and the Swift toolchain, are the owner's existing installs on C:.

Before you download or write something large, check whether a parameter lets you put it on D:, and use it. If one doesn't, tell the
owner where it will land.

## Running the model in a dev build

The model files are in `D:\Users\rahul\AppData\Local\DigUp\Models`. Set `DIGUP_MODELS` to that folder, and `DIGUP_BACKENDS` to
`D:\Github\DigUp\Vendor\llama\lib` (a dev build otherwise finds "no backends are loaded"), and put `Vendor\llama\lib`,
`Vendor\pdfium\bin`, `Vendor\ffmpeg\bin` and the Swift runtime folder on PATH. Use a throwaway index under `D:\Temp` (`--index`) for
experiments, not the real one. More in "Development environment" in `docs/design.md`.

## Working in this fork

- Changes the fork makes on top of upstream are tagged `DOWNSTREAM-FORK` in the code and listed, newest first, in
  `docs/downstream-fork-changes.md`. Add an entry there for every change, and tag it in the code.
- `docs/design.md` is the plan and the status (what is done, what is not, what was checked and what was not). Keep it true.
- Where the tools are on this machine, and how to build and test (Swift, Rust, MSVC, MSYS2 for ffmpeg), is in the
  "Development environment" section of `docs/design.md`. None of them is on PATH by default for a build.
- `swift build` deletes the tracked `Package.resolved` on Windows; run `git restore Package.resolved` afterwards.
- Don't commit or push unless asked.
