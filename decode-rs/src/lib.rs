// DOWNSTREAM-FORK (2026-11-17, security): new in the fork. See docs/design.md ("Rust decoders").
//
// What stb_image and miniz read for DigUp, in Rust: JPEG, PNG, GIF, BMP, PNM, TGA and PSD pictures, and one entry of a zip file. They parse files
// from anywhere, so they are the part most worth having in a memory-safe language. A C interface for the Swift side
// (include/digup_decode.h). Nothing here panics across it: every entry point catches a panic and returns an error code.
//
// Not the same bytes as stb for a JPEG: another decoder gives pixels that differ by a few levels. PNG, GIF and BMP are exact.

use std::io::{self, Cursor, Read, Seek, SeekFrom};
use std::os::raw::{c_char, c_void};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use image::{ImageFormat, ImageReader, Limits};

// Error codes (the same in digup_decode.h).
const OK: i32 = 0;
const UNSUPPORTED: i32 = 1; // not a format this reads: the caller may try another reader
const CORRUPT: i32 = 2; // a format this reads, and the file is bad
const TOO_BIG: i32 = 3; // asks for more memory or size than is allowed
const NOT_A_ZIP: i32 = 4;
const NO_SUCH_ENTRY: i32 = 5;
const READ_ERROR: i32 = 6;
const PANIC: i32 = 7;
const BAD_ARGUMENT: i32 = 8;

/// The most pixels a picture may have (a 100-megapixel photo is 300 MB as RGB).
const MAX_PIXELS: u64 = 400_000_000;

// ------------------------------------------------------------------------------------------------------------------ memory

/// Hands a buffer to the caller, who frees it with `dz_free` and the same length.
fn give(buffer: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) {
    let boxed = buffer.into_boxed_slice();
    unsafe {
        *out_len = boxed.len();
        *out = Box::into_raw(boxed) as *mut u8;
    }
}

/// # Safety
/// `pointer` and `len` are exactly what an earlier call returned, and are freed once.
#[no_mangle]
pub unsafe extern "C" fn dz_free(pointer: *mut u8, len: usize) {
    if !pointer.is_null() {
        drop(Box::from_raw(std::slice::from_raw_parts_mut(pointer, len)));
    }
}

// ------------------------------------------------------------------------------------------------------------------ pictures

/// What kind of picture the bytes are. TGA has no magic bytes, so it is what a file is when nothing else matches and its header
/// passes the decoder's own checks (`tga_header`); PSD is found by its "8BPS" signature, which `image` does not read.
enum Kind {
    Image(ImageFormat),
    Psd,
}

fn kind(bytes: &[u8]) -> Option<Kind> {
    if bytes.starts_with(b"8BPS") {
        return Some(Kind::Psd);
    }
    match image::guess_format(bytes) {
        Ok(f @ (ImageFormat::Png | ImageFormat::Jpeg | ImageFormat::Gif | ImageFormat::Bmp | ImageFormat::Pnm)) => {
            Some(Kind::Image(f))
        }
        Ok(_) => None, // WebP, TIFF, AVIF and the rest: ffmpeg's
        Err(_) => tga_header(bytes).then_some(Kind::Image(ImageFormat::Tga)),
    }
}

/// Whether the bytes begin like a TGA file: the decoder accepts the header (its image type, color map and depth are checked there).
fn tga_header(bytes: &[u8]) -> bool {
    bytes.len() >= 18 && image::codecs::tga::TgaDecoder::new(Cursor::new(bytes)).is_ok()
}

fn limits() -> Limits {
    let mut limits = Limits::default();
    limits.max_alloc = Some(MAX_PIXELS * 4); // bytes any one allocation may take while decoding
    limits
}

fn reader(bytes: &[u8], format: ImageFormat) -> ImageReader<Cursor<&[u8]>> {
    let mut reader = ImageReader::with_format(Cursor::new(bytes), format);
    reader.limits(limits());
    reader
}

fn checked(width: u32, height: u32) -> Result<(u32, u32), i32> {
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err(TOO_BIG);
    }
    Ok((width, height))
}

/// A PSD's size is in its header (height, then width, as big-endian u32 at bytes 14 and 18).
fn psd_dimensions(bytes: &[u8]) -> Result<(u32, u32), i32> {
    if bytes.len() < 26 {
        return Err(CORRUPT);
    }
    let height = u32::from_be_bytes(bytes[14..18].try_into().unwrap());
    let width = u32::from_be_bytes(bytes[18..22].try_into().unwrap());
    let (width, height) = checked(width, height)?;
    // The `psd` crate allocates from the header before it reads the pixels, so a file of a few bytes that claims 400 megapixels would
    // take gigabytes (an allocation failure aborts the process; it is not a panic that is caught). Compressed pixel data cannot
    // shrink by more than about 1000 to 1 (deflate), so a size that no file of this length could hold is a bad file.
    if u64::from(width) * u64::from(height) > bytes.len() as u64 * PSD_MAX_PIXELS_PER_BYTE {
        return Err(CORRUPT);
    }
    Ok((width, height))
}

/// The most pixels a PSD may claim per byte of file (see `psd_dimensions`).
const PSD_MAX_PIXELS_PER_BYTE: u64 = 4096;

fn info(bytes: &[u8]) -> Result<(u32, u32), i32> {
    match kind(bytes).ok_or(UNSUPPORTED)? {
        Kind::Psd => psd_dimensions(bytes),
        Kind::Image(format) => {
            let (width, height) = reader(bytes, format).into_dimensions().map_err(|_| CORRUPT)?;
            checked(width, height)
        }
    }
}

fn decode(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), i32> {
    let (width, height) = info(bytes)?;
    match kind(bytes).ok_or(UNSUPPORTED)? {
        Kind::Psd => {
            // The merged picture the file carries, as stb reads it. A mode or depth the reader does not know is the caller's to
            // pass on (ffmpeg, in its sandbox reads PSD too), not a crash.
            let psd = psd::Psd::from_bytes(bytes).map_err(|_| UNSUPPORTED)?;
            if psd.width() != width || psd.height() != height {
                return Err(CORRUPT);
            }
            let rgba = psd.rgba();
            if rgba.len() as u64 != u64::from(width) * u64::from(height) * 4 {
                return Err(CORRUPT);
            }
            // Alpha dropped, as for every other format here.
            let mut rgb = Vec::with_capacity(rgba.len() / 4 * 3);
            for pixel in rgba.chunks_exact(4) {
                rgb.extend_from_slice(&pixel[..3]);
            }
            Ok((width, height, rgb))
        }
        Kind::Image(format) => {
            let image = reader(bytes, format).decode().map_err(|error| match error {
                image::ImageError::Limits(_) => TOO_BIG,
                _ => CORRUPT,
            })?;
            // Packed 8-bit RGB, as stb gives with three channels: the alpha channel is dropped, 16 bits are cut to 8.
            Ok((width, height, image.into_rgb8().into_raw()))
        }
    }
}

/// The size of a picture this reads (JPEG, PNG, GIF, BMP, PNM, PSD found by their first bytes, TGA by a header that passes), without decoding it.
/// Returns 0, or `UNSUPPORTED` for any other file (so the caller may use another reader), or `CORRUPT` or `TOO_BIG`.
///
/// # Safety
/// `data` points to `len` readable bytes; `width` and `height` are writable.
#[no_mangle]
pub unsafe extern "C" fn dz_image_info(data: *const u8, len: usize, width: *mut i32, height: *mut i32) -> i32 {
    if data.is_null() || width.is_null() || height.is_null() {
        return BAD_ARGUMENT;
    }
    let bytes = std::slice::from_raw_parts(data, len);
    match catch_unwind(AssertUnwindSafe(|| info(bytes))) {
        Ok(Ok((w, h))) if w <= i32::MAX as u32 && h <= i32::MAX as u32 => {
            *width = w as i32;
            *height = h as i32;
            OK
        }
        Ok(Ok(_)) => TOO_BIG,
        Ok(Err(code)) => code,
        Err(_) => PANIC,
    }
}

/// Decodes a picture to packed 8-bit RGB (`width * height * 3` bytes, in `*out`, to be freed with `dz_free` and that length).
///
/// # Safety
/// As `dz_image_info`; `out` and `out_len` are writable.
#[no_mangle]
pub unsafe extern "C" fn dz_image_decode_rgb(
    data: *const u8,
    len: usize,
    width: *mut i32,
    height: *mut i32,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if data.is_null() || width.is_null() || height.is_null() || out.is_null() || out_len.is_null() {
        return BAD_ARGUMENT;
    }
    // Nothing to free on any failure below.
    *out = ptr::null_mut();
    *out_len = 0;
    let bytes = std::slice::from_raw_parts(data, len);
    match catch_unwind(AssertUnwindSafe(|| decode(bytes))) {
        Ok(Ok((w, h, pixels))) if w <= i32::MAX as u32 && h <= i32::MAX as u32 => {
            *width = w as i32;
            *height = h as i32;
            give(pixels, out, out_len);
            OK
        }
        Ok(Ok(_)) => TOO_BIG,
        Ok(Err(code)) => code,
        Err(_) => PANIC,
    }
}

// ------------------------------------------------------------------------------------------------------------------ zip

/// Reads where it is asked: `read(context, offset, buffer, length)` returns the bytes it copied, or -1.
type ReadAt = unsafe extern "C" fn(context: *mut c_void, offset: u64, buffer: *mut u8, length: usize) -> i64;

struct Callback {
    read: ReadAt,
    context: *mut c_void,
    size: u64,
    position: u64,
}

impl Read for Callback {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.position >= self.size || buffer.is_empty() {
            return Ok(0);
        }
        let wanted = buffer.len().min((self.size - self.position) as usize);
        let got = unsafe { (self.read)(self.context, self.position, buffer.as_mut_ptr(), wanted) };
        // A callback that fails, or claims more than it was asked for, is an error: believing it would move past the buffer.
        if got < 0 || got as u64 > wanted as u64 {
            return Err(io::Error::new(io::ErrorKind::Other, "read failed"));
        }
        self.position += got as u64;
        Ok(got as usize)
    }
}

impl Seek for Callback {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let target = match to {
            SeekFrom::Start(offset) => Some(offset),
            SeekFrom::End(delta) => self.size.checked_add_signed(delta),
            SeekFrom::Current(delta) => self.position.checked_add_signed(delta),
        };
        match target {
            Some(position) => {
                self.position = position;
                Ok(position)
            }
            None => Err(io::Error::new(io::ErrorKind::InvalidInput, "seek before the start")),
        }
    }
}

fn zip_entry(callback: Callback, name: &str, max_bytes: u64) -> Result<Vec<u8>, i32> {
    let mut archive = zip::ZipArchive::new(callback).map_err(|error| match error {
        zip::result::ZipError::Io(_) => READ_ERROR,
        _ => NOT_A_ZIP,
    })?;
    let mut entry = archive.by_name(name).map_err(|error| match error {
        zip::result::ZipError::FileNotFound => NO_SUCH_ENTRY,
        zip::result::ZipError::Io(_) => READ_ERROR,
        _ => CORRUPT,
    })?;
    // The declared size is checked before anything is allocated (a zip of a few KB can declare gigabytes), and what is read is
    // cut at the limit too, since a declared size can lie.
    if entry.size() > max_bytes {
        return Err(TOO_BIG);
    }
    let mut bytes = Vec::with_capacity(entry.size() as usize);
    // `saturating_add`: a limit of u64::MAX must not wrap to 0 (or panic) here.
    (&mut entry).take(max_bytes.saturating_add(1)).read_to_end(&mut bytes).map_err(|_| CORRUPT)?;
    if bytes.len() as u64 > max_bytes {
        return Err(TOO_BIG);
    }
    Ok(bytes)
}

/// One entry of a zip file, by name (UTF-8), at most `max_bytes` long. The file is read through `read`, `size` bytes of it.
/// Returns 0, `NOT_A_ZIP`, `NO_SUCH_ENTRY`, `TOO_BIG` (declared or actual size over the limit), `CORRUPT` or `READ_ERROR`.
///
/// # Safety
/// `read` is callable with `context`; `name` is a NUL-terminated string; `out` and `out_len` are writable.
#[no_mangle]
pub unsafe extern "C" fn dz_zip_entry(
    read: ReadAt,
    context: *mut c_void,
    size: u64,
    name: *const c_char,
    max_bytes: u64,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if name.is_null() || out.is_null() || out_len.is_null() {
        return BAD_ARGUMENT;
    }
    *out = ptr::null_mut();
    *out_len = 0;
    let Ok(name) = std::ffi::CStr::from_ptr(name).to_str() else { return BAD_ARGUMENT };
    let callback = Callback { read, context, size, position: 0 };
    match catch_unwind(AssertUnwindSafe(|| zip_entry(callback, name, max_bytes))) {
        Ok(Ok(bytes)) => {
            give(bytes, out, out_len);
            OK
        }
        Ok(Err(code)) => code,
        Err(_) => PANIC,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = Vec::new();
        let buffer = image::RgbaImage::from_fn(width, height, |x, y| image::Rgba([x as u8, y as u8, 7, 200]));
        buffer.write_to(&mut Cursor::new(&mut bytes), ImageFormat::Png).unwrap();
        bytes
    }

    #[test]
    fn a_png_decodes_to_rgb_without_its_alpha() {
        let (w, h, pixels) = decode(&png(5, 3)).unwrap();
        assert_eq!((w, h, pixels.len()), (5, 3, 5 * 3 * 3));
        assert_eq!(&pixels[0..3], &[0, 0, 7]);
        assert_eq!(&pixels[3..6], &[1, 0, 7]);
    }

    #[test]
    fn what_is_not_a_known_picture_is_unsupported_and_garbage_is_not_a_crash() {
        assert_eq!(info(b"this is not a picture").unwrap_err(), UNSUPPORTED);
        assert_eq!(info(&[]).unwrap_err(), UNSUPPORTED);
        let mut cut = png(40, 40);
        cut.truncate(cut.len() / 2);
        assert_eq!(decode(&cut).unwrap_err(), CORRUPT);
        let mut noise = png(8, 8);
        for byte in noise.iter_mut().skip(30) {
            *byte = byte.wrapping_mul(31).wrapping_add(7);
        }
        let _ = decode(&noise); // an error or a picture, and no panic
    }

    #[test]
    fn a_header_that_claims_a_huge_picture_is_refused_before_it_is_allocated() {
        let mut bytes = png(4, 4);
        // The IHDR width and height are bytes 16..24 of a PNG: claim 200000 x 200000.
        bytes[16..20].copy_from_slice(&200_000u32.to_be_bytes());
        bytes[20..24].copy_from_slice(&200_000u32.to_be_bytes());
        let error = info(&bytes).unwrap_err();
        assert!(error == TOO_BIG || error == CORRUPT, "got {error}");
    }

    fn zip_with(name: &str, content: &[u8]) -> Vec<u8> {
        use std::io::Write;
        let mut out = Cursor::new(Vec::new());
        let mut writer = zip::ZipWriter::new(&mut out);
        writer.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
        writer.write_all(content).unwrap();
        writer.finish().unwrap();
        out.into_inner()
    }

    unsafe extern "C" fn read_from_slice(context: *mut c_void, offset: u64, buffer: *mut u8, length: usize) -> i64 {
        let data = &*(context as *const Vec<u8>);
        let start = (offset as usize).min(data.len());
        let n = length.min(data.len() - start);
        ptr::copy_nonoverlapping(data.as_ptr().add(start), buffer, n);
        n as i64
    }

    fn entry(data: &Vec<u8>, name: &str, max: u64) -> Result<Vec<u8>, i32> {
        let callback = Callback { read: read_from_slice, context: data as *const Vec<u8> as *mut c_void, size: data.len() as u64, position: 0 };
        zip_entry(callback, name, max)
    }

    #[test]
    fn an_entry_is_read_and_a_missing_one_is_said_to_be_missing() {
        let data = zip_with("word/document.xml", b"<w:p>hello</w:p>");
        assert_eq!(entry(&data, "word/document.xml", 1 << 20).unwrap(), b"<w:p>hello</w:p>");
        assert_eq!(entry(&data, "nope.xml", 1 << 20).unwrap_err(), NO_SUCH_ENTRY);
        assert_eq!(entry(&b"not a zip".to_vec(), "x", 1 << 20).unwrap_err(), NOT_A_ZIP);
    }

    #[test]
    fn an_entry_over_the_limit_is_refused() {
        let data = zip_with("big.xml", &vec![b'A'; 100_000]);
        assert_eq!(entry(&data, "big.xml", 99_999).unwrap_err(), TOO_BIG);
        assert_eq!(entry(&data, "big.xml", 100_000).unwrap().len(), 100_000);
    }

    // The three fixes from the code review, each pinned by a test.

    /// A read callback that claims to have copied more than it was asked for: believing it would move the position past the buffer.
    unsafe extern "C" fn over_reporting(_context: *mut c_void, _offset: u64, buffer: *mut u8, length: usize) -> i64 {
        ptr::write_bytes(buffer, 0, length);
        length as i64 + 1000
    }

    #[test]
    fn a_callback_that_reports_more_than_it_was_asked_for_is_an_error_and_not_believed() {
        let callback = Callback { read: over_reporting, context: ptr::null_mut(), size: 4096, position: 0 };
        let error = zip_entry(callback, "x", 1 << 20).unwrap_err();
        assert!(error == READ_ERROR || error == NOT_A_ZIP, "got {error}");
        // And directly: the reader refuses it, rather than advancing past what it asked for.
        let mut callback = Callback { read: over_reporting, context: ptr::null_mut(), size: 4096, position: 0 };
        let mut buffer = [0u8; 16];
        assert!(callback.read(&mut buffer).is_err());
        assert_eq!(callback.position, 0, "the position did not move");
    }

    #[test]
    fn a_limit_of_u64_max_does_not_wrap_or_panic() {
        let data = zip_with("big.xml", &vec![b'A'; 1000]);
        assert_eq!(entry(&data, "big.xml", u64::MAX).unwrap().len(), 1000);
    }

    #[test]
    fn the_output_pointers_are_cleared_when_a_picture_fails() {
        let garbage = b"this is not a picture";
        let (mut width, mut height) = (7i32, 7i32);
        // Start them as if left over from an earlier call: a failure must not leave them looking like something to free.
        let mut out: *mut u8 = 0x10 as *mut u8;
        let mut out_len: usize = 99;
        let code = unsafe { dz_image_decode_rgb(garbage.as_ptr(), garbage.len(), &mut width, &mut height, &mut out, &mut out_len) };
        assert_eq!(code, UNSUPPORTED);
        assert!(out.is_null() && out_len == 0);
    }

    #[test]
    fn pnm_tga_and_psd_pictures_are_read() {
        // P6 (binary PPM), 2 x 1: red, blue.
        let mut ppm = b"P6
2 1
255
".to_vec();
        ppm.extend_from_slice(&[255, 0, 0, 0, 0, 255]);
        assert_eq!(decode(&ppm).unwrap(), (2, 1, vec![255, 0, 0, 0, 0, 255]));
        // TGA, written by the same crate that reads it.
        let mut tga = Vec::new();
        image::RgbImage::from_fn(3, 2, |x, y| image::Rgb([x as u8 * 50, y as u8 * 90, 9]))
            .write_to(&mut Cursor::new(&mut tga), ImageFormat::Tga)
            .unwrap();
        let (w, h, pixels) = decode(&tga).unwrap();
        assert_eq!((w, h, pixels.len()), (3, 2, 18));
        assert_eq!(&pixels[3..6], &[50, 0, 9]);
        // PSD: a 1 x 1 RGB 8-bit file, built by hand (header, empty color mode data, resources and layer sections, raw image data).
        let mut psd = b"8BPS".to_vec();
        psd.extend_from_slice(&[0, 1, 0, 0, 0, 0, 0, 0, 0, 3]); // version 1, reserved, 3 channels
        psd.extend_from_slice(&1u32.to_be_bytes()); // height
        psd.extend_from_slice(&1u32.to_be_bytes()); // width
        psd.extend_from_slice(&[0, 8, 0, 3]); // depth 8, mode RGB
        psd.extend_from_slice(&[0; 12]); // three empty sections
        psd.extend_from_slice(&[0, 0, 10, 20, 30]); // raw compression, R G B planes of one pixel
        assert_eq!(decode(&psd).unwrap(), (1, 1, vec![10, 20, 30]));
    }

    #[test]
    fn a_psd_that_claims_a_huge_size_is_refused_and_a_cut_one_is_not_a_crash() {
        let mut psd = b"8BPS".to_vec();
        psd.extend_from_slice(&[0, 1, 0, 0, 0, 0, 0, 0, 0, 3]);
        psd.extend_from_slice(&300_000u32.to_be_bytes());
        psd.extend_from_slice(&300_000u32.to_be_bytes());
        psd.extend_from_slice(&[0, 8, 0, 3]);
        assert_eq!(info(&psd).unwrap_err(), TOO_BIG);
        assert!(decode(&psd[..20]).is_err());
        // A size inside the limit but that no file this short could hold: refused before the crate allocates for it.
        let mut small = psd[..26].to_vec();
        small[14..18].copy_from_slice(&20_000u32.to_be_bytes());
        small[18..22].copy_from_slice(&20_000u32.to_be_bytes());
        assert_eq!(info(&small).unwrap_err(), CORRUPT);
        assert_eq!(decode(&small).unwrap_err(), CORRUPT);
    }

    #[test]
    fn a_header_that_only_looks_like_tga_by_chance_is_not_taken_for_one() {
        assert_eq!(info(b"just some text, not a picture at all").unwrap_err(), UNSUPPORTED);
        assert_eq!(info(&[0u8; 64]).unwrap_err(), UNSUPPORTED); // image type 0: no image
    }

    // ---------------------------------------------------------------------------------------------------------------- fuzzing
    //
    // A seeded mutation fuzzer that runs with `cargo test` (the libFuzzer targets in fuzz/ run in CI): valid files of every format
    // are cut, flipped, filled and stretched, and every entry point must return a code, never `PANIC`, never hang, and never hand
    // back a picture whose size does not match its pixels. Set DIGUP_FUZZ_ROUNDS for more (default 3000 per seed).

    /// xorshift64*: the same sequence for the same seed, so a failure can be replayed.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
        }
        fn below(&mut self, n: usize) -> usize {
            (self.next() % n.max(1) as u64) as usize
        }
    }

    fn mutate(seed: &[u8], rng: &mut Rng) -> Vec<u8> {
        let mut bytes = seed.to_vec();
        for _ in 0..1 + rng.below(4) {
            if bytes.is_empty() {
                break;
            }
            let at = rng.below(bytes.len());
            match rng.below(7) {
                0 => bytes[at] ^= 1 << rng.below(8),
                1 => bytes[at] = rng.next() as u8,
                2 => bytes.truncate(at),
                3 => {
                    let end = (at + 1 + rng.below(16)).min(bytes.len());
                    for byte in &mut bytes[at..end] {
                        *byte = [0x00, 0xFF, 0x7F, 0x80][rng.below(4)];
                    }
                }
                4 => {
                    let extra: Vec<u8> = (0..rng.below(64)).map(|_| rng.next() as u8).collect();
                    bytes.splice(at..at, extra);
                }
                5 => {
                    // A four-byte field set to an extreme: sizes, counts and offsets are where decoders go wrong.
                    if at + 4 <= bytes.len() {
                        let value: u32 = [0, 1, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0x00FF_FFFF][rng.below(6)];
                        let field = if rng.below(2) == 0 { value.to_le_bytes() } else { value.to_be_bytes() };
                        bytes[at..at + 4].copy_from_slice(&field);
                    }
                }
                _ => {
                    let from = rng.below(bytes.len());
                    let chunk: Vec<u8> = bytes[from..(from + 32).min(bytes.len())].to_vec();
                    bytes.splice(at..at, chunk);
                }
            }
        }
        bytes
    }

    fn picture_seeds() -> Vec<(&'static str, Vec<u8>)> {
        let rgb = image::RgbImage::from_fn(13, 9, |x, y| image::Rgb([x as u8 * 19, y as u8 * 27, (x * y) as u8]));
        let encode = |format| {
            let mut out = Vec::new();
            rgb.write_to(&mut Cursor::new(&mut out), format).unwrap();
            out
        };
        let mut ppm = b"P6\n4 2\n255\n".to_vec();
        ppm.extend((0..24).map(|i| i as u8 * 9));
        let mut pgm = b"P5\n3 3\n255\n".to_vec();
        pgm.extend(0..9u8);
        let mut psd = b"8BPS".to_vec();
        psd.extend_from_slice(&[0, 1, 0, 0, 0, 0, 0, 0, 0, 3]); // version 1, reserved, 3 channels
        psd.extend_from_slice(&2u32.to_be_bytes()); // height
        psd.extend_from_slice(&2u32.to_be_bytes()); // width
        psd.extend_from_slice(&[0, 8, 0, 3]); // 8 bits, RGB
        psd.extend_from_slice(&[0; 12]); // color mode data, image resources, layers: all empty
        psd.extend_from_slice(&[0, 0]); // raw
        psd.extend((0..12u8).map(|i| i * 17)); // three planes of four pixels
        vec![
            ("png", encode(ImageFormat::Png)),
            ("jpeg", encode(ImageFormat::Jpeg)),
            ("gif", encode(ImageFormat::Gif)),
            ("bmp", encode(ImageFormat::Bmp)),
            ("tga", encode(ImageFormat::Tga)),
            ("ppm", ppm),
            ("pgm", pgm),
            ("psd", psd),
        ]
    }

    fn rounds() -> usize {
        std::env::var("DIGUP_FUZZ_ROUNDS").ok().and_then(|v| v.parse().ok()).unwrap_or(3000)
    }

    /// Runs the C entry points (which catch panics and say so with `PANIC`) on the bytes and checks what they promise.
    /// Returns whether the decoder panicked (and the panic was caught at the boundary and returned as `PANIC`, as promised).
    fn check_picture(bytes: &[u8], what: &str, round: usize) -> bool {
        let (mut width, mut height) = (0i32, 0i32);
        let code = unsafe { dz_image_info(bytes.as_ptr(), bytes.len(), &mut width, &mut height) };
        assert_ne!(code, PANIC, "{what} round {round}: dz_image_info panicked");
        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len = 0usize;
        let code = unsafe { dz_image_decode_rgb(bytes.as_ptr(), bytes.len(), &mut width, &mut height, &mut out, &mut out_len) };
        let panicked = code == PANIC;
        if code == OK {
            assert!(width > 0 && height > 0, "{what} round {round}: an empty picture");
            assert_eq!(out_len, width as usize * height as usize * 3, "{what} round {round}: size and pixels disagree");
            unsafe { dz_free(out, out_len) };
        } else {
            assert!(out.is_null() && out_len == 0, "{what} round {round}: a failure left something to free");
        }
        panicked
    }

    #[test]
    fn mutated_pictures_never_panic_or_lie_about_their_size() {
        for (name, seed) in picture_seeds() {
            assert!(!check_picture(&seed, name, 0)); // the seed itself is good
            assert_eq!(decode(&seed).map(|(w, h, p)| p.len() == (w * h * 3) as usize), Ok(true), "{name} seed does not decode");
            let mut rng = Rng(0x9E37_79B9_7F4A_7C15 ^ name.len() as u64 ^ (name.as_bytes()[0] as u64) << 8);
            let mut panics = 0;
            for round in 1..=rounds() {
                let mutated = mutate(&seed, &mut rng);
                panics += check_picture(&mutated, name, round) as usize;
            }
            // The `image` crate's readers never panic on these. The `psd` crate does on some malformed files (an index out of range in
            // its section parser): that is caught at the boundary and costs one file, so it is allowed here and counted, not hidden.
            if name == "psd" {
                eprintln!("psd: {panics} of {} mutated files made the psd crate panic (contained)", rounds());
            } else {
                assert_eq!(panics, 0, "{name}: the decoder panicked on {panics} mutated files");
            }
        }
    }

    #[test]
    fn random_bytes_are_never_a_picture_that_panics() {
        let mut rng = Rng(0xDEAD_BEEF_CAFE_F00D);
        for round in 0..rounds() {
            let bytes: Vec<u8> = (0..rng.below(300)).map(|_| rng.next() as u8).collect();
            let _ = check_picture(&bytes, "noise", round);
            // Noise that starts like each format, so the decoder past the signature is exercised.
            for start in [&b"\x89PNG\r\n\x1a\n"[..], b"\xFF\xD8\xFF", b"GIF89a", b"BM", b"P6\n", b"8BPS"] {
                let mut with_start = start.to_vec();
                with_start.extend_from_slice(&bytes);
                let _ = check_picture(&with_start, "noise with a signature", round); // (a PSD signature may panic, contained)
            }
        }
    }

    #[test]
    fn mutated_zip_files_never_panic_and_never_exceed_the_limit() {
        let seed = zip_with("word/document.xml", &(0..4000).map(|i| (i % 251) as u8).collect::<Vec<u8>>());
        let mut rng = Rng(0x1234_5678_9ABC_DEF1);
        for round in 0..rounds() {
            let mutated = mutate(&seed, &mut rng);
            let data = mutated.clone();
            let callback = Callback { read: read_from_slice, context: &data as *const Vec<u8> as *mut c_void, size: data.len() as u64, position: 0 };
            // `zip_entry` is what the C entry point runs inside `catch_unwind`: a panic in it is caught there, so it is looked for here.
            let result = catch_unwind(AssertUnwindSafe(|| zip_entry(callback, "word/document.xml", 10_000)));
            match result {
                Ok(Ok(bytes)) => assert!(bytes.len() <= 10_000, "round {round}: more than the limit came out"),
                Ok(Err(_)) => {}
                Err(_) => panic!("round {round}: zip_entry panicked"),
            }
        }
    }
}
