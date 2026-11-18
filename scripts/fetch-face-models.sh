#!/bin/bash
# DOWNSTREAM-FORK (2026-11-18): new in the fork. Puts the two face models the installer carries into Vendor/faces-models (out of git), checked by SHA-256:
# YuNet (MIT, Shiqi Yu) and SFace (Apache 2.0), both from OpenCV Zoo's Hugging Face repositories (opencv/face_detection_yunet,
# opencv/face_recognition_sface), the files whose licenses are in scripts/licenses/yunet-LICENSE.txt and sface-LICENSE.txt. The program that reads them,
# digup-faces, refuses any other file (faces-rs/src/lib.rs has the same hashes). Run it before scripts/package-windows.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
dest=Vendor/faces-models
mkdir -p "$dest"
fetch() {   # name, url, sha256
  local file="$dest/$1"
  if [[ -f $file ]] && [[ $(sha256sum "$file" | cut -d' ' -f1) == "$3" ]]; then echo "$1 is there"; return; fi
  echo "downloading $1"
  curl -fL --retry 3 -o "$file.part" "$2"
  [[ $(sha256sum "$file.part" | cut -d' ' -f1) == "$3" ]] || { rm -f "$file.part"; echo "$1: the download is not the published file (SHA-256 differs)" >&2; exit 1; }
  mv "$file.part" "$file"
}
fetch yunet.onnx https://huggingface.co/opencv/face_detection_yunet/resolve/main/face_detection_yunet_2023mar.onnx \
  8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4
fetch sface.onnx https://huggingface.co/opencv/face_recognition_sface/resolve/main/face_recognition_sface_2021dec.onnx \
  0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
echo "face models are in $dest"
