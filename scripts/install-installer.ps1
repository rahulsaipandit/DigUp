# DOWNSTREAM-FORK (2026-11-20): installs the installer that scripts\build-installer.bat copied to scripts\scratch\.
#
#   scripts\install-installer.ps1                     production: "DigUp" in D:\Users\rahul\AppData\Local\DigUp
#   scripts\install-installer.ps1 -Profile local      "DigUp Local" in D:\Users\rahul\AppData\Local\DigUp-Local
#   -Launch / -NoLaunch                               start the app afterwards (default: yes for production, no for local)
#
# Why a script: the installer is silent (/S), and Windows cannot replace a program that is running. With DigUp open, the
# install "succeeds" but leaves the old DigUp.exe in place and says nothing. This script quits the app (and its helpers) first,
# installs, then checks that the installed DigUp.exe really changed, and starts it with the index and models folders.
param(
    [ValidateSet("production", "local")] [string] $Profile = "production",
    [switch] $Launch,
    [switch] $NoLaunch
)
$ErrorActionPreference = "Stop"

$scratch = Join-Path $PSScriptRoot "scratch"
$data = "D:\Users\rahul\AppData\Local\DigUp"
if ($Profile -eq "local") {
    $pattern = "DigUp Local_*_x64-setup.exe"
    $installDir = "D:\Users\rahul\AppData\Local\DigUp-Local"
    $start = $Launch.IsPresent
} else {
    $pattern = "DigUp_*_x64-setup.exe"   # does not match "DigUp Local_..."
    $installDir = $data
    $start = -not $NoLaunch.IsPresent
}
if ($NoLaunch) { $start = $false }

$setup = Get-ChildItem $scratch -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $setup) { throw "No installer matching '$pattern' in $scratch. Run scripts\build-installer.bat $Profile first." }
"Installer: $($setup.FullName) (built $($setup.LastWriteTime))"

# The local and the production app can be pointed at the same index (the local one is by default): two apps indexing into one
# index at the same time would fight over it.
$other = if ($Profile -eq "local") { $data } else { "D:\Users\rahul\AppData\Local\DigUp-Local" }
$running = { param($dir) Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($dir + "\", [StringComparison]::OrdinalIgnoreCase) } }
if (& $running $other) { Write-Warning "The other DigUp ($other) is running. Both use the same index folder by default; quit one of them." }

# Quit what is running from the install folder: the shell, the helpers and the face program.
$mine = & $running $installDir
if ($mine) {
    "Stopping $(@($mine).Count) running DigUp process(es) from $installDir"
    $mine | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    if (& $running $installDir) { throw "DigUp is still running from $installDir; quit it and run this again." }
}

$exe = Join-Path $installDir "DigUp.exe"
$before = if (Test-Path $exe) { (Get-FileHash $exe).Hash } else { $null }

"Installing to $installDir ..."
$process = Start-Process -FilePath $setup.FullName -ArgumentList "/S", "/D=$installDir" -PassThru -Wait
if ($process.ExitCode -ne 0) { throw "The installer exited with code $($process.ExitCode)." }
# The silent installer starts its uninstaller-style children; wait for the program file to be written.
Start-Sleep -Seconds 5

if (-not (Test-Path $exe)) { throw "Installed, but $exe does not exist." }
$after = (Get-FileHash $exe).Hash
if ($before -and $before -eq $after) {
    Write-Warning "DigUp.exe is byte for byte the same as before the install. Either this installer is the build you already had, or the install did not replace it. Built $($setup.LastWriteTime); installed file dated $((Get-Item $exe).LastWriteTime)."
} else {
    "Installed: DigUp.exe is new ($((Get-Item $exe).LastWriteTime))."
}

if ($start) {
    $models = Join-Path $data "Models"
    "Starting DigUp with --index $data\index --models $models"
    Start-Process -FilePath $exe -ArgumentList "--index", "`"$data\index`"", "--models", "`"$models`""
}
