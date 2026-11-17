#!/bin/bash
# DOWNSTREAM-FORK (2026-11-17, security): new in the fork. Windows: builds decode-rs (Rust: what stb and miniz read for DigUp) as a
# static library, into Vendor/decode (lib and include, out of git). Needs cargo (rustup's, on PATH) and the MSVC environment (vcvars64),
# like the Rust shell. Does nothing when that build is already there, and nothing off Windows, where it is not used yet.
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -s)" in MINGW*|MSYS*) ;; *) echo "decode-rs is used on Windows only for now"; exit 0 ;; esac
OUT=Vendor/decode
STAMP="rust $(rustc --version | cut -d' ' -f2) $(cat decode-rs/Cargo.toml decode-rs/Cargo.lock decode-rs/src/lib.rs decode-rs/include/digup_decode.h | sha256sum | cut -c1-16)"
if [[ -f "$OUT/lib/digup_decode.lib" && "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then exit 0; fi
# Git for Windows' bash has its own /usr/bin/link.exe (a file-linking utility) ahead of MSVC's linker on the PATH, and rustc would run
# that one. Name the MSVC linker, the first link.exe on the PATH that is in a Visual Studio folder.
while IFS= read -r dir; do
  if [[ -f "$dir/link.exe" && "$dir" == *MSVC* ]]; then
    export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER="$(cygpath -w "$dir/link.exe")"
    break
  fi
done < <(echo "$PATH" | tr ':' '\n')
[[ -n "${CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER:-}" ]] || { echo "no MSVC link.exe on the PATH: run this in the vcvars64 environment" >&2; exit 1; }
# --locked: the versions in decode-rs/Cargo.lock, which were looked at, and no others.
cargo build --release --locked --manifest-path decode-rs/Cargo.toml --target-dir Vendor/decode-build
mkdir -p "$OUT/lib" "$OUT/include"
cp Vendor/decode-build/release/digup_decode.lib "$OUT/lib/"
cp decode-rs/include/digup_decode.h "$OUT/include/"
echo "$STAMP" > "$OUT/BUILD"
echo "Built decode-rs into $OUT"
