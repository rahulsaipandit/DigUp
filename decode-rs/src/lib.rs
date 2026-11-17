// DOWNSTREAM-FORK (2026-11-17, security): new in the fork. See docs/design.md ("Rust decoders").
//
// What stb_image and miniz read for DigUp, in Rust: JPEG, PNG, GIF and BMP pictures, and one entry of a zip file. They parse files
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

fn supported(format: Option<ImageFormat>) -> Option<ImageFormat> {
    match format {
        Some(f @ (ImageFormat::Png | ImageFormat::Jpeg | ImageFormat::Gif | ImageFormat::Bmp)) => Some(f),
        _ => None,
    }
}

fn reader(bytes: &[u8]) -> Option<ImageReader<Cursor<&[u8]>>> {
    let mut reader = ImageReader::new(Cursor::new(bytes)).with_guessed_format().ok()?;
    supported(reader.format())?;
    let mut limits = Limits::default();
    limits.max_alloc = Some(MAX_PIXELS * 4); // bytes any one allocation may take while decoding
    reader.limits(limits);
    Some(reader)
}

fn info(bytes: &[u8]) -> Result<(u32, u32), i32> {
    let reader = reader(bytes).ok_or(UNSUPPORTED)?;
    let (width, height) = reader.into_dimensions().map_err(|_| CORRUPT)?;
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err(TOO_BIG);
    }
    Ok((width, height))
}

fn decode(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), i32> {
    let (width, height) = info(bytes)?;
    let image = reader(bytes).ok_or(UNSUPPORTED)?.decode().map_err(|error| match error {
        image::ImageError::Limits(_) => TOO_BIG,
        _ => CORRUPT,
    })?;
    // Packed 8-bit RGB, as stb gives with three channels: the alpha channel is dropped, 16 bits are cut to 8.
    Ok((width, height, image.into_rgb8().into_raw()))
}

/// The size of a picture this reads (JPEG, PNG, GIF, BMP, found by its first bytes), without decoding it.
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
}
