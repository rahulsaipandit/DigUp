// DOWNSTREAM-FORK (2026-11-17, security): this whole file is new in the fork. See docs/decoder-worker.md and
// docs/downstream-fork-changes.md.
//
// stb (pictures) and miniz (Word, Excel, PowerPoint and OpenDocument files) in the decode worker, beside PDFium
// (DecodeIsolation.swift). With DIGUP_ISOLATE_DECODERS=1, `ImageExtractor.prepare` and `DocExtractor.text` ask the worker.
//
// A picture is read whole into memory in the worker (at most 512 MB) and decoded from there, because stb opens paths and
// the sandboxed worker has only the handle it was handed. What stb can't read (HEIC, WebP, TIFF, AVIF) needs ffmpeg, which
// is a program of its own that a sandboxed worker may not start: the worker says so, and the helper runs ffmpeg as before.
// Everything ffmpeg writes is then scaled and written by stb in the helper, which is the one stb use left outside the
// worker (and `RGBImage.load` of the frames ffmpeg writes for videos, in Media+Portable.swift).
#if !canImport(PDFKit)
import CStb
import Foundation

/// What the worker made of a picture.
enum IsolatedImage {
    case prepared(ImageExtractor.Prepared)
    /// stb can't read it: ffmpeg does, here, and `taken` is its EXIF date.
    case viaFFmpeg(taken: String?)
}

extension DecodeClient {
    func imagePrepare(_ url: URL, maxPixel: Int, minSide: Int, folder: URL, png: Bool) throws -> IsolatedImage {
        let reply = try request(["op": "image.prepare", "path": url.path, "maxPixel": maxPixel, "minSide": minSide,
                                 "png": png, "folder": folder.path], file: url)
        if reply["route"] as? String == "ffmpeg" { return .viaFFmpeg(taken: reply["taken"] as? String) }
        guard let width = reply["width"] as? Int, let height = reply["height"] as? Int else {
            throw ExtractError.unreadable("picture reader gave no size")
        }
        var path = reply["path"] as? String
        // A worker that can't write to the user's folders sends the picture, and it is written here.
        if let encoded = reply["image"] as? String, let bytes = Data(base64Encoded: encoded) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let out = folder.appendingPathComponent(UUID().uuidString + (png ? ".png" : ".jpg"))
            try bytes.write(to: out)
            path = out.path
        }
        guard let path else { throw ExtractError.unreadable("picture reader gave no picture") }
        return .prepared(ImageExtractor.Prepared(path: path, width: width, height: height, taken: reply["taken"] as? String))
    }

    func docText(_ url: URL) throws -> String {
        try request(["op": "doc.text", "path": url.path], file: url)["text"] as? String ?? ""
    }
}

extension ImageExtractor {
    /// `prepare` with the decoding in the worker. The same results as `prepare`'s own code (Images+Portable.swift), whose
    /// steps it follows.
    static func prepareIsolated(_ url: URL, maxPixel: Int, minSide: Int, to folder: URL, png: Bool) throws -> Prepared {
        switch try DecodeClient.shared.imagePrepare(url, maxPixel: maxPixel, minSide: minSide, folder: folder, png: png) {
        case .prepared(let prepared):
            return prepared
        case .viaFFmpeg(let taken):
            var image = try decodeWithFFmpeg(url)
            // Its size as shown (ImageIO reports it as stored: the two differ for a picture turned 90°).
            let (width, height) = (image.width, image.height)
            guard max(width, height) >= minSide else { throw ExtractError.tooSmall(width, height) }
            let longest = max(image.width, image.height)
            if longest > maxPixel {
                let scale = Double(maxPixel) / Double(longest)
                image = try image.resized(width: max(1, Int((Double(image.width) * scale).rounded())),
                                          height: max(1, Int((Double(image.height) * scale).rounded())))
            }
            let out = folder.appendingPathComponent(UUID().uuidString + (png ? ".png" : ".jpg"))
            try image.write(to: out, png: png)
            return Prepared(path: out.path, width: width, height: height, taken: taken)
        }
    }
}

extension DecodeWorker {
    /// The most of a picture's file read into memory.
    private static let largestPicture: UInt64 = 512 << 20

    /// A picture's size and a way to decode it, from its bytes, or nil when neither reader knows it (ffmpeg may). On Windows the Rust
    /// reader goes first for JPEG, PNG, GIF and BMP, and a picture it recognizes and finds bad is refused, not handed to stb (a
    /// picture built to be rejected there would otherwise reach the C reader); stb reads the rest.
    private static func probePicture(_ bytes: Data) throws -> (width: Int, height: Int, decode: () throws -> RGBImage)? {
        #if os(Windows)
        switch RustDecode.imageInfo(bytes) {
        case .size(let width, let height):
            return (width, height, {
                guard let image = RustDecode.decodeRGB(bytes) else { throw ExtractError.unreadable("can't decode image") }
                return image
            })
        case .failed(let why):
            throw ExtractError.unreadable(why)
        case .notRust:
            break
        }
        #endif
        var storedWidth: Int32 = 0, storedHeight: Int32 = 0, channels: Int32 = 0
        let known = bytes.withUnsafeBytes {
            stbi_info_from_memory($0.bindMemory(to: UInt8.self).baseAddress, Int32(clamping: $0.count), &storedWidth,
                                  &storedHeight, &channels)
        } != 0
        guard known else { return nil }
        return (Int(storedWidth), Int(storedHeight), {
            guard let image = RGBImage.load(bytes) else { throw ExtractError.unreadable("can't decode image") }
            return image
        })
    }

    /// Which reader takes a picture's bytes: "rust", "rust (refused)" (it recognizes the format and finds the file bad), "stb", or
    /// "none" (ffmpeg's). For a test to see that the Rust reader is the one in use.
    static func readerName(_ bytes: Data) -> String {
        #if os(Windows)
        switch RustDecode.imageInfo(bytes) {
        case .size: return "rust"
        case .failed: return "rust (refused)"
        case .notRust: break
        }
        #endif
        var width: Int32 = 0, height: Int32 = 0, channels: Int32 = 0
        let known = bytes.withUnsafeBytes {
            stbi_info_from_memory($0.bindMemory(to: UInt8.self).baseAddress, Int32(clamping: $0.count), &width, &height, &channels)
        } != 0
        return known ? "stb" : "none"
    }

    /// The worker's half of `ImageExtractor.prepare`: stb's branch, from memory. Replies `route: ffmpeg` for what stb can't
    /// read, after the same checks `prepare` makes before it hands a file to ffmpeg.
    static func prepareImage(_ request: [String: Any], url: URL) throws -> [String: Any] {
        let maxPixel = request["maxPixel"] as? Int ?? 1024
        let minSide = request["minSide"] as? Int ?? 0
        let png = request["png"] as? Bool ?? false
        let exif = EXIF.read(url)
        let reader = try passed ?? FileReader(url)
        guard reader.size > 0, reader.size <= largestPicture else { throw ExtractError.unreadable("can't decode image") }
        var bytes = Data(count: Int(reader.size))
        let read = bytes.withUnsafeMutableBytes { reader.read(at: 0, into: $0.baseAddress!, count: $0.count) }
        guard read == bytes.count else { throw ExtractError.unreadable("can't read image") }

        guard let probe = try probePicture(bytes) else {
            if let note = ImageExtractor.notReadYet(url.pathExtension.lowercased()) { throw ExtractError.unreadable(note) }
            if exif?.tiled == true {
                throw ExtractError.unreadable("tiled TIFF pictures aren't read on this system yet")
            }
            return ["route": "ffmpeg", "taken": exif?.dateTimeOriginal.map { $0 as Any } ?? NSNull()]
        }
        let (width, height) = (probe.width, probe.height)
        guard max(width, height) >= minSide else { throw ExtractError.tooSmall(width, height) }
        var image = try probe.decode()
        image = image.oriented(exif?.orientation ?? 1)
        let longest = max(image.width, image.height)
        if longest > maxPixel {
            let scale = Double(maxPixel) / Double(longest)
            image = try image.resized(width: max(1, Int((Double(image.width) * scale).rounded())),
                                      height: max(1, Int((Double(image.height) * scale).rounded())))
        }
        // With a folder of its own (`work`), the worker writes there and sends the picture back.
        let work = (request["work"] as? String).map { URL(fileURLWithPath: $0) }
        let folder = work ?? URL(fileURLWithPath: request["folder"] as? String ?? "")
        let out = folder.appendingPathComponent(UUID().uuidString + (png ? ".png" : ".jpg"))
        try image.write(to: out, png: png)
        var reply: [String: Any] = ["width": width, "height": height,
                                    "taken": exif?.dateTimeOriginal.map { $0 as Any } ?? NSNull()]
        if work != nil {
            reply["image"] = (FileManager.default.contents(atPath: out.path) ?? Data()).base64EncodedString()
            try? FileManager.default.removeItem(at: out)
        } else {
            reply["path"] = out.path
        }
        return reply
    }
}
#endif
