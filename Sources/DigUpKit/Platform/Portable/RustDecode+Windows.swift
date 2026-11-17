// DOWNSTREAM-FORK (2026-11-17, security): this whole file is new in the fork. See docs/design.md ("Rust decoders") and
// docs/downstream-fork-changes.md.
//
// decode-rs (Rust, built by scripts/build-decode-rs.sh) in place of what stb_image and miniz read, on Windows:
//   - zip files (docx, odt, xlsx, pptx, ods, odp): `ZipArchive` below, with the same interface as the miniz one in
//     Docs+Portable.swift. A zip entry comes out the same bytes whatever reads it.
//   - JPEG, PNG, GIF and BMP pictures, found by their first bytes: `RustDecode.imageInfo` and `decodeRGB`, used by the decode worker
//     (DecodeIsolation+Media.swift). What the Rust reader recognizes is never handed to stb when it is bad: a picture built to be
//     rejected here would otherwise reach the C reader. Other formats (PSD, TGA, PNM, which have no magic bytes it can use or are
//     not read by the `image` crate) still go to stb, inside the sandboxed worker.
//   - A JPEG decodes to pixels that differ from stb's by a few levels (another decoder); PNG, GIF and BMP are exact.
#if os(Windows)
import CDecode
import Foundation

enum RustDecode {
    // The codes of digup_decode.h.
    static let ok: Int32 = 0, unsupported: Int32 = 1, corrupt: Int32 = 2, tooBig: Int32 = 3, notAZip: Int32 = 4, noSuchEntry: Int32 = 5

    enum Info {
        case size(width: Int, height: Int)
        /// Not a picture the Rust reader reads: stb may.
        case notRust
        /// A picture it reads, and it is bad or too big: not handed to stb.
        case failed(String)
    }

    static func imageInfo(_ data: Data) -> Info {
        var width: Int32 = 0, height: Int32 = 0
        let code = data.withUnsafeBytes { dz_image_info($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &width, &height) }
        switch code {
        case ok: return .size(width: Int(width), height: Int(height))
        case unsupported: return .notRust
        case tooBig: return .failed("picture is too big to read")
        default: return .failed("can't decode image")
        }
    }

    /// Packed 8-bit RGB, or nil (it is bad, or too big).
    static func decodeRGB(_ data: Data) -> RGBImage? {
        var width: Int32 = 0, height: Int32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let code = data.withUnsafeBytes {
            dz_image_decode_rgb($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &width, &height, &out, &length)
        }
        guard code == ok, let out else { return nil }
        defer { dz_free(out, length) }
        guard width > 0, height > 0, length == Int(width) * Int(height) * 3 else { return nil }
        return RGBImage(width: Int(width), height: Int(height), pixels: Array(UnsafeBufferPointer(start: out, count: length)))
    }
}

/// Reads where decode-rs asks, through the `FileReader` that holds the file (any file name opens, or the handle handed over).
private let readThroughFileReader: @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafeMutablePointer<UInt8>?, Int) -> Int64 = {
    context, offset, buffer, length in
    guard let context, let buffer else { return -1 }
    return Int64(FileReader.from(context).read(at: offset, into: buffer, count: length))
}

/// A zip file's entries, through decode-rs. Platform/Apple has the same name, and Docs+Portable.swift the miniz one for the other
/// systems.
final class ZipArchive {
    private let reader: FileReader

    init(_ url: URL) throws {
        // DOWNSTREAM-FORK (2026-11-16, security): a worker that was handed an open file reads that, not the path.
        reader = try DecodeWorker.passed ?? FileReader(url)
        // Is it a zip at all? An entry that does not exist: a zip says "no such entry", anything else says "not a zip".
        let (code, _) = Self.entry(reader, "[DigUp probe: no such entry]", limit: 1)
        guard code == RustDecode.noSuchEntry || code == RustDecode.ok else { throw ExtractError.unreadable("not a zip file") }
    }

    private static func entry(_ reader: FileReader, _ name: String, limit: UInt64) -> (Int32, [UInt8]?) {
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let code = name.withCString {
            dz_zip_entry(readThroughFileReader, reader.opaque, reader.size, $0, limit, &out, &length)
        }
        guard code == RustDecode.ok, let out else { return (code, nil) }
        defer { dz_free(out, length) }
        return (code, Array(UnsafeBufferPointer(start: out, count: length)))
    }

    /// The entry's bytes, or nil when the zip has no such entry. An entry that declares more than `maxEntrySize` is refused before
    /// anything is allocated for it (a zip of a few KB can declare gigabytes), and what is read is cut at the limit too.
    func data(_ name: String) throws -> [UInt8]? {
        let (code, bytes) = Self.entry(reader, name, limit: UInt64(Self.maxEntrySize))
        switch code {
        case RustDecode.ok: return bytes ?? []
        case RustDecode.noSuchEntry: return nil
        case RustDecode.tooBig: throw ExtractError.unreadable("\(name) is more than is read")
        default: throw ExtractError.unreadable("can't read \(name)")
        }
    }
}
#endif
