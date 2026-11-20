//! DOWNSTREAM-FORK (2026-11-19): moving files to the Recycle Bin / Trash, for "Delete" on the selected results.
//! Nothing here deletes permanently: if the system can't recycle a file (a network share, a file too big for the bin),
//! it's left where it is and reported as not deleted (Windows may ask first, which is its own "permanently delete?" prompt).

use std::path::Path;

/// Moves one file to the bin. Ok when it's gone from where it was.
#[cfg(windows)]
pub fn trash(path: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::Shell::{SHFileOperationW, FO_DELETE, SHFILEOPSTRUCTW};
    // FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOERRORUI | FOF_WANTNUKEWARNING
    const FLAGS: u16 = 0x0004 | 0x0010 | 0x0040 | 0x0400 | 0x4000;
    let native = std::path::PathBuf::from(path.to_string_lossy().replace('/', "\\"));
    if !native.exists() {
        return Ok(());   // already gone
    }
    let from: Vec<u16> = native.as_os_str().encode_wide().chain([0, 0]).collect();   // the list ends in a second NUL
    // SAFETY: `from` is a NUL-terminated list that outlives the call; the other fields are zero (no window, no destination).
    let (code, aborted) = unsafe {
        let mut operation: SHFILEOPSTRUCTW = std::mem::zeroed();
        operation.wFunc = FO_DELETE;
        operation.pFrom = from.as_ptr();
        operation.fFlags = FLAGS;
        let code = SHFileOperationW(&mut operation);
        (code, operation.fAnyOperationsAborted != 0)
    };
    if code != 0 || aborted || native.exists() {
        return Err(if aborted { "cancelled".into() } else { format!("Windows couldn't move it to the Recycle Bin (code {code})") });
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn trash(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Ok(());
    }
    let status = std::process::Command::new("gio").arg("trash").arg("--").arg(path).status().map_err(|e| e.to_string())?;
    if status.success() { Ok(()) } else { Err("the Trash didn't take it".into()) }
}

#[cfg(target_os = "macos")]
pub fn trash(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Ok(());
    }
    let script = "on run argv\ntell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)\nend run";
    let status = std::process::Command::new("osascript").arg("-e").arg(script).arg(path).status().map_err(|e| e.to_string())?;
    if status.success() { Ok(()) } else { Err("the Trash didn't take it".into()) }
}
