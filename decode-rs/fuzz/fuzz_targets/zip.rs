#![no_main]
// Any bytes as a zip file, asked for one entry: never more than the limit, never a crash.
use digup_decode::{dz_free, dz_zip_entry};
use libfuzzer_sys::fuzz_target;
use std::ffi::c_void;
use std::ptr;

unsafe extern "C" fn read_from(context: *mut c_void, offset: u64, buffer: *mut u8, length: usize) -> i64 {
    let data = &*(context as *const &[u8]);
    let start = (offset as usize).min(data.len());
    let n = length.min(data.len() - start);
    ptr::copy_nonoverlapping(data.as_ptr().add(start), buffer, n);
    n as i64
}

fuzz_target!(|data: &[u8]| {
    let slice: &[u8] = data;
    let mut out: *mut u8 = ptr::null_mut();
    let mut out_len = 0usize;
    let limit = 1 << 20;
    let code = unsafe {
        dz_zip_entry(read_from, &slice as *const &[u8] as *mut c_void, data.len() as u64, c"word/document.xml".as_ptr(), limit, &mut out, &mut out_len)
    };
    assert_ne!(code, 7, "the zip reader panicked");
    if code == 0 {
        assert!(out_len as u64 <= limit);
        unsafe { dz_free(out, out_len) };
    }
});
