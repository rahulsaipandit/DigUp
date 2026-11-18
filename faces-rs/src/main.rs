// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md 5.1). The face program: JSON lines on stdin and stdout, in the
// manner of `digup worker`. It reads the pictures the sandboxed decode already wrote (paths, never pixels over the pipe) and returns faces.
//
//   digup-faces [--models DIR] [--threads N]
//   -> {"ready":true,"signature":…,"dim":128}  or  {"ready":false,"error":…} and exit 1
//   <- {"id":…,"op":"faces","paths":[…],"score":0.5}
//   -> {"id":…,"ok":true,"results":[{"path":…,"width":w,"height":h,"faces":[{"box":[x,y,w,h],"score":s,"landmarks":[10 numbers],
//        "sharpness":v,"embedding":"base64 of 128 little-endian float32"}]} | {"path":…,"error":…}]}
//   <- {"id":…,"op":"quit"}    -> {"id":…,"ok":true}
//
// A picture that cannot be read or that makes the models fail gives an error for that picture only; the program goes on.
use base64::Engine;
use digup_faces::{FaceStack, SIGNATURE};
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};

/// Prepared pictures are at most 1024 px; anything much larger is not one of ours.
const MAX_SIDE: u32 = 4096;
const MAX_BYTES: u64 = 64 << 20;

fn reply(value: Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn read_picture(path: &Path) -> Result<image::RgbImage, String> {
    let size = std::fs::metadata(path).map_err(|e| e.to_string())?.len();
    if size > MAX_BYTES {
        return Err("the picture is too large".into());
    }
    let mut reader = image::ImageReader::open(path).map_err(|e| e.to_string())?.with_guessed_format().map_err(|e| e.to_string())?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_SIDE);
    limits.max_image_height = Some(MAX_SIDE);
    limits.max_alloc = Some(256 << 20);
    reader.limits(limits);
    Ok(reader.decode().map_err(|e| e.to_string())?.to_rgb8())
}

fn faces_json(stack: &mut FaceStack, path: &str) -> Value {
    let picture = match read_picture(Path::new(path)) {
        Ok(p) => p,
        Err(e) => return json!({"path": path, "error": e}),
    };
    let (width, height) = (picture.width(), picture.height());
    match catch_unwind(AssertUnwindSafe(|| stack.faces_in(&picture))) {
        Ok(Ok(faces)) => {
            let faces: Vec<Value> = faces
                .iter()
                .map(|f| {
                    let bytes: Vec<u8> = f.embedding.iter().flat_map(|v| v.to_le_bytes()).collect();
                    json!({
                        "box": f.bbox, "score": f.score, "sharpness": f.sharpness,
                        "landmarks": f.landmarks.iter().flatten().collect::<Vec<_>>(),
                        "embedding": base64::engine::general_purpose::STANDARD.encode(bytes),
                    })
                })
                .collect();
            json!({"path": path, "width": width, "height": height, "faces": faces})
        }
        Ok(Err(e)) => json!({"path": path, "error": e}),
        Err(_) => json!({"path": path, "error": "the face program panicked on this picture"}),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let value_of = |flag: &str| args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned();
    let models: PathBuf = value_of("--models").map(PathBuf::from).unwrap_or_else(|| {
        let base = std::env::var("DIGUP_MODELS").map(PathBuf::from).unwrap_or_default();
        base.join("faces")
    });
    let threads = value_of("--threads").and_then(|t| t.parse().ok()).unwrap_or(2);
    let mut stack = match FaceStack::load(&models, threads) {
        Ok(s) => s,
        Err(e) => {
            reply(json!({"ready": false, "error": e}));
            std::process::exit(1);
        }
    };
    reply(json!({"ready": true, "signature": SIGNATURE, "dim": 128}));
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let Ok(request) = serde_json::from_str::<Value>(&line) else { continue };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        match request.get("op").and_then(Value::as_str) {
            Some("quit") => {
                reply(json!({"id": id, "ok": true}));
                return;
            }
            Some("info") => reply(json!({"id": id, "ok": true, "signature": SIGNATURE, "dim": 128})),
            Some("faces") => {
                if let Some(score) = request.get("score").and_then(Value::as_f64) {
                    stack.score_threshold = score as f32;
                }
                let paths: Vec<&str> = request.get("paths").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
                let results: Vec<Value> = paths.iter().map(|p| faces_json(&mut stack, p)).collect();
                reply(json!({"id": id, "ok": true, "results": results}));
            }
            other => reply(json!({"id": id, "ok": false, "error": format!("unknown op {}", other.unwrap_or("(none)"))})),
        }
    }
}
