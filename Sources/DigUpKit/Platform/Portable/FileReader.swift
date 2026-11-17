// Reading a file for C libraries through Foundation rather than by path (Linux, Windows): miniz and PDFium open paths
// with fopen and CreateFileA, which on Windows read the ANSI code page, so a Bengali or Arabic file name wouldn't open.
// They read through `read(at:into:count:)` instead, a block at a time.
#if !canImport(PDFKit)
import Foundation
#if os(Windows)
import WinSDK
#endif

final class FileReader {
    let size: UInt64
    private let handle: FileHandle
    #if os(Windows)
    private var passedRaw: HANDLE?   // a copy of the handle `init(passedHandle:)` was made from, kept to duplicate from
    #endif

    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    #if os(Windows)
    /// DOWNSTREAM-FORK (2026-11-16, security): reads through an open Windows handle the helper handed to this process, so a
    /// worker that may open no paths can still read the one file. The handle is closed with the reader.
    init?(passedHandle raw: HANDLE?) {
        guard let raw, raw != INVALID_HANDLE_VALUE else { return nil }
        // A copy of our own first: FileHandle takes the original over, and it can't be duplicated after that.
        var own: HANDLE?
        guard DuplicateHandle(GetCurrentProcess(), raw, GetCurrentProcess(), &own, 0, false, DWORD(DUPLICATE_SAME_ACCESS)),
              let own else { CloseHandle(raw); return nil }   // the handle handed over is ours to close when it can't be used
        let descriptor = _open_osfhandle(intptr_t(bitPattern: raw), 0)   // _O_RDONLY
        guard descriptor >= 0 else { CloseHandle(own); CloseHandle(raw); return nil }   // neither is going to be used
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // `own` would leak on this path: the deinit that closes it doesn't run for an init that stops before `size` is set.
        guard let end = try? handle.seekToEnd() else { CloseHandle(own); return nil }
        size = end
        passedRaw = own
    }
    #endif

    deinit {
        try? handle.close()
        #if os(Windows)
        if let passedRaw { CloseHandle(passedRaw) }
        #endif
    }

    /// DOWNSTREAM-FORK (2026-11-17, security): another handle on the same open file, for a reader that opens by itself
    /// (EXIF's). Both seek before every read, so they can share the file's position. Only for a reader made from a handle
    /// handed over (Windows); nil otherwise.
    func duplicateHandle() -> FileHandle? {
        #if os(Windows)
        var copy: HANDLE?
        guard let own = passedRaw,
              DuplicateHandle(GetCurrentProcess(), own, GetCurrentProcess(), &copy, 0, false, DWORD(DUPLICATE_SAME_ACCESS)),
              let copy else { return nil }
        let descriptor = _open_osfhandle(intptr_t(bitPattern: copy), 0)
        guard descriptor >= 0 else { CloseHandle(copy); return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
        return nil
        #endif
    }

    /// Copies up to `count` bytes from `offset` into `buffer`; how many it copied.
    func read(at offset: UInt64, into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        guard count > 0, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count) else { return 0 }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        return data.count
    }

    /// Itself as a C callback's context (it must outlive the C library's use of it).
    var opaque: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    static func from(_ opaque: UnsafeMutableRawPointer?) -> FileReader {
        Unmanaged<FileReader>.fromOpaque(opaque!).takeUnretainedValue()
    }
}
#endif
