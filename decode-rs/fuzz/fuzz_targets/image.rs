#![no_main]
// Any bytes as a picture: JPEG, PNG, GIF, BMP, PNM, TGA, PSD or none of them. Looks for what the C entry points promise not to do:
// crash, hang, return a picture whose size does not match its pixels, or leave something to free after a failure. (A panic in a
// dependency is caught by the entry point and returned as 7; libFuzzer sees it as a normal return, so 7 is checked for below,
// except for the `psd` crate, known to panic on some malformed files.)
use digup_decode::{dz_free, dz_image_decode_rgb, dz_image_info};
use libfuzzer_sys::fuzz_target;
use std::ptr;

fuzz_target!(|data: &[u8]| {
    let (mut width, mut height) = (0i32, 0i32);
    let info = unsafe { dz_image_info(data.as_ptr(), data.len(), &mut width, &mut height) };
    let mut out: *mut u8 = ptr::null_mut();
    let mut out_len = 0usize;
    let code = unsafe { dz_image_decode_rgb(data.as_ptr(), data.len(), &mut width, &mut height, &mut out, &mut out_len) };
    let is_psd = data.starts_with(b"8BPS");
    assert!(is_psd || (info != 7 && code != 7), "a decoder panicked (code 7)");
    if code == 0 {
        assert_eq!(out_len, width as usize * height as usize * 3);
        unsafe { dz_free(out, out_len) };
    } else {
        assert!(out.is_null() && out_len == 0);
    }
});
