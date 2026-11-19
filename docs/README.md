Here's the dev-build way to run it on this machine. Everything is already built and the model files are in place.

## QUICK RUN (using setup script)
[scripts/dev-run.bat](scripts/dev-run.bat) sets PATH, `DIGUP_MODELS` and `DIGUP_BACKENDS`, then runs `digup.exe` with `--index D:\Temp\digup-dev-index`. Every argument you pass goes on to `digup.exe`.

**Installing a built installer onto D:** [scripts/build-installer.bat](scripts/build-installer.bat) writes `shell\src-tauri\target\release\bundle\nsis\DigUp_<version>_x64-setup.exe`. Quit DigUp from the tray first (Windows cannot replace files in use), then run it silently with the D: folder (`/D=` must be last; `scripts/scratch/` is git-ignored and handy for a copy of the installer):

```powershell
& "D:\Github\DigUp\shell\src-tauri\target\release\bundle\nsis\DigUp_0.7.0-beta.3_x64-setup.exe" /S /D=D:\Users\rahul\AppData\Local\DigUp
```

The index and models folders are not touched by installing.

For permanent folder like Photos and Videos, use permanent index
**Permanent index (reuse it later):** use the D: mirror of the real location from CLAUDE.md, and use it every time.

"D:\Users\rahul\AppData\Local\Programs\DigUp\DigUp.exe" `
  --index D:\Users\rahul\AppData\Local\DigUp\index `
  --models D:\Users\rahul\AppData\Local\DigUp\Models `
  --roots "D:\RP_Backup\RP_Bak_Photos_Videos"

Here is how folders and indexes are set for the installed app.

**The installed app** is the Tauri shell. It takes the index, model and folders as launch arguments, and these are the only places they are set (from [options.rs](shell/src-tauri/src/options.rs)):

| Argument | What it sets |
|---|---|
| `--index DIR` | the index folder |
| `--models DIR` | the model files (passed to the helper as `DIGUP_MODELS`) |
| `--roots "D:\a;D:\b"` | the folders to search and keep indexed, separated by `;`. This skips the setup screen. |
| `--settings FILE` | the settings file |

For example:

```powershell
& "D:\Users\rahul\AppData\Local\Programs\DigUp\DigUp.exe" `
  --index D:\Users\rahul\AppData\Local\DigUp\index `
  --models D:\Users\rahul\AppData\Local\DigUp\Models `
  --roots "D:\RP_Backup\RP_Bak_Photos_Videos"
```

Adjust the exe path to wherever you install it. The installer's default is under `%LOCALAPPDATA%\Programs`, so install with `/D=` to put it on D:.

- **Without `--roots`:** the app uses the folders you pick in its setup and Settings screens, stored in the settings file. That is the normal way to change folders later.
- **A different index per set of folders:** start the app with a different `--index` (and `--settings`) each time. Use a desktop shortcut with the arguments, one per index.
- **Without `--index`:** the app uses `%LOCALAPPDATA%\DigUp\index` on C:. To keep that on D: every time, launch it with `--index` from a shortcut.

**The CLI** (`dev-run.bat`) is separate from this. It takes the folders directly (`index <folders>`) and its index is the `INDEX` variable.

**Both can share one index.** Point the CLI's `INDEX` and the app's `--index` at the same folder. The app then keeps it up to date and the CLI can search it. I haven't tried running both at once.




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
It barely matters for the result, but passing only the parent is simpler.

**What I checked in the code:**
- The crawler walks every folder you give it, including all its subfolders.
- It guards against a folder inside another root being walked twice (`foundRoot` in [Crawler.swift:54](Sources/DigUpKit/Crawler.swift#L54)). So the parent plus its children gives the same files, not duplicates. I read the code but didn't run that case.

**So these two give the same index:**
```powershell
D:\Github\DigUp\scripts\dev-run.bat index D:\RP_Backup\RP_Bak_Photos_Videos
D:\Github\DigUp\scripts\dev-run.bat index D:\RP_Backup\RP_Bak_Photos_Videos\Photos D:\RP_Backup\RP_Bak_Photos_Videos\Photos_Videos
```

## Question> For permanent index - 
If I have a single parent folder like D:\RP_Backup\RP_Bak_Photos_Videos which in turn has child folders like Photos and Photos_Videos, does it matter whether I pass in the parent folder or all three indivdual folders
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