# DigUp on this machine: build, install and run

The model files are in `D:\Users\rahul\AppData\Local\DigUp\Models`; the Vendor libraries and the Swift engine are already built. The
index every app and the CLI use is `D:\Users\rahul\AppData\Local\DigUp\index`. The tools' locations and how to set up a shell are in
"Development environment" in [design.md](design.md).

**Contents:** [Searching inside folders](#searching-inside-folders-fork) · [Which way to build and run](#which-way-to-build-and-run) ·
[Run the app from source](#run-the-app-from-source-fast-loop) · [Two installers](#two-installers-local-and-production) ·
[CLI](#cli-for-quick-runs) · [Parent folder or the individual folders](#parent-folder-or-the-individual-folders) ·
[Defender exclusion](#local-dev-faster-builds-with-a-defender-exclusion-optional)

## Searching inside folders (fork)

Put `folder:` and complete paths in the query to search only inside them; subfolders are included. A comma separates several paths, and a path with a space goes in quotes:

```
receipts folder:"D:\RP_Backup\RP_Bak_Photos_Videos\Photos"
receipts folder:D:\Photos,E:\Scans
receipts folder:"D:\My Photos", "E:\Old Pictures"
```

Only complete paths work (`folder:Receipts` is not understood, and the status line says so). The paths may be written as Explorer shows them, in any case. If a folder holds nothing indexed, or a path with a space was left unquoted, the status line names it. `folder:` alone, with no words, asks what to look for.

## Which way to build and run

| I want to… | Use | Time per change |
|---|---|---|
| Try a UI or shell change against my real photos | [Run the app from source](#run-the-app-from-source-fast-loop): the "DigUp (dev)" shortcut | about 10 s |
| Try the packaged app (installer, install folder, uninstall) without touching the real one | [Local installer](#steps-local-build) | about 3.5 min |
| Update the app I keep | [Production installer](#steps-production-build) | about 7 min |
| Search or index from the command line | [CLI](#cli-for-quick-runs) | — |

Only one DigUp app can run at a time: they share the index folder and the hotkey (see [Things to know about running both](#things-to-know-about-running-both)).

## Run the app from source (fast loop)

Builds the shell in debug mode and runs it against the real index and models, so nothing has to be re-indexed. It quits the installed
DigUp first (shared index, one hotkey, and a running exe cannot be rebuilt) and does not restart it.

**The easy way: the desktop shortcut "DigUp (dev)"**, or from any PowerShell window (VS Code is not needed):

```powershell
D:\Github\DigUp\scripts\dev-shell.ps1             # quit DigUp, cargo build (about 10 s after the first), start the dev build
D:\Github\DigUp\scripts\dev-shell.ps1 -NoBuild    # start the last dev build as it is
```

[scripts/dev-shell.ps1](../scripts/dev-shell.ps1) sets `DIGUP_BACKENDS` and PATH (a dev build otherwise finds "no backends are loaded"),
links the helper folder the first time, and starts `digup-shell.exe` with `--index` and `--models`. If the build fails, the window stays
open with the error. The shortcut runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\Github\DigUp\scripts\dev-shell.ps1`;
to recreate it, make a shortcut with that target.

**The other shortcuts ("DigUp", "DigUp (D drive)", the Start menu entry) start the installed copy, not this build.** `cargo build` never
changes it; only an installer does. After an edit, use "DigUp (dev)" again: the files in `shell\ui` are built into the program, so a
refresh does not pick them up.

By hand, the same thing (Quit DigUp first):

```powershell
cd D:\Github\DigUp\shell\src-tauri
cargo build --target-dir D:\Temp\digup-shell-target

$env:DIGUP_BACKENDS = 'D:\Github\DigUp\Vendor\llama\lib'
$env:PATH = 'D:\Github\DigUp\Vendor\llama\lib;D:\Github\DigUp\Vendor\pdfium\bin;D:\Github\DigUp\Vendor\ffmpeg\bin;' + $env:PATH
D:\Temp\digup-shell-target\debug\digup-shell.exe --index "D:\Users\rahul\AppData\Local\DigUp\index" --models "D:\Users\rahul\AppData\Local\DigUp\Models"
```

- The shell looks for its helper in a `helper` folder beside the exe; the script makes a junction to `shell\src-tauri\helper`
  (by hand: `mklink /J D:\Temp\digup-shell-target\debug\helper D:\Github\DigUp\shell\src-tauri\helper` in Command Prompt).
- Without `--index` it would use `DIGUP_INDEX` or the default under `%LOCALAPPDATA%` on C:, so always pass `--index` here.
- A launch with `--index` counts as a dev run: it does not add the open-at-login entry.

## Two installers: local and production

[scripts/build-installer.bat](../scripts/build-installer.bat) builds two different apps from the same source. Run it from a normal Command
Prompt or PowerShell, from `D:\Github\DigUp`; it sets up Swift, MSVC and the linker itself. Each installer is copied to
`scripts\scratch\` (git-ignored), because the next build of that profile deletes the bundle folder it came from.

| | **Local** (for trying things) | **Production** (the one you keep) |
|---|---|---|
| Build | `scripts\build-installer.bat local` | `scripts\build-installer.bat production` |
| Installer | `scripts\scratch\DigUp Local_0.7.0-beta.3_x64-setup.exe` | `scripts\scratch\DigUp_0.7.0-beta.3_x64-setup.exe` |
| App identity | `com.abdurrahim.DigUp.local`, "DigUp Local" | `com.abdurrahim.DigUp`, "DigUp" |
| Own settings, uninstall entry, install folder | yes, apart from production's | yes |
| Default index (built in) | `D:\Users\rahul\AppData\Local\DigUp\index`, the permanent index (shared with production: don't run both at once) | `D:\Users\rahul\AppData\Local\DigUp\index`, the permanent index |
| Default models (built in) | `D:\Users\rahul\AppData\Local\DigUp\Models` | the same folder |
| Rust release profile | thin LTO, 16 code-generation units | full LTO, 1 unit (as upstream) |
| Cargo target folder | `D:\Temp\digup-shell-target-local` | `shell\src-tauri\target` |
| Installer compression | zlib | LZMA |
| Install it to | `D:\Users\rahul\AppData\Local\DigUp-Local` | `D:\Users\rahul\AppData\Local\DigUp` |

`scripts\build-installer.bat both` builds one after the other.

### Installing: use the script

**Quit the app before installing, or the install silently does nothing.** The installers are silent (`/S`), and Windows cannot replace a
program that is running: with DigUp open, the install reports success but keeps the old `DigUp.exe` (this is how an installer with a new
UI once left the old UI in place). [scripts/install-installer.ps1](../scripts/install-installer.ps1) does the safe thing: it stops the app
and its helpers, installs, checks that the installed `DigUp.exe` changed (and warns if it did not), and starts the app with `--index` and
`--models`.

```powershell
cd D:\Github\DigUp
scripts\install-installer.ps1                    # production → D:\Users\rahul\AppData\Local\DigUp, starts it afterwards
scripts\install-installer.ps1 -Profile local     # DigUp Local → ...\DigUp-Local, does not start it (add -Launch to)
```

It installs the newest matching installer in `scripts\scratch\` (not the bundle folder, which the next build deletes), so build first.
The warning "byte for byte the same" is expected when the installer is the build you already had.

### Steps: local build

```powershell
cd D:\Github\DigUp
scripts\build-installer.bat local
scripts\install-installer.ps1 -Profile local -Launch
```

By hand instead (quit "DigUp Local" from the tray first; `/D=` must be the last argument and the path has no quotes):

```powershell
& "D:\Github\DigUp\scripts\scratch\DigUp Local_0.7.0-beta.3_x64-setup.exe" /S /D=D:\Users\rahul\AppData\Local\DigUp-Local
```

Run it from the Start menu or `D:\Users\rahul\AppData\Local\DigUp-Local`. With no arguments it uses the **permanent index**
`D:\Users\rahul\AppData\Local\DigUp\index` (so it is not empty: your photos are already in it). Its settings are separate, so it may
ask for its folders on first run; `--index` and `--models` still override.

### Steps: production build

```powershell
cd D:\Github\DigUp
scripts\build-installer.bat production
scripts\install-installer.ps1
```

By hand instead (quit DigUp from the tray first):

```powershell
& "D:\Github\DigUp\scripts\scratch\DigUp_0.7.0-beta.3_x64-setup.exe" /S /D=D:\Users\rahul\AppData\Local\DigUp
```

Run it from the Start menu or the desktop shortcut `DigUp (D drive).lnk`. It uses the permanent index with no arguments. The shortcut also
passes `--index` and `--models` explicitly, as a precaution against a regression in the built-in defaults; a launch with `--index`
counts as a dev run, so it does not add the open-at-login entry (the Start menu entry does).

For the permanent Photos and Videos folders, give it only the folders:

```powershell
& "D:\Users\rahul\AppData\Local\DigUp\DigUp.exe" --roots "D:\RP_Backup\RP_Bak_Photos_Videos"
```

In Command Prompt, drop the `&` (and the quotes if the path has no spaces). Installing does not touch the index or models folders.

### Why the local build is built the cheaper way

A trial app does not need to be as small or as fast as the one you keep, so the local build trades a larger, slightly slower program for
a shorter wait. Three things make the full build slow, and each is changed for local only:

1. **The final compile of the shell** ("Building 523/524: digup-shell"). The release profile in `shell/src-tauri/Cargo.toml` asks for
   `lto = true` and `codegen-units = 1`: after all 523 dependencies are compiled, one thread re-optimizes the shell and every dependency
   together. The local build overrides these with `CARGO_PROFILE_RELEASE_LTO=thin` and `CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16`, which
   run in parallel. The program comes out somewhat larger and slower; the app does not depend on that.
2. **A separate target folder.** A changed profile makes cargo rebuild every dependency. If both builds shared `shell\src-tauri\target`,
   each switch between them would redo all 523. The local build uses `D:\Temp\digup-shell-target-local`, so each profile keeps its own
   up-to-date cache. The first local build is a full rebuild; the ones after it are not.
3. **`makensis` packing.** It compresses about 220 MB (the `helper` folder: llama.cpp's CUDA backend, ICU, the Swift runtime, ffmpeg)
   with LZMA on one core. Local uses zlib: a bigger installer, a much shorter step. This is not about the model: the 865 MB model files
   are not in the installer at all, they are downloaded to `...\DigUp\Models`. What is compressed are DLLs and `.exe` files, which
   compress well, so LZMA is worth its time only for the installer you keep.

**Why not `--no-bundle` for local?** `tauri build --no-bundle` skips `makensis` entirely and leaves only `target\release\DigUp.exe`.
That is no longer an installer: no install folder, no uninstall entry, no `sandbox-remove` on uninstall, and the `helper` folder must sit
beside the exe (or be given with `--helper`). The local app is meant to be installed and uninstalled like the real one, so it is not
used; [Run the app from source](#run-the-app-from-source-fast-loop) is the quick loop instead.

### Why production is left as upstream ships it

The production app is the one you keep and may update from, so it keeps upstream's settings: full LTO and one code-generation unit
(smaller, faster program) and LZMA (a smaller installer). The long build is paid once per release, not per experiment. Only the default
folders differ from upstream, and `--index` / `--models` still override them.

### Which folder an app uses

The built-in defaults are compiled in (`DIGUP_BUILD_INDEX` and `DIGUP_BUILD_MODELS`, set by the script). They win over the user
variables `DIGUP_INDEX` and `DIGUP_MODELS`, deliberately: with `DIGUP_INDEX` set to the permanent index, the local app would otherwise
use it. The order for the index is `--index`, then the built-in default, then `DIGUP_INDEX`, then `%LOCALAPPDATA%\DigUp\index` on C:.
The defaults are paths on this machine, so an installer built here is for this machine only.

### Things to know about running both

- **The index is shared.** Both apps default to the permanent index now, so running both at once would have two apps indexing into one
  folder. Run one at a time; the install script warns when the other is running.
- **One hotkey.** Both register Ctrl+Shift+Space (or pass `--hotkey` to one).
- **The decode sandbox is shared.** Both use the same AppContainer profile (`DigUp.DecodeWorker`). Uninstalling one runs
  `digup sandbox-remove`, which removes that profile for the other too. Not tested: whether the other recreates it on its next start.
- **Not tried:** running the two together, or uninstalling one. The local app's installed exe is expected to be named `DigUp Local.exe`
  (the Tauri config gives both `DigUp.exe`; check after installing).

### Launch arguments (both apps)

| Argument | What it sets |
|---|---|
| `--index DIR` | the index folder |
| `--models DIR` | the model files (passed to the helper as `DIGUP_MODELS`) |
| `--roots "D:\a;D:\b"` | the folders to search and keep indexed, separated by `;`. This skips the setup screen. |
| `--settings FILE` | the settings file |

- **Without `--roots`:** the app uses the folders you pick in its setup and Settings screens, stored in its settings file.
- **A different index per set of folders:** start the app with a different `--index` (and `--settings`) each time.

### How long the builds take

Single runs on this machine, not a controlled benchmark:

| Build | Result |
|---|---|
| Local, first build in an empty `digup-shell-target-local` (all 523 crates compiled, thin LTO) | 3 min 31 s from start to the copied installer; cargo took 2 min 29 s |
| Production (full LTO, LZMA), dependencies already built | about 7 min from start to the copied installer (10:40 to 10:47); the shell's final compile alone was 3 min 11 s in the first installer build |
| Dev build of the shell (`cargo build`, debug), after a UI edit | about 10 s |

The local installer is 113 MB (zlib) against 93 MB for the same files with LZMA. A later local build, with its dependencies already
compiled, should be shorter than the first; that was not timed. The production and local figures were not measured under the same
conditions (the production run had its dependencies built already, the local run did not), so the real saving is larger than the
table suggests.

## CLI for quick runs

[scripts/dev-run.bat](../scripts/dev-run.bat) sets PATH, `DIGUP_MODELS` and `DIGUP_BACKENDS`, then runs `digup.exe` with
`--index D:\Temp\digup-dev-index`, a **throwaway** index (the apps default to the permanent one). Every argument you pass goes on to
`digup.exe`. Set `INDEX` (or `MODELS`) in the environment to use another folder. Without `--index`, `digup.exe` itself would use
`%LOCALAPPDATA%\DigUp\index` on C:, but the script always passes one, so choose the folder with `INDEX`.

```bat
scripts\dev-run.bat --help                  prints the CLI help
scripts\dev-run.bat status
scripts\dev-run.bat index D:\some\folder --limit 20
scripts\dev-run.bat search zebra -n 5
set BUILD=1 && scripts\dev-run.bat status   rebuild the CLI first (swift build --product digup)
```

Tests: `swift test`, in the same environment (the full suite was 157 tests with the model).

**The CLI and the apps can share one index.** Point the CLI's `INDEX` at the app's index folder; the app keeps it up to date and the CLI
can search it. Not tried: running both at once. Running `index` again later only syncs what changed, then embeds what's new.

```powershell
$env:INDEX = "D:\Users\rahul\AppData\Local\DigUp\index"
D:\Github\DigUp\scripts\dev-run.bat index D:\RP_Backup\RP_Bak_Photos_Videos
D:\Github\DigUp\scripts\dev-run.bat search sunset beach -n 10
D:\Github\DigUp\scripts\dev-run.bat status
```

(From Command Prompt, or for one command: `cmd /c "set INDEX=D:\Users\rahul\AppData\Local\DigUp\index && D:\Github\DigUp\scripts\dev-run.bat status"`.)

**A throwaway index:** set nothing; it goes to `D:\Temp\digup-dev-index`, safe to delete later. For a separate one each time, set
`$env:INDEX = "D:\Temp\digup-try-1"`.

```powershell
D:\Github\DigUp\scripts\dev-run.bat index D:\SomeTestFolder --limit 20
D:\Github\DigUp\scripts\dev-run.bat search zebra
```

- **Video indexing time:** the first pass can be long. `digup estimate D:\Photos D:\Videos` shows the expected time before you commit.
- **Reusing an index:** use the same model files. A different model would need a re-index.
- **Subfolders:** the crawler walks every folder you give it, including all subfolders, and guards against a folder inside another root being
  walked twice (`foundRoot` in [Crawler.swift:54](../Sources/DigUpKit/Crawler.swift#L54); read, not run). So a parent and its children give the same index:

```powershell
D:\Github\DigUp\scripts\dev-run.bat index D:\RP_Backup\RP_Bak_Photos_Videos
D:\Github\DigUp\scripts\dev-run.bat index D:\RP_Backup\RP_Bak_Photos_Videos\Photos D:\RP_Backup\RP_Bak_Photos_Videos\Photos_Videos
```

## Parent folder or the individual folders?

For a permanent index: with a parent such as `D:\RP_Backup\RP_Bak_Photos_Videos` that holds `Photos` and `Photos_Videos`, does it matter whether you pass the parent or the children? It barely matters for the first result, but passing only the parent is simpler.

**The difference shows up on later runs.** A sync removes index entries for files that are gone from the folders you pass. It only touches files under the folders you pass this time ([Indexer.swift:92](../Sources/DigUpKit/Indexer.swift#L92)):
- **Parent folder:** new subfolders you add later get picked up automatically. A sibling folder you left out is never indexed.
- **Individual folders:** a new subfolder is ignored until you add it. Any other file in the parent that isn't in those subfolders (loose files, other folders) is skipped.
- **Keeping an index entry:** don't drop a folder from a later run and expect its entries to stay. Files from a folder you no longer pass are kept, because the run only checks the folders you pass. Files deleted from inside a folder you do pass are removed from the index.
- **A drive that is unplugged:** the code keeps its entries rather than treating them as deleted.

**Passing the parent is the better choice if you want everything in it.**
Use the same command every time, so the index follows what's on disk:

```powershell
$env:INDEX = "D:\Users\rahul\AppData\Local\DigUp\index"
D:\Github\DigUp\scripts\dev-run.bat index D:\RP_Backup\RP_Bak_Photos_Videos
```
If the parent holds other stuff you don't want indexed (documents, installers), pass only `Photos` and `Photos_Videos`.

## Local dev: faster builds with a Defender exclusion (optional)

Defender scans every file a build writes (thousands of small files from Rust and Swift) and each new `.exe` and `.dll` the linker
and `makensis` produce. Excluding the build output folders removes that cost. How much it saves here has not been measured.

The trade-off: nothing inside an excluded folder is scanned, so a malicious dependency or build script that writes there would not
be flagged. Keep the list to build output only:

- `D:\Github\DigUp\shell\src-tauri\target`
- `D:\Github\DigUp\.build`
- `D:\Temp\digup-shell-target` (the dev build of the shell)
- `D:\Temp\digup-shell-target-local` (the local installer's cargo target folder)
- `D:\Temp\shell-check` (the `--target-dir` used for `cargo check`)

Do not exclude `D:\Github\DigUp` as a whole, `D:\Temp`, or `D:\Users\rahul\AppData\Local\DigUp` (the installed app, the index and the
models).

Add them in Windows Security → Virus & threat protection → Manage settings → Exclusions, or in an administrator PowerShell:

```powershell
Add-MpPreference -ExclusionPath "D:\Github\DigUp\shell\src-tauri\target","D:\Github\DigUp\.build","D:\Temp\digup-shell-target","D:\Temp\digup-shell-target-local","D:\Temp\shell-check"
```

This does not speed up the `makensis` step ("Running makensis to produce ...-setup.exe"). That step compresses the ~220 MB `helper`
folder with LZMA on one core (zlib in the local build), and antivirus is not what slows it. To list or remove the exclusions later:
`Get-MpPreference | Select ExclusionPath` and `Remove-MpPreference -ExclusionPath <path>`.
