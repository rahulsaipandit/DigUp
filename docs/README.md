# DigUp on this machine: build, install and run

The model files are in `D:\Users\rahul\AppData\Local\DigUp\Models`; the Vendor libraries and the Swift engine are already built.

## Searching inside folders (fork)

Put `folder:` and complete paths in the query to search only inside them; subfolders are included. A comma separates several paths, and a path with a space goes in quotes:

```
receipts folder:"D:\RP_Backup\RP_Bak_Photos_Videos\Photos"
receipts folder:D:\Photos,E:\Scans
receipts folder:"D:\My Photos", "E:\Old Pictures"
```

Only complete paths work (`folder:Receipts` is not understood, and the status line says so). The paths may be written as Explorer shows them, in any case. If a folder holds nothing indexed, or a path with a space was left unquoted, the status line names it. `folder:` alone, with no words, asks what to look for.

## Two installers: local and production

[scripts/build-installer.bat](scripts/build-installer.bat) builds two different apps from the same source. Run it from a normal Command
Prompt or PowerShell, from `D:\Github\DigUp`; it sets up Swift, MSVC and the linker itself. Each installer is copied to
`scripts\scratch\` (git-ignored), because the next build of that profile deletes the bundle folder it came from.

| | **Local** (for trying things) | **Production** (the one you keep) |
|---|---|---|
| Build | `scripts\build-installer.bat local` | `scripts\build-installer.bat production` |
| Installer | `scripts\scratch\DigUp Local_0.7.0-beta.3_x64-setup.exe` | `scripts\scratch\DigUp_0.7.0-beta.3_x64-setup.exe` |
| App identity | `com.abdurrahim.DigUp.local`, "DigUp Local" | `com.abdurrahim.DigUp`, "DigUp" |
| Own settings, uninstall entry, install folder | yes, apart from production's | yes |
| Default index (built in) | `D:\Temp\digup-dev-index`, the throwaway index `dev-run.bat` also uses | `D:\Users\rahul\AppData\Local\DigUp\index`, the permanent index |
| Default models (built in) | `D:\Users\rahul\AppData\Local\DigUp\Models` | the same folder |
| Rust release profile | thin LTO, 16 code-generation units | full LTO, 1 unit (as upstream) |
| Cargo target folder | `D:\Temp\digup-shell-target-local` | `shell\src-tauri\target` |
| Installer compression | zlib | LZMA |
| Install it to | `D:\Users\rahul\AppData\Local\DigUp-Local` | `D:\Users\rahul\AppData\Local\DigUp` |

`scripts\build-installer.bat both` builds one after the other.

### Local build: why it is built the cheaper way

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
That is the fastest loop, but it is no longer an installer: no install folder, no uninstall entry, no `sandbox-remove` on uninstall, and
the `helper` folder must sit beside the exe (or be given with `--helper`). It was kept out because the local app is meant to be
installed and uninstalled like the real one. For a quick edit-and-run loop, `--no-bundle` is a sensible third mode; it is not built.

Measured times are under "How long the builds take" below.

### Production build: why it is left as upstream ships it

The production app is the one you keep and may update from, so it keeps upstream's settings: full LTO and one code-generation unit
(smaller, faster program) and LZMA (a smaller installer). The long build is paid once per release, not per experiment. Only the default
folders (above) differ from upstream, and `--index` / `--models` still override them.

### Steps: local build

```powershell
cd D:\Github\DigUp
scripts\build-installer.bat local
```

Then install it (quit "DigUp Local" from the tray first: Windows cannot replace files in use). `/D=` must be the last argument and the
path has no quotes:

```powershell
& "D:\Github\DigUp\scripts\scratch\DigUp Local_0.7.0-beta.3_x64-setup.exe" /S /D=D:\Users\rahul\AppData\Local\DigUp-Local
```

Run it from the Start menu or `D:\Users\rahul\AppData\Local\DigUp-Local`. It uses `D:\Temp\digup-dev-index` with no arguments, and asks
for its folders on first run (its settings are separate), or pass `--roots "D:\SomeTestFolder"`.

### Steps: production build

```powershell
cd D:\Github\DigUp
scripts\build-installer.bat production
```

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

### Which folder an app uses

The built-in defaults are compiled in (`DIGUP_BUILD_INDEX` and `DIGUP_BUILD_MODELS`, set by the script). They win over the user
variables `DIGUP_INDEX` and `DIGUP_MODELS`, deliberately: with `DIGUP_INDEX` set to the permanent index, the local app would otherwise
use it. The order for the index is `--index`, then the built-in default, then `DIGUP_INDEX`, then `%LOCALAPPDATA%\DigUp\index` on C:.
The defaults are paths on this machine, so an installer built here is for this machine only.

### Things to know about running both

- **One hotkey.** Both register Ctrl+Shift+Space; run only one at a time (or pass `--hotkey` to one).
- **The decode sandbox is shared.** Both use the same AppContainer profile (`DigUp.DecodeWorker`). Uninstalling one runs
  `digup sandbox-remove`, which removes that profile for the other too. Not tested: whether the other recreates it on its next start.
- **Not tried:** installing either build, running the two together, or uninstalling one. The local app's installed exe is expected to
  be named `DigUp Local.exe`; check after installing.

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

The local installer is 113 MB (zlib) against 93 MB for the same files with LZMA. A later local build, with its dependencies already
compiled, should be shorter than the first; that was not timed. The production and local figures were not measured under the same
conditions (the production run had its dependencies built already, the local run did not), so the real saving is larger than the
table suggests.


## CLI for quick runs

[scripts/dev-run.bat](scripts/dev-run.bat) sets PATH, `DIGUP_MODELS` and `DIGUP_BACKENDS`, then runs `digup.exe` with
`--index D:\Temp\digup-dev-index` (the same index the local installer defaults to). Every argument you pass goes on to `digup.exe`.
Set `INDEX` to use another folder, for example the permanent one below.

**The CLI and the apps can share one index.** Point the CLI's `INDEX` at the app's index folder. The app keeps it up to date and the CLI
can search it. Not tried: running both at once.




```powershell
cmd /c "set INDEX=D:\Users\rahul\AppData\Local\DigUp\index && D:\Github\DigUp\scripts\dev-run.bat index D:\RP_Backup\RP_Bak_Photos_Videos"
```

Running `index` again later only syncs what changed, then embeds what's new.
To avoid retyping, set it once for the PowerShell session:
```powershell
$env:INDEX = "D:\Users\rahul\AppData\Local\DigUp\index"
D:\Github\DigUp\scripts\dev-run.bat index D:\RP_Backup\RP_Bak_Photos_Videos
D:\Github\DigUp\scripts\dev-run.bat search sunset beach
```

**Additional Sample but with invalid path since it is for example only** - 
```powershell
cmd /c "set INDEX=D:\Users\rahul\AppData\Local\DigUp\index && D:\Github\DigUp\scripts\dev-run.bat index D:\Photos D:\Videos"
cmd /c "set INDEX=D:\Users\rahul\AppData\Local\DigUp\index && D:\Github\DigUp\scripts\dev-run.bat search sunset beach -n 10"
cmd /c "set INDEX=D:\Users\rahul\AppData\Local\DigUp\index && D:\Github\DigUp\scripts\dev-run.bat status"
```


**Temporary index (throwaway):** set nothing. 
It goes to `D:\Temp\digup-dev-index`, so it's safe to delete later.

```powershell
D:\Github\DigUp\scripts\dev-run.bat index D:\SomeTestFolder --limit 20
D:\Github\DigUp\scripts\dev-run.bat search zebra
```

For a separate temporary index each time, give it a new name:
```powershell
$env:INDEX = "D:\Temp\digup-try-1"
```
**Note**: Without `--index`, `digup.exe` uses `%LOCALAPPDATA%\DigUp\index` on C:. 
The script always passes `--index`, defaulting to the throwaway folder. So choose the folder with `INDEX`.
- **Video indexing time:** the first pass can be long. `digup estimate D:\Photos D:\Videos` shows the expected time before you commit.
- **Reusing an index:** use the same model files. A different model would need a re-index.

----

Helper script sample Commands:
```bat
scripts\dev-run.bat --help                                       prints the CLI help.
scripts\dev-run.bat status
scripts\dev-run.bat index D:\some\folder --limit 20              set `INDEX` or `MODELS` in the environment to use other folders.
scripts\dev-run.bat search zebra -n 5
set BUILD=1 && scripts\dev-run.bat status    :: rebuild first
```

**What I checked in the code:**
- The crawler walks every folder you give it, including all its subfolders.
- It guards against a folder inside another root being walked twice (`foundRoot` in [Crawler.swift:54](Sources/DigUpKit/Crawler.swift#L54)). So the parent plus its children gives the same files, not duplicates. I read the code but didn't run that case.

**So these two give the same index:**
```powershell
D:\Github\DigUp\scripts\dev-run.bat index D:\RP_Backup\RP_Bak_Photos_Videos
D:\Github\DigUp\scripts\dev-run.bat index D:\RP_Backup\RP_Bak_Photos_Videos\Photos D:\RP_Backup\RP_Bak_Photos_Videos\Photos_Videos
```

## Parent folder or the individual folders?

For a permanent index: with a parent such as `D:\RP_Backup\RP_Bak_Photos_Videos` that holds `Photos` and `Photos_Videos`, does it matter whether you pass the parent or the children? It barely matters for the first result, but passing only the parent is simpler.

**The difference shows up on later runs.** A sync removes index entries for files that are gone from the folders you pass. It only touches files under the folders you pass this time ([Indexer.swift:92](Sources/DigUpKit/Indexer.swift#L92)):
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
- `D:\Temp\digup-shell-target-local` (the local installer's cargo target folder)
- `D:\Temp\shell-check` (the `--target-dir` used for `cargo check`)

Do not exclude `D:\Github\DigUp` as a whole, `D:\Temp`, or `D:\Users\rahul\AppData\Local\DigUp` (the installed app, the index and the
models).

Add them in Windows Security → Virus & threat protection → Manage settings → Exclusions, or in an administrator PowerShell:

```powershell
Add-MpPreference -ExclusionPath "D:\Github\DigUp\shell\src-tauri\target","D:\Github\DigUp\.build","D:\Temp\digup-shell-target-local","D:\Temp\shell-check"
```

This does not speed up the `makensis` step ("Running makensis to produce ...-setup.exe"). That step compresses the ~220 MB `helper`
folder with LZMA on one core (zlib in the local build), and antivirus is not what slows it. To list or remove the exclusions later:
`Get-MpPreference | Select ExclusionPath` and `Remove-MpPreference -ExclusionPath <path>`.

============================================================================
## Original Build Instructions
**1. Set up the environment** (PowerShell, from `D:\Github\DigUp`):

```powershell
$sw = "C:\Users\rahul\AppData\Local\Programs\Swift"
$env:PATH = "C:\Program Files (x86)\Microsoft Visual Studio\Installer;$sw\Runtimes\6.4.1\usr\bin;$sw\Toolchains\6.4.1+Asserts\usr\bin;D:\Github\DigUp\Vendor\llama\lib;D:\Github\DigUp\Vendor\pdfium\bin;D:\Github\DigUp\Vendor\ffmpeg\bin;$env:PATH"
$env:DIGUP_MODELS   = "D:\Users\rahul\AppData\Local\DigUp\Models"
$env:DIGUP_BACKENDS = "D:\Github\DigUp\Vendor\llama\lib"
```

**2. Build** (needs the MSVC environment from `vcvars64.bat`, so do it in a `cmd` that has called it):

```bat
call "D:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cd /d D:\Github\DigUp
swift build --product digup
git restore Package.resolved
```

**3. Run the CLI** with a throwaway index on D: (not your real one):

```powershell
.build\debug\digup.exe --help
.build\debug\digup.exe --index D:\Temp\digup-index <command> ...
```

Use `--help` to see the exact subcommands, such as index and search. I didn't check them here.

**Other pieces:**
- **Tests:** `swift test`, with the same PATH and env vars. The full suite is 157 tests with the model.
- **Tauri shell (the GUI):** it's the Rust part, run with `cargo` from `C:\Users\rahul\.cargo\bin`. Pass `--target-dir D:\Temp\...`. I haven't checked its exact command, so tell me if you want the GUI and I'll look it up.

The setup is in "Development environment" in [docs/design.md](docs/design.md#L411). Do you want me to put steps 1–2 into a `.bat` or `.ps1` script?