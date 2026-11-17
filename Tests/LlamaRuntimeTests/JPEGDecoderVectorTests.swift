// DOWNSTREAM-FORK (2026-11-17, security): new in the fork. Does the Rust JPEG decoder (decode-rs, on Windows) move the vectors that stb's
// decoder gave? Each JPEG goes through what the indexer does with a picture (decode, turn by its EXIF orientation, scale to the
// indexer's size, write the picture the model reads), once with each decoder, and the model embeds both files. The cosine of the two
// vectors is what existing indexes would feel: ReferenceVectorTests asks 0.999 of runtimes that agree.
//
// Needs the model files (skipped without). With `DIGUP_JPEG_CORPUS` set to folders (separated by `;`) it measures every JPEG in them (at
// most `DIGUP_JPEG_LIMIT`, default 60); without, only the reference photo and the test pictures. It writes a table to
// digup-jpeg-vectors.log in the temp folder.
#if os(Windows)
import DigUpKit
import Foundation
import Testing
@testable import DigUpKit
@testable import LlamaRuntime

@Suite(.serialized) struct JPEGDecoderVectorTests {
    static let modelsThere = (try? LlamaModels.locate())?.media != nil
    /// Not ReferenceVectorTests' 0.999: that is asked of runtimes that should agree to the last bit. Another JPEG decoder rounds the
    /// pixels a little differently (0.05 to 0.6 levels on average), and on 39 pictures measured on 2026-11-17 the cosine was 0.9987 at
    /// worst and 0.9995 on average, which does not change what a search returns. Re-embedding every index for that would cost more than it
    /// gives, so `vectorVersion` was not bumped; this test says how far it may go.
    static let floor: Float = 0.998
    static let meanFloor: Float = 0.999

    static func corpus() -> [URL] {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found = [here.appendingPathComponent("Reference/photo.jpg")]
        let limit = ProcessInfo.processInfo.environment["DIGUP_JPEG_LIMIT"].flatMap(Int.init) ?? 60
        for folder in (ProcessInfo.processInfo.environment["DIGUP_JPEG_CORPUS"] ?? "").split(separator: ";") {
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: String(folder)), includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
                if found.count >= limit { return found }
                found.append(url)
            }
        }
        return found
    }

    /// What `ImageExtractor.prepare` does after the decode, with stb's decoder.
    static func prepareWithStb(_ url: URL, maxPixel: Int, to folder: URL) throws -> URL? {
        guard let decoded = RGBImage.loadStb(url.path) else { return nil }
        var image = decoded.oriented(EXIF.read(url)?.orientation ?? 1)
        let longest = max(image.width, image.height)
        if longest > maxPixel {
            let scale = Double(maxPixel) / Double(longest)
            image = try image.resized(width: max(1, Int((Double(image.width) * scale).rounded())),
                                      height: max(1, Int((Double(image.height) * scale).rounded())))
        }
        let out = folder.appendingPathComponent("stb-" + UUID().uuidString + ".jpg")
        try image.write(to: out, png: false)
        return out
    }

    @Test(.enabled(if: modelsThere)) func theRustJPEGDecoderGivesTheVectorsStbDid() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-JPEGVec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("digup-jpeg-vectors.log")
        let embedder = try LlamaEmbedder(models: LlamaModels.locate(), textOnly: false, log: log)
        defer { embedder.close() }

        var skipped: [String] = [], unreadable: [String] = []
        var rows: [(name: String, pixels: String, meanDiff: Double, cosine: Float)] = []
        for url in Self.corpus() {
            // The same call the indexer makes (a photo: 1024 pixels), which on Windows decodes with decode-rs.
            // A picture stb reads and the Rust decoder does not is a failure of the Rust decoder (progressive, CMYK, odd subsampling), not
            // a picture to leave out of the measurement. One stb cannot read either is not ours to measure.
            guard let stb = try Self.prepareWithStb(url, maxPixel: 1024, to: folder) else { skipped.append(url.lastPathComponent); continue }
            guard let rust = try? ImageExtractor.prepare(url, maxPixel: 1024, minSide: 0, to: folder, png: false) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            let (a, b) = (URL(fileURLWithPath: rust.path), stb)
            let pair = try embedder.embedImages([a.path, b.path], budget: 140)
            guard let va = pair[0].vector, let vb = pair[1].vector else {
                unreadable.append(url.lastPathComponent + " (no vector)")
                continue
            }
            let cosine = zip(va, vb).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            // How far apart the two prepared pictures are, in pixels, as another view of the same thing.
            let (pa, pb) = (RGBImage.loadStb(a.path), RGBImage.loadStb(b.path))
            var mean = -1.0
            if let pa, let pb, pa.pixels.count == pb.pixels.count {
                mean = Double(zip(pa.pixels, pb.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(pa.pixels.count)
            }
            rows.append((url.lastPathComponent, "\(rust.width)x\(rust.height)", mean, cosine))
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        try #require(!rows.isEmpty, "no JPEG could be measured")
        #expect(unreadable.isEmpty, "stb reads these and the Rust decoder (or the model) does not: \(unreadable)")
        print("JPEG vectors: \(rows.count) measured, \(skipped.count) that stb cannot read either")
        let worst = rows.min { $0.cosine < $1.cosine }!
        let mean = rows.reduce(Float(0)) { $0 + $1.cosine } / Float(rows.count)
        var report = "JPEGs measured: \(rows.count)\nmean cosine \(mean)\nworst \(worst.name) \(worst.cosine)\n\n"
        for row in rows.sorted(by: { $0.cosine < $1.cosine }) {
            report += "\(row.cosine)  meanPixelDiff \(String(format: "%.2f", row.meanDiff))  \(row.pixels)  \(row.name)\n"
        }
        try report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("digup-jpeg-vectors-table.txt"),
                         atomically: true, encoding: .utf8)
        #expect(worst.cosine >= Self.floor, "\(worst.name) moved to cosine \(worst.cosine); see digup-jpeg-vectors-table.txt")
        #expect(mean >= Self.meanFloor, "mean cosine \(mean)")
    }
}
#endif
