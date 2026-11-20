#!/bin/bash
# Builds DigUp's Windows installer: the Tauri shell (shell/) with DigUp's helper, llama.cpp, PDFium, the Swift and C++
# runtimes and ffmpeg in its helper folder, as an NSIS installer that installs for the current user (no admin prompt).
# Run it in Git for Windows' bash inside a Visual Studio developer environment, after scripts/fetch-vendor.sh,
# scripts/build-llama.sh, scripts/build-decode-rs.sh and scripts/build-ffmpeg.sh (that one in MSYS2's MINGW64 shell). Needs Swift, Rust, Python and
# Node (for Tauri's CLI):
#   scripts/package-windows.sh      → shell/src-tauri/target/release/bundle/nsis/
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x Vendor/ffmpeg/bin/ffmpeg.exe ]] || { echo "no Vendor/ffmpeg/bin/ffmpeg.exe: run scripts/build-ffmpeg.sh in MSYS2" >&2; exit 1; }
# DOWNSTREAM-FORK (2026-11-17, security): the Rust readers that replace stb and miniz (scripts/build-decode-rs.sh): the build below links them.
[[ -f Vendor/decode/lib/digup_decode.lib ]] || { echo "no Vendor/decode/lib/digup_decode.lib: run scripts/build-decode-rs.sh" >&2; exit 1; }
# DOWNSTREAM-FORK (2026-11-18): the face program (faces-rs, scripts/build-faces-rs.sh), which the index helper starts beside itself when faces are turned on.
[[ -f Vendor/faces-models/sface.onnx && -f Vendor/faces-models/yunet.onnx ]] || { echo "no Vendor/faces-models: run scripts/fetch-face-models.sh" >&2; exit 1; }
[[ -x Vendor/faces-build/release/digup-faces.exe ]] || { echo "no Vendor/faces-build/release/digup-faces.exe: run scripts/build-faces-rs.sh" >&2; exit 1; }
TAURI_CLI=2.12.2

swift build -c release --product digup

# What the installer puts beside DigUp.exe, in helper\ ("DigUp.exe" and "digup.exe" can't share a folder): the helper
# finds the DLLs, llama.cpp's backends and ffmpeg in its own folder. The C++ runtime goes with them, so nothing needs
# installing first; the shell itself links its C runtime statically (.cargo/config.toml).
swift_root=$(cd "$(dirname "$(command -v swift)")/../../../.." && pwd)   # …/Swift from …/Swift/Toolchains/*/usr/bin
swift_runtime=$(ls -d "$swift_root"/Runtimes/*/usr/bin | tail -1)
crt=$(ls -d "$(cygpath "$VCToolsRedistDir")"x64/Microsoft.VC*.CRT | tail -1)   # set by the developer environment
helper=shell/src-tauri/helper
rm -rf "$helper"
mkdir -p "$helper"
cp .build/release/digup.exe Vendor/llama/lib/*.dll Vendor/pdfium/bin/pdfium.dll "$helper/"
cp "$swift_runtime"/*.dll "$helper/"
cp "$crt"/*.dll "$helper/"   # over the Swift runtime's copies of the same: the newer C++ runtime
cp Vendor/ffmpeg/bin/ffmpeg.exe Vendor/ffmpeg/bin/ffprobe.exe "$helper/"   # the small static build, no DLLs
# DOWNSTREAM-FORK (2026-11-18): the face program (ONNX Runtime is linked into it: no DLL) and the two face models it reads (YuNet, MIT, and SFace,
# Apache 2.0: about 39 MB; their licenses are in the notices, scripts/fetch-face-models.sh checks the files). DigUp finds them in helper\faces\ beside it.
cp Vendor/faces-build/release/digup-faces.exe "$helper/"
mkdir -p "$helper/faces"
cp Vendor/faces-models/yunet.onnx Vendor/faces-models/sface.onnx "$helper/faces/"

# With the release's signing key (TAURI_SIGNING_PRIVATE_KEY, and its password) the packages that update themselves are
# signed for in-app updates (a .sig beside each). Installed copies check those signatures with the public key in
# tauri.conf.json (plugins.updater.pubkey): a release built without it could never update.
signing=
if [[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
  if grep -q '"pubkey": ""' shell/src-tauri/tauri.conf.json; then
    echo "the signing key is set, but plugins.updater.pubkey in shell/src-tauri/tauri.conf.json is empty" >&2
    exit 1
  fi
  signing=',"createUpdaterArtifacts":true'
fi
# DOWNSTREAM-FORK (2026-11-20): DIGUP_PROFILE selects what is built (scripts/build-installer.bat sets it).
#   production (the default): the app as upstream ships it.
#   local: "DigUp Local", a second app next to the real one (own install folder, settings and uninstall entry), packed with zlib
#          (a bigger installer, but makensis' LZMA on one core is the slowest step). build-installer.bat also gives it a lighter
#          cargo profile and its own target folder through CARGO_PROFILE_RELEASE_* and CARGO_TARGET_DIR.
# DIGUP_BUILD_INDEX and DIGUP_BUILD_MODELS, when set, are compiled into the shell as its default folders (options.rs).
identity=
bundle_extra=
case "${DIGUP_PROFILE:-production}" in
  production) ;;
  local)
    identity=',"productName":"DigUp Local","identifier":"com.abdurrahim.DigUp.local"'
    bundle_extra=',"windows":{"nsis":{"compression":"zlib"}}'
    ;;
  *) echo "DIGUP_PROFILE must be local or production, not ${DIGUP_PROFILE}" >&2; exit 1 ;;
esac
# Where cargo puts the bundle: its own target folder when CARGO_TARGET_DIR is set (an absolute path).
if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
  bundle_dir="$(cygpath -u "$CARGO_TARGET_DIR")/release/bundle/nsis"
else
  bundle_dir=shell/src-tauri/target/release/bundle/nsis
fi
# The license of everything the installer carries, installed beside the app. (python3 can be the Store's stub.)
python=python3
python3 -c '' 2> /dev/null || python=python
"$python" scripts/notices.py windows shell/src-tauri/THIRD-PARTY-NOTICES.txt
# Installers of an earlier build (another version) would be taken for this one's.
rm -rf "$bundle_dir"
# The helper folder goes in as the installer's resources here only: Tauri checks resources on every build.
resources='{"helper/":"helper/","THIRD-PARTY-NOTICES.txt":"THIRD-PARTY-NOTICES.txt"}'
(cd shell/src-tauri && npx --yes "@tauri-apps/cli@$TAURI_CLI" build --bundles nsis \
  --config "{\"bundle\":{\"resources\":$resources$signing$bundle_extra}$identity}")
ls -la "$bundle_dir/"
