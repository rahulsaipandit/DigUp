// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md 5.2). The face step: finds the faces in pictures and stores them in
// `faces.sqlite`. It runs on the prepared picture of a file the main index has just finished (no second decode), and as a backfill that
// prepares the pictures of files indexed before faces were turned on. A failure here is recorded on the scan row and never touches the file.
import Foundation

public final class FaceStep {
    public let directory: URL
    private let executable: URL
    private let models: URL
    private let logFile: URL?
    private var store: FaceStore?
    private var worker: FaceWorker?
    /// Why the last attempt failed, in words for the status line; nil after a success.
    public private(set) var lastError: String?
    public private(set) var scanned = 0, failed = 0
    /// `scanned` when the faces were last grouped (-1: not yet in this process, so the first look groups once).
    private var groupedAt = -1
    /// Pictures were scanned since the faces were last grouped.
    public var needsRegroup: Bool { scanned != groupedAt }

    /// `directory`: the index folder (where `faces.sqlite` lives). Nothing is opened or started until the first picture.
    public init(directory: URL, executable: URL, models: URL, log: URL? = nil) {
        self.directory = directory
        self.executable = executable
        self.models = models
        logFile = log
    }

    /// Where the face program and its models are, or nil with the reason: `$DIGUP_FACES_EXE` or `digup-faces` beside this program, and
    /// `$DIGUP_MODELS/faces` (the models folder's `faces` subfolder).
    public static func locate(directory: URL, models modelsFolder: URL, helper: URL) -> (FaceStep?, String?) {
        let env = ProcessInfo.processInfo.environment
        let exeName = FileManager.default.fileExists(atPath: helper.deletingLastPathComponent().appendingPathComponent("digup-faces.exe").path)
            ? "digup-faces.exe" : "digup-faces"
        let executable = env["DIGUP_FACES_EXE"].map { URL(fileURLWithPath: $0) } ?? helper.deletingLastPathComponent().appendingPathComponent(exeName)
        // The models folder's faces\ subfolder, else faces\ beside the program (an installer that carries the models puts them there).
        var models = modelsFolder.appendingPathComponent("faces")
        let beside = helper.deletingLastPathComponent().appendingPathComponent("faces")
        if !FileManager.default.fileExists(atPath: models.appendingPathComponent("sface.onnx").path),
           FileManager.default.fileExists(atPath: beside.appendingPathComponent("sface.onnx").path) { models = beside }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return (nil, "the face program is missing (\(executable.path))") }
        guard FileManager.default.fileExists(atPath: models.appendingPathComponent("sface.onnx").path) else {
            return (nil, "the face models are missing (\(models.path))")
        }
        return (FaceStep(directory: directory, executable: executable, models: models,
                         log: directory.appendingPathComponent("face-worker.log")), nil)
    }

    private func openStore() throws -> FaceStore {
        if store == nil { store = try FaceStore(directory: directory, role: .index) }
        return store!
    }

    private func open() throws -> (FaceStore, FaceWorker) {
        _ = try openStore()
        if worker == nil || worker?.isRunning == false {
            worker = try FaceWorker(executable: executable, models: models, log: logFile)
        }
        return (store!, worker!)
    }

    /// Matches faces to the people already named and groups the rest, for the People window to offer (one transaction, cancellable). Never
    /// throws: a failure is in `lastError`. Returns the number of groups, or nil when it failed or was stopped.
    @discardableResult
    public func regroup(shouldStop: () -> Bool = { false }) -> Int? {
        do {
            if store == nil { store = try FaceStore(directory: directory, role: .index) }
            let count = try store!.recluster(shouldStop: shouldStop).count
            groupedAt = scanned
            return count
        } catch {
            lastError = "grouping faces: \(error)"
            return nil
        }
    }

    /// Forgets the faces of photos that are no longer under the folders being indexed (a folder taken out in Settings). Never throws.
    public func prune(keepingUnder roots: [String]) {
        do { try openStore().prune(keepingUnder: roots) } catch { lastError = "removing the faces of removed folders: \(error)" }
    }

    /// Frees the face program's memory until the next picture.
    public func close() {
        worker?.close()
        worker = nil
    }

    public struct Item: Sendable {
        public var path: String
        public var size: Int64
        public var mtime: Double
        /// EXIF DateTimeOriginal as the camera wrote it ("2025:01:01 07:28:17"), if known.
        public var taken: String?
        /// The prepared picture to read: at most 1024 px, written by the sandboxed decode, removed by the caller afterwards.
        public var picture: String
        public init(path: String, size: Int64, mtime: Double, taken: String?, picture: String) {
            (self.path, self.size, self.mtime, self.taken, self.picture) = (path, size, mtime, taken, picture)
        }
    }

    /// Finds and stores the faces of these pictures. Pictures already scanned with this model are left alone. Never throws: a failure is
    /// recorded on each file's scan row (retried a few times, then reported) and put in `lastError`. False when the face program could not be
    /// started (nothing was recorded, so a caller that goes through many pictures can stop instead of preparing them for nothing).
    @discardableResult
    public func scan(_ items: [Item]) -> Bool {
        let (store, worker): (FaceStore, FaceWorker)
        do { (store, worker) = try open() } catch {
            lastError = "\(error)"
            return false   // nothing to record against: the next picture tries again
        }
        let waiting = items.filter { (try? store.needsScan(path: $0.path, size: $0.size, mtime: Int64($0.mtime), signature: FaceWorker.signature)) ?? true }
        guard !waiting.isEmpty else { return true }
        var recorded = 0   // pictures of `waiting`, from the front, whose row is written: a later failure must not mark them failed
        do {
            let results = try worker.faces(in: waiting.map(\.picture))
            for (item, result) in zip(waiting, results) {
                if let error = result.error {
                    try? store.recordFailure(path: item.path, size: item.size, mtime: Int64(item.mtime), signature: FaceWorker.signature)
                    failed += 1
                    lastError = error
                    recorded += 1
                    continue
                }
                let taken = item.taken.flatMap(Self.epoch)
                try store.recordScan(path: item.path, size: item.size, mtime: Int64(item.mtime), taken: taken,
                                     contentKey: ContentKey.make(path: item.path, size: item.size, taken: taken),
                                     signature: FaceWorker.signature, detections: result.detections)
                scanned += 1
                recorded += 1
            }
            lastError = nil
        } catch {
            // The program died or hung (or the faces file could not be written): the pictures of this batch not yet recorded are marked failed,
            // and a new program starts next time.
            lastError = "\(error)"
            let rest = waiting.dropFirst(recorded)
            for item in rest {
                try? store.recordFailure(path: item.path, size: item.size, mtime: Int64(item.mtime), signature: FaceWorker.signature)
            }
            failed += rest.count
            worker.close()
            self.worker = nil
        }
        return true
    }

    /// The backfill: images the main index holds that have no up-to-date face scan, newest first, prepared again (sandboxed decode, 1024 px)
    /// and scanned 8 at a time. Resumable, since each file's scan row is its own record: stopping loses nothing and the next run goes on.
    /// `shouldStop` is asked between batches. Returns how many pictures it went through.
    @discardableResult
    public func backfill(_ files: [FileRecord], minSide: Int, shouldStop: () -> Bool = { false },
                         progress: (Int, Int) -> Void = { _, _ in }) -> Int {
        guard let store = try? openStore() else { return 0 }   // the program starts with the first picture, not before
        let waiting = files.filter { $0.kind == .image && $0.state == "done" }
            .sorted { $0.mtime > $1.mtime }
            .filter { (try? store.needsScan(path: $0.path, size: $0.size, mtime: Int64($0.mtime), signature: FaceWorker.signature)) ?? true }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigUp-faces-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var done = 0
        var index = 0
        while index < waiting.count, !shouldStop() {
            let batch = waiting[index..<min(index + 8, waiting.count)]
            index += batch.count
            var items: [Item] = []
            for file in batch {
                let folder = scratch.appendingPathComponent("\(file.id)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                do {
                    let picture = try ImageExtractor.prepare(URL(fileURLWithPath: file.path), maxPixel: 1024, minSide: minSide, to: folder, png: false)
                    items.append(Item(path: file.path, size: file.size, mtime: file.mtime, taken: picture.taken, picture: picture.path))
                } catch let error as ExtractError {
                    if case .tooSmall = error {
                        // Too small for the model to have embedded either: nothing to find, and not tried again.
                        try? store.recordScan(path: file.path, size: file.size, mtime: Int64(file.mtime), signature: FaceWorker.signature, detections: [])
                    } else {
                        // Unreadable now (a locked file, a failed decode): retried a few times like any other failure, not given up on for good.
                        try? store.recordFailure(path: file.path, size: file.size, mtime: Int64(file.mtime), signature: FaceWorker.signature)
                    }
                } catch {
                    try? store.recordFailure(path: file.path, size: file.size, mtime: Int64(file.mtime), signature: FaceWorker.signature)
                }
            }
            let started = items.isEmpty || scan(items)   // nothing to read: the program is not started for it
            for file in batch { try? FileManager.default.removeItem(at: scratch.appendingPathComponent("\(file.id)")) }
            done += batch.count
            progress(done, waiting.count)
            if !started { break }   // the face program does not start: the rest would be decoded for nothing, and the next pass tries again
        }
        return done
    }

    /// "2025:01:01 07:28:17" as seconds since 1970. The camera's clock has no zone, so it is read as UTC: only the order and the day matter.
    static func epoch(_ text: String) -> Int64? {
        let parts = text.split(whereSeparator: { ": -T".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var parts6 = DateComponents()
        (parts6.year, parts6.month, parts6.day) = (parts[0], parts[1], parts[2])
        (parts6.hour, parts6.minute, parts6.second) = (parts.count > 3 ? parts[3] : 0, parts.count > 4 ? parts[4] : 0, parts.count > 5 ? parts[5] : 0)
        return calendar.date(from: parts6).map { Int64($0.timeIntervalSince1970) }
    }
}
