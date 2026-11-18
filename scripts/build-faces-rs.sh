#!/bin/bash
# DOWNSTREAM-FORK (2026-11-17): new in the fork. Windows: builds digup-faces (faces-rs, the face program: YuNet and SFace through ONNX Runtime, which
# is linked in) into Vendor/faces-build/release/digup-faces.exe, out of git. Needs cargo (rustup's, on PATH) and the MSVC environment (vcvars64), like
# build-decode-rs.sh, and a network the first time: the ort crate downloads ONNX Runtime (about 600 MB of cache under %LOCALAPPDATA%\ort.pyke.io, which
# the crate puts there and this script cannot move). Does nothing off Windows.
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -s)" in MINGW*|MSYS*) ;; *) echo "digup-faces is built on Windows only for now"; exit 0 ;; esac
while IFS= read -r dir; do
  if [[ -f "$dir/link.exe" && "$dir" == *MSVC* ]]; then
    export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER="$(cygpath -w "$dir/link.exe")"
    break
  fi
done < <(echo "$PATH" | tr ':' '\n')
[[ -n "${CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER:-}" ]] || { echo "no MSVC link.exe on the PATH: run this in the vcvars64 environment" >&2; exit 1; }
# --locked: the versions in faces-rs/Cargo.lock, and no others.
cargo build --release --locked --manifest-path faces-rs/Cargo.toml --target-dir Vendor/faces-build
echo "Built Vendor/faces-build/release/digup-faces.exe"
