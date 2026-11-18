// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md). The face pipeline: YuNet detects faces and five landmarks,
// the face is aligned to 112 x 112 with a similarity transform onto the ArcFace template, and SFace returns a 128-d unit vector. This is a
// port of the reference the SmartPhotos project checked against OpenCV (tools/faces/face_ref.py), so its numbers are the ones to match.
use image::{imageops::FilterType, RgbImage};
use ndarray::Array4;
use ort::{
    inputs,
    session::{builder::GraphOptimizationLevel, Session},
    value::Value,
};
use sha2::{Digest, Sha256};
use std::path::Path;

/// The only model files that are loaded (rule 5 of the design): a file with any other hash is refused.
pub const YUNET_SHA256: &str = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4";
pub const SFACE_SHA256: &str = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79";
/// Recorded with every scan, so a different model or setting means "scan again".
pub const SIGNATURE: &str = "yunet-640+sface-128/1";

const TEMPLATE: [[f32; 2]; 5] = [[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366], [41.5493, 92.3655], [70.7299, 92.2041]];
const SIDE: usize = 640;

#[derive(Debug, Clone)]
pub struct Face {
    /// x, y, width, height in the pixels of the picture that was read.
    pub bbox: [f32; 4],
    pub score: f32,
    /// Right eye, left eye, nose, right mouth corner, left mouth corner.
    pub landmarks: [[f32; 2]; 5],
    /// Variance of the Laplacian over the face box, in that picture's pixels.
    pub sharpness: f32,
    pub embedding: Vec<f32>,
}

pub struct FaceStack {
    detector: Session,
    recogniser: Session,
    /// Detections below this score are dropped. The store applies its own floor and thresholds afterwards.
    pub score_threshold: f32,
    pub nms_threshold: f32,
}

pub fn sha256_hex(path: &Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    Ok(Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect())
}

fn session(path: &Path, expected: &str, threads: usize) -> Result<Session, String> {
    let actual = sha256_hex(path)?;
    if actual != expected {
        return Err(format!("{} is not the model DigUp ships (SHA-256 {actual})", path.display()));
    }
    Session::builder()
        .map_err(|e| e.to_string())?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| e.to_string())?
        .with_intra_threads(threads)
        .map_err(|e| e.to_string())?
        .commit_from_file(path)
        .map_err(|e| format!("cannot load {}: {e}", path.display()))
}

impl FaceStack {
    pub fn load(folder: &Path, threads: usize) -> Result<Self, String> {
        Ok(FaceStack {
            detector: session(&folder.join("yunet.onnx"), YUNET_SHA256, threads)?,
            recogniser: session(&folder.join("sface.onnx"), SFACE_SHA256, threads)?,
            score_threshold: 0.5,
            nms_threshold: 0.3,
        })
    }

    /// Every face in the picture, strongest first.
    pub fn faces_in(&mut self, picture: &RgbImage) -> Result<Vec<Face>, String> {
        let mut found = self.detect(picture)?;
        for face in &mut found {
            face.embedding = self.embed(picture, &face.landmarks)?;
            face.sharpness = sharpness(picture, face.bbox);
        }
        Ok(found)
    }

    fn detect(&mut self, picture: &RgbImage) -> Result<Vec<Face>, String> {
        let (w, h) = (picture.width() as f32, picture.height() as f32);
        let scale = (SIDE as f32 / w).min(SIDE as f32 / h);
        let (nw, nh) = (((w * scale).round() as u32).max(1), ((h * scale).round() as u32).max(1));
        // Triangle is a bilinear filter that averages when it shrinks, as PIL's BILINEAR does in the reference.
        let small = image::imageops::resize(picture, nw, nh, FilterType::Triangle);
        // BGR, raw 0..255, letterboxed at the top left with zeros (no stretch, no mean or scale), as OpenCV's FaceDetectorYN feeds YuNet.
        let mut input = Array4::<f32>::zeros((1, 3, SIDE, SIDE));
        for (x, y, p) in small.enumerate_pixels() {
            input[[0, 0, y as usize, x as usize]] = p[2] as f32;
            input[[0, 1, y as usize, x as usize]] = p[1] as f32;
            input[[0, 2, y as usize, x as usize]] = p[0] as f32;
        }
        let value = Value::from_array(input).map_err(|e| e.to_string())?;
        let outputs = self.detector.run(inputs!["input" => value]).map_err(|e| format!("detection failed: {e}"))?;
        let mut faces: Vec<Face> = Vec::new();
        for stride in [8usize, 16, 32] {
            let columns = SIDE / stride;
            let get = |name: &str| -> Result<Vec<f32>, String> {
                let (_, data) = outputs[format!("{name}_{stride}").as_str()].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
                Ok(data.to_vec())
            };
            let (cls, obj, bbox, kps) = (get("cls")?, get("obj")?, get("bbox")?, get("kps")?);
            for i in 0..cls.len() {
                let score = (cls[i].clamp(0.0, 1.0) * obj[i].clamp(0.0, 1.0)).sqrt();
                if score < self.score_threshold {
                    continue;
                }
                let (row, col) = ((i / columns) as f32, (i % columns) as f32);
                let s = stride as f32;
                let (cx, cy) = ((col + bbox[i * 4]) * s, (row + bbox[i * 4 + 1]) * s);
                let (bw, bh) = (bbox[i * 4 + 2].exp() * s, bbox[i * 4 + 3].exp() * s);
                let mut landmarks = [[0f32; 2]; 5];
                for (k, point) in landmarks.iter_mut().enumerate() {
                    *point = [(kps[i * 10 + 2 * k] + col) * s / scale, (kps[i * 10 + 2 * k + 1] + row) * s / scale];
                }
                faces.push(Face {
                    bbox: [(cx - bw / 2.0) / scale, (cy - bh / 2.0) / scale, bw / scale, bh / scale],
                    score,
                    landmarks,
                    sharpness: 0.0,
                    embedding: Vec::new(),
                });
            }
        }
        faces.sort_by(|a, b| b.score.total_cmp(&a.score));
        let mut kept: Vec<Face> = Vec::new();
        for face in faces {
            if kept.iter().all(|k| iou(&face.bbox, &k.bbox) < self.nms_threshold) {
                kept.push(face);
            }
        }
        Ok(kept)
    }

    fn embed(&mut self, picture: &RgbImage, landmarks: &[[f32; 2]; 5]) -> Result<Vec<f32>, String> {
        let m = similarity_transform(landmarks, &TEMPLATE);
        let aligned = warp(picture, &m, 112);
        let mut input = Array4::<f32>::zeros((1, 3, 112, 112));
        for y in 0..112 {
            for x in 0..112 {
                for c in 0..3 {
                    input[[0, c, y, x]] = aligned[(y * 112 + x) * 3 + c];
                }
            }
        }
        let value = Value::from_array(input).map_err(|e| e.to_string())?;
        let outputs = self.recogniser.run(inputs!["data" => value]).map_err(|e| format!("embedding failed: {e}"))?;
        let (_, data) = outputs[0].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
        let norm = data.iter().map(|v| v * v).sum::<f32>().sqrt();
        if !norm.is_finite() || norm <= f32::EPSILON {
            return Err("the face gave an empty embedding".into());
        }
        Ok(data.iter().map(|v| v / norm).collect())
    }
}

pub fn iou(a: &[f32; 4], b: &[f32; 4]) -> f32 {
    let (x1, y1) = (a[0].max(b[0]), a[1].max(b[1]));
    let (x2, y2) = ((a[0] + a[2]).min(b[0] + b[2]), (a[1] + a[3]).min(b[1] + b[3]));
    let inter = (x2 - x1).max(0.0) * (y2 - y1).max(0.0);
    inter / (a[2] * a[3] + b[2] * b[3] - inter + 1e-9)
}

/// The least-squares similarity (scale, rotation, translation) taking `src` onto `dst`: [a, -b, tx, b, a, ty].
pub fn similarity_transform(src: &[[f32; 2]; 5], dst: &[[f32; 2]; 5]) -> [f64; 6] {
    // Unknowns a, b, tx, ty with u = a x - b y + tx and v = b x + a y + ty; solved through the normal equations.
    let mut ata = [[0f64; 4]; 4];
    let mut atb = [0f64; 4];
    for (s, d) in src.iter().zip(dst) {
        let (x, y, u, v) = (s[0] as f64, s[1] as f64, d[0] as f64, d[1] as f64);
        for (row, target) in [([x, -y, 1.0, 0.0], u), ([y, x, 0.0, 1.0], v)] {
            for i in 0..4 {
                atb[i] += row[i] * target;
                for j in 0..4 {
                    ata[i][j] += row[i] * row[j];
                }
            }
        }
    }
    for col in 0..4 {
        let pivot = (col..4).max_by(|&i, &j| ata[i][col].abs().total_cmp(&ata[j][col].abs())).unwrap();
        ata.swap(col, pivot);
        atb.swap(col, pivot);
        for row in col + 1..4 {
            let f = ata[row][col] / ata[col][col];
            for k in col..4 {
                ata[row][k] -= f * ata[col][k];
            }
            atb[row] -= f * atb[col];
        }
    }
    let mut x = [0f64; 4];
    for row in (0..4).rev() {
        let sum: f64 = (row + 1..4).map(|k| ata[row][k] * x[k]).sum();
        x[row] = (atb[row] - sum) / ata[row][row];
    }
    [x[0], -x[1], x[2], x[1], x[0], x[3]]
}

/// RGB, 0..255, row-major (y, x, channel), sampled by the inverse of `m` with bilinear weights; outside the picture is black.
pub fn warp(picture: &RgbImage, m: &[f64; 6], size: usize) -> Vec<f32> {
    let (a, b, tx, ty) = (m[0], m[3], m[2], m[5]);
    let d = a * a + b * b;
    let inv = [a / d, b / d, -(a * tx + b * ty) / d, -b / d, a / d, (b * tx - a * ty) / d];
    let (w, h) = (picture.width() as i64, picture.height() as i64);
    let mut out = vec![0f32; size * size * 3];
    let px = |x: i64, y: i64, c: usize| -> f32 {
        if x < 0 || y < 0 || x >= w || y >= h { 0.0 } else { picture.get_pixel(x as u32, y as u32)[c] as f32 }
    };
    for y in 0..size {
        for x in 0..size {
            let (xf, yf) = (x as f64, y as f64);
            let sx = (inv[0] * xf + inv[1] * yf + inv[2]) as f32;
            let sy = (inv[3] * xf + inv[4] * yf + inv[5]) as f32;
            let (x0, y0) = (sx.floor(), sy.floor());
            let (fx, fy) = (sx - x0, sy - y0);
            let (x0, y0) = (x0 as i64, y0 as i64);
            for c in 0..3 {
                out[(y * size + x) * 3 + c] = px(x0, y0, c) * (1.0 - fx) * (1.0 - fy) + px(x0 + 1, y0, c) * fx * (1.0 - fy)
                    + px(x0, y0 + 1, c) * (1.0 - fx) * fy + px(x0 + 1, y0 + 1, c) * fx * fy;
            }
        }
    }
    out
}

/// Variance of the 4-neighbour Laplacian of the grey picture over the face box.
pub fn sharpness(picture: &RgbImage, bbox: [f32; 4]) -> f32 {
    let (w, h) = (picture.width() as i64, picture.height() as i64);
    if w < 4 || h < 4 {
        return 0.0; // too small to have an inside, and clamp below would panic
    }
    let (x0, y0) = ((bbox[0].floor() as i64).clamp(1, w - 2), (bbox[1].floor() as i64).clamp(1, h - 2));
    let (x1, y1) = (((bbox[0] + bbox[2]).ceil() as i64).clamp(x0 + 1, w - 1), ((bbox[1] + bbox[3]).ceil() as i64).clamp(y0 + 1, h - 1));
    let grey = |x: i64, y: i64| -> f32 {
        let p = picture.get_pixel(x as u32, y as u32);
        0.299 * p[0] as f32 + 0.587 * p[1] as f32 + 0.114 * p[2] as f32
    };
    let (mut sum, mut sum2, mut n) = (0f64, 0f64, 0f64);
    for y in y0..y1 {
        for x in x0..x1 {
            if x < 1 || y < 1 || x >= w - 1 || y >= h - 1 {
                continue;
            }
            let l = (grey(x - 1, y) + grey(x + 1, y) + grey(x, y - 1) + grey(x, y + 1) - 4.0 * grey(x, y)) as f64;
            sum += l;
            sum2 += l * l;
            n += 1.0;
        }
    }
    if n == 0.0 { 0.0 } else { (sum2 / n - (sum / n) * (sum / n)) as f32 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transform_recovers_a_known_similarity() {
        // Rotate by 10 degrees, scale 1.5, move by (3, -4).
        let (c, s) = (1.5f32 * 10f32.to_radians().cos(), 1.5f32 * 10f32.to_radians().sin());
        let mut moved = TEMPLATE;
        for p in &mut moved {
            *p = [c * p[0] - s * p[1] + 3.0, s * p[0] + c * p[1] - 4.0];
        }
        let m = similarity_transform(&moved, &TEMPLATE);
        // Mapping `moved` back onto the template must land every point on it.
        for (p, t) in moved.iter().zip(&TEMPLATE) {
            let u = m[0] * p[0] as f64 + m[1] * p[1] as f64 + m[2];
            let v = m[3] * p[0] as f64 + m[4] * p[1] as f64 + m[5];
            assert!((u - t[0] as f64).abs() < 1e-3 && (v - t[1] as f64).abs() < 1e-3, "{u} {v} vs {t:?}");
        }
    }

    #[test]
    fn warp_is_identity_for_identity() {
        let mut img = RgbImage::new(20, 20);
        for (x, y, p) in img.enumerate_pixels_mut() {
            *p = image::Rgb([x as u8 * 10, y as u8 * 10, 7]);
        }
        let out = warp(&img, &[1.0, 0.0, 0.0, 0.0, 1.0, 0.0], 20);
        for y in 0..20usize {
            for x in 0..20usize {
                assert_eq!(out[(y * 20 + x) * 3], x as f32 * 10.0, "x at {x},{y}");
                assert_eq!(out[(y * 20 + x) * 3 + 1], y as f32 * 10.0, "y at {x},{y}");
            }
        }
    }

    #[test]
    fn warp_translates() {
        let mut img = RgbImage::new(20, 20);
        for (x, _, p) in img.enumerate_pixels_mut() {
            *p = image::Rgb([x as u8 * 10, 0, 0]);
        }
        // Output (x, y) takes the source at (x + 5, y): a translation by -5.
        let out = warp(&img, &[1.0, 0.0, -5.0, 0.0, 1.0, 0.0], 10);
        assert_eq!(out[3 * 3], 80.0); // output x = 3 is source x = 8
    }

    #[test]
    fn overlap_of_boxes() {
        assert!((iou(&[0.0, 0.0, 10.0, 10.0], &[0.0, 0.0, 10.0, 10.0]) - 1.0).abs() < 1e-6);
        assert_eq!(iou(&[0.0, 0.0, 10.0, 10.0], &[20.0, 0.0, 10.0, 10.0]), 0.0);
    }

    #[test]
    fn a_flat_face_is_not_sharp() {
        let flat = RgbImage::from_pixel(50, 50, image::Rgb([120, 120, 120]));
        assert_eq!(sharpness(&flat, [10.0, 10.0, 30.0, 30.0]), 0.0);
    }
}
