# DOWNSTREAM-FORK (2026-11-20): builds the Tauri shell from source (debug) and runs it against the real index and models.
# The fast loop for UI and shell changes (about 10 s); the desktop shortcut "DigUp (dev)" runs this.
#
#   scripts\dev-shell.ps1             quit DigUp, cargo build, start the dev build
#   scripts\dev-shell.ps1 -NoBuild    start the last dev build without building
#
# Why a script and not a plain shortcut to the exe: the dev build needs DIGUP_BACKENDS and PATH (llama.cpp, PDFium, ffmpeg)
# or it finds "no backends are loaded". And it must not run beside the installed app: they share the index and the hotkey,
# and a running exe cannot be rebuilt. The installed app is quit first (and not restarted).
param([switch] $NoBuild)
$ErrorActionPreference = "Stop"

$repo = Split-Path $PSScriptRoot -Parent
$target = "D:\Temp\digup-shell-target"
$exe = Join-Path $target "debug\digup-shell.exe"
$data = "D:\Users\rahul\AppData\Local\DigUp"

function Stop-Running([string[]] $folders) {
    Get-CimInstance Win32_Process | Where-Object {
        $path = $_.ExecutablePath
        $path -and ($folders | Where-Object { $path.StartsWith($_ + "\", [StringComparison]::OrdinalIgnoreCase) })
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}

try {
    # The installed app and an earlier dev build (its exe is locked while it runs). The local installer's app (DigUp-Local) is
    # left alone, but it shares the index: don't keep it running.
    Stop-Running @($data, (Join-Path $target "debug"))

    if (-not $NoBuild) {
        $env:PATH = "C:\Users\rahul\.cargo\bin;" + $env:PATH
        Push-Location (Join-Path $repo "shell\src-tauri")
        try {
            "cargo build --target-dir $target"
            cargo build --target-dir $target
            if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit code $LASTEXITCODE)." }
        } finally { Pop-Location }
    }
    if (-not (Test-Path $exe)) { throw "$exe does not exist: run without -NoBuild." }

    # The shell finds its helper in a `helper` folder beside the exe: a junction to the built one.
    $helper = Join-Path $target "debug\helper"
    if (-not (Test-Path $helper)) {
        New-Item -ItemType Junction -Path $helper -Target (Join-Path $repo "shell\src-tauri\helper") | Out-Null
    }

    $env:DIGUP_BACKENDS = Join-Path $repo "Vendor\llama\lib"
    $env:PATH = (Join-Path $repo "Vendor\llama\lib") + ";" + (Join-Path $repo "Vendor\pdfium\bin") + ";" +
                (Join-Path $repo "Vendor\ffmpeg\bin") + ";" + $env:PATH
    "Starting the dev build with the index in $data"
    Start-Process -FilePath $exe -WorkingDirectory "D:\Temp" -ArgumentList "--index", "`"$data\index`"", "--models", "`"$data\Models`""
} catch {
    # Opened from the shortcut, the window would close with the error in it.
    Write-Host ""
    Write-Host "dev-shell failed: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}
