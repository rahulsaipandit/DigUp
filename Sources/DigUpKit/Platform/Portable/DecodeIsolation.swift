// DOWNSTREAM-FORK (2026-11-16, security): this whole file is new in the fork. See docs/decoder-worker.md and
// docs/downstream-fork-changes.md.
//
// PDFium in its own process (Linux, Windows). With DIGUP_ISOLATE_DECODERS=1 the three places that read a PDF
// (PDFExtractor.pages, PDFExtractor.renderPage, Estimator.pages) ask `digup decode-worker` instead of calling PDFium in
// the helper's own process, so a bug in PDFium takes down the worker and not the index or the model. The worker runs the
// same PDFium code (with the switch off in its own environment) and speaks one JSON line each way, as `digup worker` does
// for the embedding model. A crash or a hang costs one file: the request throws `ExtractError.unreadable`, the worker is
// started again for the next one. On Windows the worker is started under a job object and mitigation policies
// (Sandbox+Windows.swift, docs/design.md); it has no AppContainer yet and still opens files by path.
#if !canImport(PDFKit)
import CPDFium
import Foundation
#if os(Windows)
import WinSDK
#endif

enum DecodeIsolation {
    static let environmentSwitch = "DIGUP_ISOLATE_DECODERS"

    /// What a test sets for the code it runs (a task-local, so tests that run side by side don't see each other's).
    @TaskLocal static var forced: Bool?
    @TaskLocal static var forcedHelper: URL?
    /// A test asks the worker to answer its `selftest.*` operations.
    @TaskLocal static var selftest = false

    /// Whether files are read in the worker. DIGUP_ISOLATE_DECODERS=1 turns it on and =0 off; with neither, it is on for the
    /// `digup` helper on Windows (see `resolve`). A worker is started with "0", so it reads in its own process.
    static var enabled: Bool {
        forced ?? resolve(environment: ProcessInfo.processInfo.environment[environmentSwitch], program: Bundle.main.executableURL)
    }

    /// DOWNSTREAM-FORK (2026-11-17, security): the worker is on by default where it has been tested: on Windows, in the
    /// program named `digup` (the helper and its command line), which is what starts a worker. Not in other programs, such as
    /// a test runner, which would start itself as the worker, and not on other systems, where there is no sandbox yet.
    static func resolve(environment: String?, program: URL?) -> Bool {
        switch environment {
        case "1": return true
        case "0": return false
        default:
            #if os(Windows)
            return program?.deletingPathExtension().lastPathComponent.lowercased() == "digup"
            #else
            return false
            #endif
        }
    }

    /// Seconds a request may take before the worker is killed (DIGUP_DECODE_TIMEOUT).
    static var timeout: TimeInterval {
        ProcessInfo.processInfo.environment["DIGUP_DECODE_TIMEOUT"].flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil }
            ?? 180
    }

    /// The program to start as the worker: DIGUP_DECODE_HELPER, else the running program (the helper is `digup`).
    static var helper: URL? {
        if let forcedHelper { return forcedHelper }
        if let chosen = ProcessInfo.processInfo.environment["DIGUP_DECODE_HELPER"], !chosen.isEmpty {
            return URL(fileURLWithPath: chosen)
        }
        return Bundle.main.executableURL
    }
}

/// A worker that cannot start fails every file it would have read, one by one, and the app shows no per-file failures. So
/// the reason is also written to `decode-worker.log` in DigUp's folder (`%LOCALAPPDATA%\DigUp` on Windows), once for each
/// reason in each process, with the time. `digup status` says where to look.
enum DecodeLog {
    /// What a test sets, so that it doesn't write to the real log.
    @TaskLocal static var forcedPath: String?

    static var path: String { forcedPath ?? AppPaths.applicationSupport.appendingPathComponent("decode-worker.log").path }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: Set<String> = []

    /// Appends one line unless this process has already written this message to this file. Returns whether it wrote.
    @discardableResult
    static func note(_ message: String, to file: String = path) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard seen.insert(file + "\n" + message).inserted else { return false }
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            return (try? handle.write(contentsOf: line)) != nil
        }
        return (try? line.write(to: URL(fileURLWithPath: file))) != nil
    }
}

/// What the helper sees of a worker process: bytes in, bytes out, and a way to end it.
protocol DecodeChannel: AnyObject, Sendable {
    var isRunning: Bool { get }
    func write(_ data: Data) throws
    /// What has arrived, waiting for at least some; empty when the worker has gone.
    func read() -> Data
    func terminate()
    func close()
    /// How the worker ended, for the error message (nil while it runs, or when not known).
    func exitStatus() -> String?
    /// A folder the worker may write to, or nil when it can write wherever the user can (then it writes where it is told).
    var workFolder: String? { get }
    /// Gives the worker an open read-only handle to `url` and returns its value in the worker, or nil when the worker opens
    /// paths itself.
    func passFile(_ url: URL) throws -> Int?
}

/// A worker started with Foundation's Process: on systems with no sandbox launch yet, and on Windows with DIGUP_SANDBOX=0.
final class ProcessChannel: DecodeChannel, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(executable: URL, arguments: [String], environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var isRunning: Bool { process.isRunning }
    func write(_ data: Data) throws { try input.fileHandleForWriting.write(contentsOf: data) }
    // availableData returns what has arrived (readData(ofLength:) waits to fill its length, and a reply is short).
    func read() -> Data { output.fileHandleForReading.availableData }
    func terminate() { if process.isRunning { process.terminate() } }
    func exitStatus() -> String? { process.isRunning ? nil : "exit code \(process.terminationStatus)" }
    var workFolder: String? { nil }
    func passFile(_ url: URL) throws -> Int? { nil }

    func close() {
        terminate()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }
}

/// The helper's side: one worker process, started when first needed and again after it stops.
final class DecodeClient: @unchecked Sendable {
    static let shared = DecodeClient()

    private final class Child: @unchecked Sendable {
        let channel: DecodeChannel
        var buffer = Data()
        init(_ channel: DecodeChannel) { self.channel = channel }
    }

    /// Set by the watchdog's thread, read by the one waiting on the worker.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private let lock = NSLock()
    private var child: Child?
    private var nextID = 1

    private func start() throws -> Child {
        guard let helper = DecodeIsolation.helper else {
            throw ExtractError.unreadable("PDF reader isn't available (no helper to start)")
        }
        var environment = ProcessInfo.processInfo.environment
        environment[DecodeIsolation.environmentSwitch] = "0"   // the worker reads in its own process
        if DecodeIsolation.selftest { environment["DIGUP_DECODE_SELFTEST"] = "1" }
        do {
            #if os(Windows)
            if SandboxPolicy.enabled {
                return Child(try SandboxedProcess(executable: helper, arguments: ["decode-worker"], environment: environment))
            }
            #endif
            return Child(try ProcessChannel(executable: helper, arguments: ["decode-worker"], environment: environment))
        } catch {
            let message = "PDF reader couldn't start: \(error)"
            DecodeLog.note(message)   // the app shows nothing per file, so a worker that can't start leaves a trace here
            throw ExtractError.unreadable(message)
        }
    }

    private static func how(_ worker: Child) -> String {
        worker.channel.exitStatus().map { " (\($0))" } ?? ""
    }

    /// For tests: ends the worker as a crash would, so the next request has to start a new one.
    func stopForTesting() {
        lock.withLock { drop() }
    }

    private func drop() {
        guard let old = child else { return }
        child = nil
        old.channel.close()
    }

    /// One line from the worker, or nil when it has stopped.
    private func readLine(_ child: Child) -> Data? {
        while true {
            if let newline = child.buffer.firstIndex(of: 0x0A) {
                let line = child.buffer[child.buffer.startIndex..<newline]
                child.buffer.removeSubrange(child.buffer.startIndex...newline)
                return Data(line)
            }
            let data = child.channel.read()
            if data.isEmpty { return nil }
            child.buffer.append(data)
        }
    }

    /// Sends one request and returns the reply's fields. Throws `ExtractError` for a worker that stopped or timed out, and
    /// for the failure the worker reported.
    func request(_ fields: [String: Any], file: URL? = nil) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let worker: Child
        if let running = child, running.channel.isRunning { worker = running } else {
            drop()
            worker = try start()
            child = worker
        }
        let id = nextID
        nextID += 1
        var message = fields
        message["id"] = id
        // A worker that can write only in a folder of its own is told which, and one that can read only what it is handed is
        // handed the file.
        if let work = worker.channel.workFolder { message["work"] = work }
        if let file {
            do { if let handle = try worker.channel.passFile(file) { message["handle"] = handle } } catch {
                throw ExtractError.unreadable("PDF reader can't be given the file: \(error)")
            }
        }
        let line = try JSONSerialization.data(withJSONObject: message) + [0x0A]
        // A worker that doesn't answer in time is killed: its pipe then closes and the read below ends.
        let timedOut = Flag()
        let watchdog = DispatchWorkItem { timedOut.set(); worker.channel.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + DecodeIsolation.timeout, execute: watchdog)
        defer { watchdog.cancel() }
        do { try worker.channel.write(line) } catch {
            drop()
            throw ExtractError.unreadable(timedOut.isSet ? "PDF reader timed out" : "PDF reader stopped\(Self.how(worker))")
        }
        guard let reply = readLine(worker),
              let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              (object["id"] as? Int) == id else {
            let how = Self.how(worker)
            drop()
            throw ExtractError.unreadable(timedOut.isSet ? "PDF reader timed out" : "PDF reader stopped\(how)")
        }
        guard object["ok"] as? Bool == true else {
            switch object["kind"] as? String {
            case "locked": throw ExtractError.locked
            case "tooSmall": throw ExtractError.tooSmall(object["width"] as? Int ?? 0, object["height"] as? Int ?? 0)
            default: throw ExtractError.unreadable(object["error"] as? String ?? "can't read PDF")
            }
        }
        return object
    }

    func pdfCount(_ url: URL) throws -> Int {
        try request(["op": "pdf.count", "path": url.path], file: url)["total"] as? Int ?? 0
    }

    func pdfPages(_ url: URL, range: Range<Int>, minText: Int, pixels: Int, folder: URL) throws
        -> (pages: [PDFExtractor.Page], total: Int, title: String?) {
        let reply = try request(["op": "pdf.pages", "path": url.path, "from": range.lowerBound, "to": range.upperBound,
                                 "minText": minText, "pixels": pixels, "folder": folder.path], file: url)
        let pages = try (reply["pages"] as? [[String: Any]] ?? []).compactMap { item -> PDFExtractor.Page? in
            guard let number = item["number"] as? Int, let text = item["text"] as? String else { return nil }
            var imagePath = item["imagePath"] as? String
            // A worker that can't write to the user's folders sends the picture, and it is written here.
            if let encoded = item["image"] as? String, let bytes = Data(base64Encoded: encoded) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let out = folder.appendingPathComponent(UUID().uuidString + ".png")
                try bytes.write(to: out)
                imagePath = out.path
            }
            return PDFExtractor.Page(number: number, text: text, imagePath: imagePath, ocr: item["ocr"] as? Bool ?? false,
                                     garbled: item["garbled"] as? String)
        }
        return (pages, reply["total"] as? Int ?? 0, reply["title"] as? String)
    }

    func pdfRender(_ number: Int, of url: URL, pixels: Int, to out: URL) throws {
        let reply = try request(["op": "pdf.render", "path": url.path, "page": number, "pixels": pixels, "out": out.path],
                                file: url)
        if let encoded = reply["image"] as? String, let bytes = Data(base64Encoded: encoded) {
            try bytes.write(to: out)
        }
    }
}

/// A reader is made and used on one thread at a time, and handed to a task-local for the length of one request.
extension FileReader: @unchecked Sendable {}

/// The worker's side, `digup decode-worker`: reads requests from standard input until `quit` or the end of the input.
public enum DecodeWorker {
    /// For `digup status`: where the log of workers that could not start is, once there is one.
    public static var logLine: String? {
        FileManager.default.fileExists(atPath: DecodeLog.path)
            ? "decode worker log: \(DecodeLog.path) (a file reader that could not start is recorded there)" : nil
    }

    /// The file the request handed over, which PDFium reads through (set while a request runs).
    @TaskLocal static var passed: FileReader?

    private static func emit(_ fields: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: fields) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    public static func run() -> Int32 {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id: Any = request["id"] ?? NSNull()
            do {
                switch request["op"] as? String {
                case "quit":
                    emit(["id": id, "ok": true])
                    return 0
                case "pdf.count":
                    let total = try withFile(request) { try PDFium.withDocument(url(request)) { Int(FPDF_GetPageCount($0)) } }
                    emit(["id": id, "ok": true, "total": total])
                case "pdf.pages":
                    let range = (request["from"] as? Int ?? 0)..<max(request["from"] as? Int ?? 0, request["to"] as? Int ?? 0)
                    // With a folder of its own (`work`), the worker renders there and sends the pictures back.
                    let work = (request["work"] as? String).map { URL(fileURLWithPath: $0) }
                    let folder = work ?? URL(fileURLWithPath: request["folder"] as? String ?? "")
                    let read = try withFile(request) {
                        try PDFExtractor.pages(of: url(request), range: { _ in range },
                                               minText: request["minText"] as? Int ?? 0,
                                               renderPixels: request["pixels"] as? Int ?? 1400, to: folder)
                    }
                    let pages: [[String: Any]] = read.pages.map { page in
                        var item: [String: Any] = ["number": page.number, "text": page.text, "ocr": page.ocr,
                                                   "garbled": page.garbled.map { $0 as Any } ?? NSNull(),
                                                   "imagePath": NSNull()]
                        if let path = page.imagePath {
                            if work != nil, let bytes = FileManager.default.contents(atPath: path) {
                                item["image"] = bytes.base64EncodedString()
                                try? FileManager.default.removeItem(atPath: path)
                            } else {
                                item["imagePath"] = path
                            }
                        }
                        return item
                    }
                    emit(["id": id, "ok": true, "pages": pages, "total": read.total,
                          "title": read.title.map { $0 as Any } ?? NSNull()])
                case "image.prepare":
                    var reply = try withFile(request) { try prepareImage(request, url: url(request)) }
                    reply["id"] = id; reply["ok"] = true
                    emit(reply)
                case "doc.text":
                    let text = try withFile(request) { try DocExtractor.text(of: url(request)) }
                    emit(["id": id, "ok": true, "text": text])
                case "pdf.render":
                    let work = (request["work"] as? String).map { URL(fileURLWithPath: $0) }
                    let out = work.map { $0.appendingPathComponent(UUID().uuidString + ".jpg") }
                        ?? URL(fileURLWithPath: request["out"] as? String ?? "")
                    try withFile(request) {
                        try PDFExtractor.renderPage(request["page"] as? Int ?? 1, of: url(request),
                                                    pixels: request["pixels"] as? Int ?? 1400, to: out)
                    }
                    if work != nil {
                        let bytes = FileManager.default.contents(atPath: out.path) ?? Data()
                        try? FileManager.default.removeItem(at: out)
                        emit(["id": id, "ok": true, "image": bytes.base64EncodedString()])
                    } else {
                        emit(["id": id, "ok": true])
                    }
                #if os(Windows)
                // Only when a test asked for them: they let a caller see how the worker is confined.
                case "selftest.job" where ProcessInfo.processInfo.environment["DIGUP_DECODE_SELFTEST"] == "1":
                    var reply = SandboxProbe.job()
                    reply["id"] = id; reply["ok"] = true
                    emit(reply)
                case "selftest.open" where ProcessInfo.processInfo.environment["DIGUP_DECODE_SELFTEST"] == "1":
                    let opened = (try? FileHandle(forReadingFrom: url(request))) != nil
                    emit(["id": id, "ok": true, "opened": opened])
                case "selftest.connect" where ProcessInfo.processInfo.environment["DIGUP_DECODE_SELFTEST"] == "1":
                    emit(["id": id, "ok": true, "connected": SandboxProbe.connects(toLoopbackPort: request["port"] as? Int ?? 0)])
                case "selftest.exif" where ProcessInfo.processInfo.environment["DIGUP_DECODE_SELFTEST"] == "1":
                    let reply: [String: Any] = try withFile(request) {
                        ["passed": passed != nil, "duplicated": passed?.duplicateHandle() != nil,
                         "exif": EXIF.read(url(request)) != nil, "size": Int(passed?.size ?? 0)]
                    }
                    emit(reply.merging(["id": id, "ok": true]) { $1 })
                case "selftest.reader" where ProcessInfo.processInfo.environment["DIGUP_DECODE_SELFTEST"] == "1":
                    let name: String = try withFile(request) {
                        let reader = try passed ?? FileReader(url(request))
                        var bytes = Data(count: Int(min(reader.size, 64 << 20)))
                        let got = bytes.withUnsafeMutableBytes { reader.read(at: 0, into: $0.baseAddress!, count: $0.count) }
                        return readerName(bytes.prefix(got))
                    }
                    emit(["id": id, "ok": true, "reader": name])
                case "selftest.spawn" where ProcessInfo.processInfo.environment["DIGUP_DECODE_SELFTEST"] == "1":
                    emit(["id": id, "ok": true, "spawned": SandboxProbe.spawnsAChild()])
                #endif
                case let op:
                    emit(["id": id, "ok": false, "kind": "other", "error": "unknown op \(op ?? "(none)")"])
                }
            } catch ExtractError.locked {
                emit(["id": id, "ok": false, "kind": "locked", "error": "password-protected"])
            } catch ExtractError.tooSmall(let width, let height) {
                emit(["id": id, "ok": false, "kind": "tooSmall", "width": width, "height": height, "error": "small image"])
            } catch ExtractError.unreadable(let why) {
                emit(["id": id, "ok": false, "kind": "unreadable", "error": why])
            } catch {
                emit(["id": id, "ok": false, "kind": "other", "error": "\(error)"])
            }
        }
        return 0
    }

    /// Runs `body` with PDFium reading the handle the request carries (if it carries one), not a path.
    static func withFile<T>(_ request: [String: Any], _ body: () throws -> T) throws -> T {
        #if os(Windows)
        if let value = request["handle"] as? Int {
            guard let reader = FileReader(passedHandle: HANDLE(bitPattern: value)) else {
                throw ExtractError.unreadable("can't read the file handed over")
            }
            return try $passed.withValue(reader, operation: body)
        }
        #endif
        return try body()
    }

    static func url(_ request: [String: Any]) -> URL {
        URL(fileURLWithPath: request["path"] as? String ?? "")
    }
}
#else
import Foundation

/// macOS reads PDFs with PDFKit, in process; there is no worker there.
public enum DecodeWorker {
    public static var logLine: String? { nil }

    public static func run() -> Int32 {
        FileHandle.standardError.write(Data("decode-worker: not used on this system\n".utf8))
        return 1
    }
}
#endif
