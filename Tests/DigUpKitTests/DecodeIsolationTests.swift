// DOWNSTREAM-FORK (2026-11-16, security): new in the fork. Checks the PDF worker (docs/decoder-worker.md).
#if !canImport(PDFKit)
import Foundation
import CMiniz
import Testing
@testable import DigUpKit
#if os(Windows)
import WinSDK
#endif

/// The worker is the `digup` program run as `digup decode-worker`, so these tests need it built (`swift build`, which
/// `swift test` does for the package) and find it beside the package's other build products.
@Suite(.serialized) struct DecodeIsolationTests {
    static let helper: URL = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let name = FileSystem.program("digup")
        let candidates = [root.appendingPathComponent(".build/debug/\(name)")]
            + (Bundle.main.executableURL.map { [$0.deletingLastPathComponent().appendingPathComponent(name)] } ?? [])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
    }()

    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-Decode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Runs `body` with the worker switched on and pointed at the built helper.
    func isolated<T>(_ body: () throws -> T) rethrows -> T {
        try DecodeIsolation.$forced.withValue(true) {
            try DecodeIsolation.$forcedHelper.withValue(Self.helper) {
                #if os(Windows)
                // The parent here is a test runner, so the worker's DLL folders are named: the folders on PATH that hold the
                // worker's llama.cpp, PDFium and Swift runtime DLLs.
                let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ";").map(String.init)
                let needed = path.filter { folder in
                    ["llama.dll", "pdfium.dll", "swiftCore.dll"].contains { FileManager.default.fileExists(atPath: folder + "\\" + $0) }
                }
                return try AppContainer.$extraFolders.withValue(needed, operation: body)
                #else
                return try body()
                #endif
            }
        }
    }

    @Test func helperIsBuilt() {
        #expect(FileManager.default.isExecutableFile(atPath: Self.helper.path), "build the package first: \(Self.helper.path)")
    }

    @Test func workerReadsAPDFAsTheDirectCodeDoes() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("notes.pdf")
        try TextPDF.write(["First page about quokkas.", "Second page about wombats.", "Third page."], to: pdf,
                          info: "/Title (Field notes)")
        let direct = try PDFExtractor.pages(of: pdf, range: { _ in 0..<2 }, minText: 1, renderPixels: 800,
                                            to: folder.appendingPathComponent("direct"))
        let viaWorker = try isolated {
            try PDFExtractor.pages(of: pdf, range: { _ in 0..<2 }, minText: 1, renderPixels: 800,
                                   to: folder.appendingPathComponent("worker"))
        }
        #expect(viaWorker.total == direct.total && viaWorker.total == 3)
        #expect(viaWorker.title == direct.title && viaWorker.title == "Field notes")
        #expect(viaWorker.pages.map(\.number) == direct.pages.map(\.number))
        #expect(viaWorker.pages.map(\.text) == direct.pages.map(\.text))
        #expect(viaWorker.pages.map(\.text).first?.contains("quokkas") == true)
    }

    @Test func pagesWithLittleTextComeBackAsPictures() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("slide.pdf")
        try TextPDF.write(["Short."], to: pdf)
        // minText far above the page's text: the page is rendered, and the picture reaches the folder the caller named.
        let read = try isolated {
            try PDFExtractor.pages(of: pdf, range: { 0..<$0 }, minText: 1000, renderPixels: 300,
                                   to: folder.appendingPathComponent("pictures"))
        }
        let path = try #require(read.pages.first?.imagePath)
        #expect(path.hasPrefix(folder.appendingPathComponent("pictures").path))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(bytes.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "a PNG")
    }

    // MARK: pictures (stb) and zip-based documents (miniz) in the worker

    /// The same five pictures `ImageTests` prepares: stb reads the JPEG in the worker, and the worker hands the HEIC, WebP,
    /// TIFF and AVIF to ffmpeg, which the helper runs.
    @Test(arguments: ["pattern-o6.jpg", "pattern-o6.heic", "pattern-o6.webp", "pattern-o6.tiff", "pattern.avif"])
    func picturesComeOutAsTheDirectCodeMakesThem(_ name: String) throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = ImageTests.pictures.appendingPathComponent(name)
        let direct = try ImageExtractor.prepare(url, maxPixel: 1024, minSide: 256, to: folder, png: true)
        let viaWorker = try isolated {
            try ImageExtractor.prepare(url, maxPixel: 1024, minSide: 256, to: folder, png: true)
        }
        #expect(viaWorker.width == direct.width && viaWorker.height == direct.height)
        #expect(viaWorker.taken == direct.taken && viaWorker.taken == "2024:05:17 10:30:00")
        let shown = try ImageTests.decode(viaWorker.path)
        let expected = try ImageTests.decode(direct.path)
        #expect(shown.width == expected.width && shown.height == expected.height)
        #expect(shown.quadrants == expected.quadrants)
    }

    @Test func theWorkerReadsExifFromTheHandleItWasGiven() throws {
        let url = ImageTests.pictures.appendingPathComponent("pattern-o6.jpg")
        let reply = try DecodeIsolation.$selftest.withValue(true) {
            DecodeClient.shared.stopForTesting()
            defer { DecodeClient.shared.stopForTesting() }
            return try isolated { try DecodeClient.shared.request(["op": "selftest.exif", "path": url.path], file: url) }
        }
        #expect(reply["passed"] as? Bool == true, "\(reply)")
        #expect(reply["duplicated"] as? Bool == true, "\(reply)")
        #expect(reply["exif"] as? Bool == true, "\(reply)")
    }

    @Test func smallPicturesAreStillSkippedThroughTheWorker() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = ImageTests.pictures.appendingPathComponent("pattern-o6.jpg")
        do {
            _ = try isolated { try ImageExtractor.prepare(url, maxPixel: 1024, minSide: 401, to: folder, png: true) }
            Issue.record("a 400-pixel picture should be too small for 401")
        } catch ExtractError.tooSmall(let width, let height) {
            #expect(Set([width, height]) == [400, 240])
        }
    }

    /// A zip with one deflated entry, as Word and LibreOffice write theirs.
    func zip(named file: String, entry: String, _ bytes: [UInt8], in folder: URL) throws -> URL {
        var archive = mz_zip_archive()
        guard mz_zip_writer_init_heap(&archive, 0, 0) != 0 else { throw ExtractError.unreadable("can't start a zip") }
        defer { mz_zip_writer_end(&archive) }
        let added = bytes.withUnsafeBytes { mz_zip_writer_add_mem(&archive, entry, $0.baseAddress, $0.count, 1) }
        guard added != 0 else { throw ExtractError.unreadable("can't add the entry") }
        var pointer: UnsafeMutableRawPointer?
        var size = 0
        guard mz_zip_writer_finalize_heap_archive(&archive, &pointer, &size) != 0, let pointer else {
            throw ExtractError.unreadable("can't finish the zip")
        }
        defer { mz_free(pointer) }
        let url = folder.appendingPathComponent(file)
        try Data(bytes: pointer, count: size).write(to: url)
        return url
    }

    @Test func aWordFileIsReadInTheWorkerAsTheDirectCodeReadsIt() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let docx = try zip(named: "notes.docx", entry: "word/document.xml",
                           Array("<w:document><w:p>hello from the worker</w:p><w:p>second paragraph</w:p></w:document>".utf8),
                           in: folder)
        let direct = try DocExtractor.text(of: docx)
        let viaWorker = try isolated { try DocExtractor.text(of: docx) }
        #expect(viaWorker == direct)
        #expect(viaWorker.contains("hello from the worker") && viaWorker.contains("second paragraph"))
    }

    @Test func aZipThatDeclaresTooMuchIsRefusedInTheWorker() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let declared = Int(Zip.maxEntryBytes) + 1
        let bomb = try zip(named: "bomb.docx", entry: "word/document.xml", [UInt8](repeating: 0x41, count: declared), in: folder)
        #expect(throws: ExtractError.self) { try isolated { try DocExtractor.text(of: bomb) } }
        // And the worker is still there for the next file.
        let fine = try zip(named: "fine.docx", entry: "word/document.xml", Array("<w:p>still here</w:p>".utf8), in: folder)
        #expect(try isolated { try DocExtractor.text(of: fine) }.contains("still here"))
    }

    // MARK: when it is on

    @Test func theWorkerIsOnByDefaultOnlyInTheHelperOnWindows() {
        let helper = URL(fileURLWithPath: "C:\\DigUp\\digup.exe")
        let runner = URL(fileURLWithPath: "C:\\Swift\\xctest.exe")
        // The switch decides when it is set.
        #expect(DecodeIsolation.resolve(environment: "1", program: runner))
        #expect(!DecodeIsolation.resolve(environment: "0", program: helper))
        #expect(!DecodeIsolation.resolve(environment: nil, program: runner), "a test runner would start itself as the worker")
        #expect(!DecodeIsolation.resolve(environment: nil, program: nil))
        #if os(Windows)
        #expect(DecodeIsolation.resolve(environment: nil, program: helper))
        #expect(DecodeIsolation.resolve(environment: nil, program: URL(fileURLWithPath: "C:\\DigUp\\DIGUP.EXE")))
        #else
        #expect(!DecodeIsolation.resolve(environment: nil, program: helper), "no sandbox here yet")
        #endif
    }

    // MARK: the Rust readers (decode-rs) in place of stb and miniz

    /// Which reader the worker uses for a file's bytes.
    func reader(of file: URL) throws -> String {
        let reply = try DecodeIsolation.$selftest.withValue(true) {
            DecodeClient.shared.stopForTesting()
            defer { DecodeClient.shared.stopForTesting() }
            return try isolated { try DecodeClient.shared.request(["op": "selftest.reader", "path": file.path], file: file) }
        }
        return reply["reader"] as? String ?? ""
    }

    /// A 2x2 24-bit BMP, bottom row first, with pixels in B, G, R order and each row padded to 4 bytes.
    static let bmp: Data = {
        var bytes: [UInt8] = [0x42, 0x4D, 70, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0, 40, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 24, 0,
                              0, 0, 0, 0, 16, 0, 0, 0, 0x13, 0x0B, 0, 0, 0x13, 0x0B, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        bytes += [255, 0, 0, 0, 255, 0, 0, 0]          // bottom row: blue, green, then 2 bytes of padding
        bytes += [0, 0, 255, 255, 255, 255, 0, 0]      // top row: red, white, then 2 bytes of padding
        return Data(bytes)
    }()

    @Test func theRustReaderIsTheOneInUseForTheFormatsItReads() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpg = ImageTests.pictures.appendingPathComponent("pattern-o6.jpg")
        let png = folder.appendingPathComponent("a.png"), bmp = folder.appendingPathComponent("a.bmp"), ppm = folder.appendingPathComponent("a.ppm")
        try RGBImage(width: 2, height: 2, pixels: [255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9]).write(to: png, png: true)
        try Self.bmp.write(to: bmp)
        try (Data("P6 2 2 255\n".utf8) + Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9])).write(to: ppm)
        #expect(try reader(of: jpg) == "rust")
        #expect(try reader(of: png) == "rust")
        #expect(try reader(of: bmp) == "rust")
        #expect(try reader(of: ppm) == "stb", "a format the Rust reader does not read still goes to stb")
    }

    @Test func theRustReaderGivesTheSamePixelsAsStbForPNGAndBMPAndNearlyForJPEG() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // PNG: written with stb, read by both, and exactly the same.
        var pixels = [UInt8]()
        for y in 0..<17 { for x in 0..<23 { pixels += [UInt8(x * 11 % 256), UInt8(y * 15 % 256), UInt8((x * y) % 256)] } }
        let source = RGBImage(width: 23, height: 17, pixels: pixels)
        let png = folder.appendingPathComponent("a.png")
        try source.write(to: png, png: true)
        let pngBytes = try Data(contentsOf: png)
        let rustPNG = try #require(RustDecode.decodeRGB(pngBytes)), stbPNG = try #require(RGBImage.load(pngBytes))
        #expect(rustPNG.width == stbPNG.width && rustPNG.height == stbPNG.height && rustPNG.pixels == stbPNG.pixels)
        #expect(rustPNG.pixels == pixels, "and what was written")
        // BMP: exactly the same.
        let rustBMP = try #require(RustDecode.decodeRGB(Self.bmp)), stbBMP = try #require(RGBImage.load(Self.bmp))
        #expect(rustBMP.pixels == stbBMP.pixels && rustBMP.pixels == [255, 0, 0, 255, 255, 255, 0, 0, 255, 0, 255, 0])
        // JPEG: another decoder, so a few levels apart at most on average.
        let jpgBytes = try Data(contentsOf: ImageTests.pictures.appendingPathComponent("pattern-o6.jpg"))
        let rustJPG = try #require(RustDecode.decodeRGB(jpgBytes)), stbJPG = try #require(RGBImage.load(jpgBytes))
        #expect(rustJPG.width == stbJPG.width && rustJPG.height == stbJPG.height)
        let total = Swift.zip(rustJPG.pixels, stbJPG.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        #expect(Double(total) / Double(rustJPG.pixels.count) < 3, "mean difference per channel value")
    }

    @Test func aBadPictureInAFormatTheRustReaderReadsIsRefusedAndNotHandedToStb() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("cut.png")
        try RGBImage(width: 64, height: 64, pixels: [UInt8](repeating: 120, count: 64 * 64 * 3)).write(to: png, png: true)
        var bytes = try Data(contentsOf: png)
        bytes.removeLast(bytes.count / 2)
        try bytes.write(to: png)
        #expect(try reader(of: png) == "rust (refused)" || reader(of: png) == "rust")
        #expect(throws: ExtractError.self) {
            try isolated { try ImageExtractor.prepare(png, maxPixel: 1024, minSide: 0, to: folder, png: true) }
        }
    }

    @Test func zipEntriesComeOutAsTheBytesThatWentIn() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let content = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 8)) }
        let zip = try self.zip(named: "binary.zip", entry: "dir/part.bin", content, in: folder)
        let archive = try ZipArchive(zip)
        #expect(try archive.data("dir/part.bin") == content)
        #expect(try archive.data("dir/missing.bin") == nil)
        #expect(throws: (any Error).self) { try ZipArchive(folder.appendingPathComponent("binary.zip.nothing")) }
        let notZip = folder.appendingPathComponent("plain.docx")
        try Data("not a zip at all".utf8).write(to: notZip)
        do { _ = try ZipArchive(notZip); Issue.record("a text file is not a zip") } catch {
            #expect("\(error)" == "unreadable: not a zip file")
        }
    }

    @Test func rangeIsClampedToThePages() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("two.pdf")
        try TextPDF.write(["One.", "Two."], to: pdf)
        let read = try isolated {
            try PDFExtractor.pages(of: pdf, range: { _ in 0..<50 }, minText: 1, renderPixels: 400, to: folder)
        }
        #expect(read.total == 2 && read.pages.map(\.number) == [1, 2])
    }

    @Test func workerCountsAndRendersPages() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("book.pdf")
        try TextPDF.write((1...7).map { "Page \($0)" }, to: pdf)
        try isolated {
            #expect(Estimator.pages(of: pdf.path) == 7)
            let out = folder.appendingPathComponent("page3.jpg")
            try PDFExtractor.renderPage(3, of: pdf, pixels: 300, to: out)
            #expect((try Data(contentsOf: out)).count > 100)
        }
    }

    @Test func aFileThatIsNotAPDFIsUnreadableAndTheWorkerLivesOn() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let junk = folder.appendingPathComponent("junk.pdf")
        try Data("this is not a PDF".utf8).write(to: junk)
        let good = folder.appendingPathComponent("good.pdf")
        try TextPDF.write(["Still works."], to: good)
        try isolated {
            #expect(throws: ExtractError.self) {
                try PDFExtractor.pages(of: junk, range: { $0 > 0 ? 0..<$0 : 0..<0 }, minText: 1, renderPixels: 400, to: folder)
            }
            let read = try PDFExtractor.pages(of: good, range: { 0..<$0 }, minText: 1, renderPixels: 400, to: folder)
            #expect(read.pages.first?.text.contains("Still works") == true)
        }
    }

    @Test func aStoppedWorkerIsStartedAgain() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("a.pdf")
        try TextPDF.write(["Alive."], to: pdf)
        try isolated {
            #expect(Estimator.pages(of: pdf.path) == 1)
            DecodeClient.shared.stopForTesting()   // as a crash would
            #expect(Estimator.pages(of: pdf.path) == 1)
        }
    }

    #if os(Windows)
    /// What the worker says about its own confinement (it answers `selftest.*` only when a test asks).
    func selftest(_ op: String, _ fields: [String: Any] = [:]) throws -> [String: Any] {
        try DecodeIsolation.$selftest.withValue(true) {
            DecodeClient.shared.stopForTesting()   // a worker started for this, with the selftest operations on
            defer { DecodeClient.shared.stopForTesting() }
            return try isolated { try DecodeClient.shared.request(fields.merging(["op": op]) { $1 }) }
        }
    }

    @Test func windowsWorkerRunsInAJobWithLimits() throws {
        let job = try selftest("selftest.job")
        #expect(job["inJob"] as? Bool == true)
        let flags = job["flags"] as? Int ?? 0
        #expect(flags & 0x2000 != 0, "kill on job close")
        #expect(flags & 0x8 != 0 && job["activeProcessLimit"] as? Int == 1, "one process only")
        #expect(flags & 0x100 != 0 && (job["memoryLimit"] as? Int ?? 0) > 0, "a memory cap")
        let ui = job["ui"] as? Int ?? 0
        // No clipboard (0x2, 0x4), system parameters (0x8), display settings (0x10), global atoms (0x20), desktop (0x40),
        // exit-windows (0x80).
        #expect(ui & 0xFE == 0xFE)
    }

    @Test func windowsWorkerCannotStartAnotherProgram() throws {
        #expect(try selftest("selftest.spawn")["spawned"] as? Bool == false)
    }

    @Test func windowsWorkerCannotOpenAFileItWasNotHanded() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appendingPathComponent("secret.txt")
        try Data("the user's own file".utf8).write(to: secret)
        // The control: outside the sandbox the same worker opens it, so a refusal below is the sandbox's.
        let control = try SandboxPolicy.$forced.withValue(false) { try selftest("selftest.open", ["path": secret.path]) }
        #expect(control["opened"] as? Bool == true)
        #expect(try selftest("selftest.open", ["path": secret.path])["opened"] as? Bool == false)
    }

    /// A listener on this machine's loopback address, on a port the system picks: what a worker would send data to.
    final class Listener {
        let port: Int
        private let handle: SOCKET

        init() throws {
            var data = WSADATA()
            guard WSAStartup(0x0202, &data) == 0 else { throw SandboxError(step: "test sockets", code: 0) }
            let local = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
            var address = sockaddr_in()
            address.sin_family = ADDRESS_FAMILY(AF_INET)
            address.sin_addr.S_un.S_addr = 0x0100_007F
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(local, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
            }
            var size = Int32(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(local, $0, &size) }
            }
            guard bound == 0, named == 0, listen(local, 4) == 0 else {
                throw SandboxError(step: "test listener", code: UInt32(WSAGetLastError()))
            }
            handle = local
            port = Int(UInt16(bigEndian: address.sin_port))
        }

        deinit {
            closesocket(handle)
            WSACleanup()
        }
    }

    @Test func windowsWorkerCannotReachTheNetwork() throws {
        let listener = try Listener()
        // The control: outside the sandbox the same worker connects, so a refusal below is the sandbox's.
        let control = try SandboxPolicy.$forced.withValue(false) { try selftest("selftest.connect", ["port": listener.port]) }
        #expect(control["connected"] as? Bool == true)
        #expect(try selftest("selftest.connect", ["port": listener.port])["connected"] as? Bool == false)
    }

    // MARK: taking the sandbox away (throwaway containers, never the real one)

    func throwawayName() -> String { "DigUp.Test-" + UUID().uuidString.prefix(12) }

    @Test func aGrantCanBeSeenAndTakenAway() throws {
        let name = throwawayName()
        defer { AppContainer.deleteProfile(name) }
        guard case .success(let sid) = AppContainer.makeSid(name) else { Issue.record("no container"); return }
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!AppContainer.hasGrant(folder.path, for: sid))
        try AppContainer.grantRead(folder.path, to: sid)
        #expect(AppContainer.hasGrant(folder.path, for: sid))
        try AppContainer.revoke(folder.path, from: sid)
        #expect(!AppContainer.hasGrant(folder.path, for: sid))
    }

    @Test func removingTheSandboxTakesTheGrantsAndTheProfileAway() throws {
        let name = throwawayName()
        guard case .success(let sid) = AppContainer.makeSid(name), case .success(let work) = AppContainer.makeWorkFolder(sid) else {
            Issue.record("no container"); return
        }
        defer { AppContainer.deleteProfile(name) }
        let one = try folder(), two = try folder()
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
        try AppContainer.grantRead(one.path, to: sid)
        try AppContainer.grantRead(two.path, to: sid)
        // One folder is on the list, one is named on the command line.
        let list = one.appendingPathComponent("grants.txt").path
        try Data((one.path + "\n").utf8).write(to: URL(fileURLWithPath: list))
        #expect(FileManager.default.fileExists(atPath: work))

        var lines: [String] = []
        let ok = AppContainer.removeAll(name: name, manifest: list, extra: [two.path]) { lines.append($0) }
        #expect(ok, "\(lines)")
        #expect(!AppContainer.hasGrant(one.path, for: sid) && !AppContainer.hasGrant(two.path, for: sid))
        #expect(!FileManager.default.fileExists(atPath: list), "the list goes when everything went well")
        #expect(!FileManager.default.fileExists(atPath: work), "the profile folder is gone")
        #expect(lines.contains { $0.contains("deleted the container profile") })
        // A second run has nothing left to do, and says so without failing.
        #expect(AppContainer.removeAll(name: name, manifest: list, extra: []) { _ in })
    }

    @Test func grantingToTheRealContainerIsListed() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try AppContainer.grantRead(folder.path)
        defer {
            // Leave the real container as it was: this folder is temporary.
            if case .success(let sid) = AppContainer.sid { try? AppContainer.revoke(folder.path, from: sid) }
        }
        #expect(AppContainer.manifestFolders().contains(folder.path))
    }

    @Test func theSweepRemovesOnlyOldFilesFromTheScratchFolder() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("old.jpg"), fresh = folder.appendingPathComponent("fresh.jpg")
        try Data("a".utf8).write(to: old)
        try Data("b".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        #expect(AppContainer.sweepWorkFolder(folder.path, olderThan: 600) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path), "a file a worker may be writing now stays")
        #expect(AppContainer.sweepWorkFolder(folder.path, olderThan: 600) == 0)
    }

    // MARK: ffmpeg and ffprobe in the sandbox

    static let video = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Videos/shots.ts")

    /// Runs a program as `SandboxedProcess` does, to the end, and returns what it wrote and how it ended.
    func sandboxed(_ program: String, _ arguments: [String], input: URL?) throws -> (output: String, code: UInt32?) {
        let exe = URL(fileURLWithPath: program)
        let folder = exe.deletingLastPathComponent().path.replacingOccurrences(of: "/", with: "\\")
        let process = try SandboxedProcess(executable: exe, arguments: arguments, environment: ProcessInfo.processInfo.environment,
                                           standardInput: input, grantFolders: [folder])
        defer { process.close() }
        var data = Data()
        while true {
            let chunk = process.read()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return (String(decoding: data, as: UTF8.self), process.exitCode())
    }

    @Test func sandboxedFFprobeReadsTheFileItIsHandedAndNoOther() throws {
        let probe = try #require(FFmpeg.ffprobe, "ffprobe isn't installed")
        let showDuration = ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1"]
        // Handed the file as its standard input, it reads it (and can seek in it).
        let handed = try sandboxed(probe, showDuration + ["-fd", "0", "-i", "fd:"], input: Self.video)
        #expect(handed.code == 0 && Double(handed.output.trimmingCharacters(in: .whitespacesAndNewlines)) == 12.0)
        // Told the file's path, it can't open it: the container has no access there. (The same call outside the sandbox works.)
        let byPath = try sandboxed(probe, showDuration + [Self.video.path], input: nil)
        #expect(byPath.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && byPath.code != 0)
        let control = try FFmpeg.output(probe, showDuration + [Self.video.path])
        #expect(Double(control.trimmingCharacters(in: .whitespacesAndNewlines)) == 12.0, "the path itself is fine for a plain process")
    }

    @Test func ffmpegThroughTheSandboxGivesTheSameAnswersAsOutsideIt() throws {
        let url = Self.video
        let direct = (MediaInfo.duration(of: url), MediaInfo.streams(of: url))
        let viaSandbox = isolated { (MediaInfo.duration(of: url), MediaInfo.streams(of: url)) }
        #expect(viaSandbox.0 == direct.0 && viaSandbox.0 == 12.0)
        #expect(viaSandbox.1 == direct.1 && viaSandbox.1.video)
    }

    @Test func ffmpegIsStartedInTheSandboxExactlyWhenTheWorkerIsInUse() throws {
        let url = Self.video
        let sandboxed = SandboxLaunches.Tracker(), plain = SandboxLaunches.Tracker(), noSandbox = SandboxLaunches.Tracker()
        _ = SandboxLaunches.$tracker.withValue(sandboxed) { isolated { MediaInfo.duration(of: url) } }
        #expect(sandboxed.count > 0, "a call with the worker in use starts ffprobe in the sandbox")
        // With the worker off, the same call starts it as a plain process.
        _ = SandboxLaunches.$tracker.withValue(plain) { DecodeIsolation.$forced.withValue(false) { MediaInfo.duration(of: url) } }
        #expect(plain.count == 0)
        // With DIGUP_SANDBOX=0 (a task-local here), a plain launch too.
        _ = SandboxLaunches.$tracker.withValue(noSandbox) {
            isolated { SandboxPolicy.$forced.withValue(false) { MediaInfo.duration(of: url) } }
        }
        #expect(noSandbox.count == 0)
    }

    @Test func aFrameWrittenAsAFileInsideTheSandboxReachesTheCallersFolder() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("frame.jpg")
        try isolated {
            try runBlocking { try await VideoExtractor.frame(at: 6, of: Self.video, pixels: 320, to: out) }
        }
        let bytes = try Data(contentsOf: out)
        #expect(bytes.prefix(2) == Data([0xFF, 0xD8]), "a JPEG")
    }

    @Test func theSwitchStartsTheWorkerWithoutTheSandbox() throws {
        // With DIGUP_SANDBOX=0 the worker comes from Foundation's Process, outside any job of its own making.
        let job = try SandboxPolicy.$forced.withValue(false) { try selftest("selftest.job") }
        #expect(job["activeProcessLimit"] as? Int != 1)
    }
    #endif

    @Test func aWorkerThatCannotStartLeavesATraceOnceForEachReason() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("decode-worker.log").path
        #expect(DecodeLog.note("PDF reader couldn't start: test reason", to: log))
        #expect(!DecodeLog.note("PDF reader couldn't start: test reason", to: log), "the same reason is not repeated")
        #expect(DecodeLog.note("PDF reader couldn't start: another reason", to: log))
        let lines = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2 && lines[0].contains("test reason") && lines[1].contains("another reason"))
    }

    @Test func aWorkerThatCannotStartIsAnErrorNotASilentFallback() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("a.pdf")
        try TextPDF.write(["Alive."], to: pdf)
        DecodeClient.shared.stopForTesting()
        let log = folder.appendingPathComponent("decode-worker.log").path
        DecodeLog.$forcedPath.withValue(log) {
            DecodeIsolation.$forced.withValue(true) {
                DecodeIsolation.$forcedHelper.withValue(folder.appendingPathComponent("no-such-program")) {
                    #expect(throws: ExtractError.self) { try PDFExtractor.renderPage(1, of: pdf, pixels: 200, to: folder.appendingPathComponent("x.jpg")) }
                }
            }
        }
        DecodeClient.shared.stopForTesting()
        // The failure left a trace where a person can find it, not only in the error returned for the file.
        #expect((try? String(contentsOfFile: log, encoding: .utf8))?.contains("PDF reader couldn't start") == true)
    }
}
#endif
