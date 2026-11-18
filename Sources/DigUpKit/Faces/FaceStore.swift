// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md §6). `faces.sqlite` beside the index, like
// `code.sqlite`: no effect on the main index's schema, and one file to delete for "Delete all face data".
import Foundation

public final class FaceStore {
    /// The index service and the search service both open this file. Each table has one owning process (§6):
    /// the index service owns `scan`, `face`, `content`, `grp` and `auto` labels; the search service owns `person`,
    /// `rejection`, `op_log` and every other label. Writes to a table the role does not own throw.
    public enum Role: String, Sendable { case index, search }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static let file = "faces.sqlite"
    public static let schemaVersion: Int64 = 1

    public let db: Database
    public let role: Role
    public let directory: URL

    public init(directory: URL, role: Role) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.role = role
        db = try Database(path: directory.appendingPathComponent(Self.file).path)
        try migrate()
    }

    func requireOwner(_ owner: Role, _ what: String) throws {
        guard role == owner else { throw Failure(message: "\(what) is written by the \(owner.rawValue) service, not the \(role.rawValue) service") }
    }

    private func migrate() throws {
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        guard version <= Self.schemaVersion else { throw Failure(message: "this faces file was made by a newer DigUp (schema \(version))") }
        guard version < Self.schemaVersion else { return }
        try db.execute("PRAGMA busy_timeout = 60000")
        defer { try? db.execute("PRAGMA busy_timeout = 5000") }
        try db.transaction {
            try db.query("PRAGMA user_version") { version = $0.int(0) }
            guard version == 0 else { return }
            try db.execute("""
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE scan (
                    path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime INTEGER NOT NULL, signature TEXT NOT NULL,
                    status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, date INTEGER NOT NULL);
                CREATE TABLE face (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL, size INTEGER NOT NULL, mtime INTEGER NOT NULL,
                    taken INTEGER, content_key TEXT,
                    x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL, landmarks TEXT,
                    confidence REAL NOT NULL, sharpness REAL NOT NULL, scale REAL NOT NULL, orientation INTEGER NOT NULL,
                    embedding BLOB NOT NULL);
                CREATE INDEX face_path ON face(path);
                CREATE TABLE content (key TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY (key, path));
                CREATE INDEX content_path ON content(path);
                CREATE TABLE grp (id INTEGER PRIMARY KEY, run INTEGER NOT NULL);
                CREATE TABLE grp_face (group_id INTEGER NOT NULL, face_id INTEGER NOT NULL, PRIMARY KEY (group_id, face_id));
                CREATE TABLE person (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '', private INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE label (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL,
                    x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL, embedding BLOB NOT NULL,
                    face_id INTEGER, person_id INTEGER, source TEXT NOT NULL, confidence REAL NOT NULL DEFAULT 1, date INTEGER NOT NULL);
                CREATE UNIQUE INDEX label_face ON label(face_id) WHERE face_id IS NOT NULL;
                CREATE INDEX label_person ON label(person_id);
                CREATE INDEX label_path ON label(path);
                CREATE TABLE rejection (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL,
                    x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL, embedding BLOB NOT NULL,
                    person_id INTEGER NOT NULL, date INTEGER NOT NULL);
                CREATE INDEX rejection_path ON rejection(path);
                CREATE TABLE op_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, operation TEXT NOT NULL, detail TEXT NOT NULL,
                    undo TEXT NOT NULL, date INTEGER NOT NULL);
                PRAGMA user_version = \(Self.schemaVersion);
                """)
            try db.run("INSERT INTO meta(key, value) VALUES ('schema', ?)", [.text("\(Self.schemaVersion)")])
        }
    }

    // MARK: meta, thresholds, model

    func meta(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(value)])
    }

    /// The thresholds in force. The defaults are written the first time so the file holds the one source of truth.
    public func thresholds() throws -> FaceThresholds {
        if let text = try meta("thresholds"), let value = try? JSONDecoder().decode(FaceThresholds.self, from: Data(text.utf8)) {
            return value
        }
        let defaults = FaceThresholds.defaults
        if role == .search { try setThresholds(defaults) }
        return defaults
    }

    /// Changing a soft threshold changes which faces are usable and rescans nothing (§17 rows 6 and 23).
    public func setThresholds(_ value: FaceThresholds) throws {
        try requireOwner(.search, "the thresholds")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try setMeta("thresholds", String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// The detector, alignment and embedder in use. A scan made with another signature is made again (row 7); a threshold change does not.
    public func modelSignature() throws -> String? { try meta("model") }
    public func setModelSignature(_ signature: String) throws {
        try requireOwner(.index, "the model signature")
        try setMeta("model", signature)
    }

    public func isUsable(_ face: FaceRecord, _ t: FaceThresholds) -> Bool {
        face.confidence >= t.usableConfidence && face.box.pixels >= t.usablePixels && face.sharpness >= t.usableSharpness
    }

    // MARK: scanning (index service)

    public enum ScanStatus: String, Sendable { case faces, empty = "none", failed }

    public func needsScan(path: String, size: Int64, mtime: Int64, signature: String) throws -> Bool {
        let limit = try thresholds().maxAttempts
        var row: (Int64, Int64, String, String, Int64)?
        try db.query("SELECT size, mtime, signature, status, attempts FROM scan WHERE path = ?", [.text(path)]) {
            row = ($0.int(0), $0.int(1), $0.text(2) ?? "", $0.text(3) ?? "", $0.int(4))
        }
        guard let row else { return true }
        if row.0 != size || row.1 != mtime || row.2 != signature { return true }
        return row.3 == ScanStatus.failed.rawValue && row.4 < Int64(limit)
    }

    /// Stores what the face worker found in one picture. Detections below the hard floor are not stored; everything above it is,
    /// with its measurements. A file with none above the floor is `none`, never "everything was filtered out". The file's old face
    /// rows go, and labels on them re-attach to a matching new face or wait in the review list (§7).
    @discardableResult
    public func recordScan(path: String, size: Int64, mtime: Int64, taken: Int64? = nil, contentKey: String? = nil,
                           signature: String, detections: [Detection], now: Date = Date()) throws -> Int {
        try requireOwner(.index, "scan results")
        let t = try thresholds()
        let kept = detections.filter { $0.confidence >= t.floorConfidence && $0.box.pixels >= t.floorPixels && !$0.embedding.isEmpty }
        try db.transaction {
            try dropFaces(of: path)
            for d in kept {
                try db.run("""
                    INSERT INTO face(path, size, mtime, taken, content_key, x, y, w, h, landmarks, confidence, sharpness, scale, orientation, embedding)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.text(path), .int(size), .int(mtime), taken.map { .int($0) } ?? .null, .optional(contentKey),
                          .double(d.box.x), .double(d.box.y), .double(d.box.w), .double(d.box.h),
                          .optional(d.landmarks.map { $0.map { String($0) }.joined(separator: ",") }),
                          .double(d.confidence), .double(d.sharpness), .double(d.scale), .int(Int64(d.orientation)),
                          .blob(blob(normalised(d.embedding)))])
            }
            try db.run("DELETE FROM content WHERE path = ?", [.text(path)])
            if let contentKey { try db.run("INSERT OR IGNORE INTO content(key, path) VALUES (?, ?)", [.text(contentKey), .text(path)]) }
            try putScan(path: path, size: size, mtime: mtime, signature: signature, status: kept.isEmpty ? .empty : .faces, attempts: 0, now: now)
            try reattachLabels(path: path, thresholds: t)
        }
        return kept.count
    }

    /// A face step that crashed or timed out. The file stays done in the main index; only this row says so.
    public func recordFailure(path: String, size: Int64, mtime: Int64, signature: String, now: Date = Date()) throws {
        try requireOwner(.index, "scan results")
        var attempts: Int64 = 0
        try db.query("SELECT attempts FROM scan WHERE path = ?", [.text(path)]) { attempts = $0.int(0) }
        try putScan(path: path, size: size, mtime: mtime, signature: signature, status: .failed, attempts: attempts + 1, now: now)
    }

    public func scanStatus(of path: String) throws -> (status: ScanStatus, attempts: Int)? {
        var result: (ScanStatus, Int)?
        try db.query("SELECT status, attempts FROM scan WHERE path = ?", [.text(path)]) {
            result = (ScanStatus(rawValue: $0.text(0) ?? "") ?? .failed, Int($0.int(1)))
        }
        return result
    }

    private func putScan(path: String, size: Int64, mtime: Int64, signature: String, status: ScanStatus, attempts: Int64, now: Date) throws {
        try db.run("""
            INSERT INTO scan(path, size, mtime, signature, status, attempts, date) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET size = excluded.size, mtime = excluded.mtime, signature = excluded.signature,
                status = excluded.status, attempts = excluded.attempts, date = excluded.date
            """, [.text(path), .int(size), .int(mtime), .text(signature), .text(status.rawValue), .int(attempts), .int(Int64(now.timeIntervalSince1970))])
    }

    /// Removes a path's face rows. Labels keep their anchor (path, box, embedding copy) and lose only the link.
    private func dropFaces(of path: String) throws {
        try db.run("UPDATE label SET face_id = NULL WHERE path = ?", [.text(path)])
        try db.run("DELETE FROM grp_face WHERE face_id IN (SELECT id FROM face WHERE path = ?)", [.text(path)])
        try db.run("DELETE FROM face WHERE path = ?", [.text(path)])
    }

    /// A label with no face row takes the new face in its picture that matches its stored embedding above the matching threshold
    /// and wins by the margin over the other faces there (siblings look alike). Otherwise it stays, unlinked, in the review list.
    /// Only the anchor columns change here, so the index service may do this to a label the search service owns.
    private func reattachLabels(path: String, thresholds t: FaceThresholds) throws {
        var orphans: [(id: Int64, embedding: [Float])] = []
        try db.query("SELECT id, embedding FROM label WHERE path = ? AND face_id IS NULL", [.text(path)]) {
            orphans.append(($0.int(0), floats($0.blob(1) ?? Data())))
        }
        guard !orphans.isEmpty else { return }
        let faces = try faceRecords(path: path)
        var taken = Set<Int64>()
        var options: [(label: Int64, face: FaceRecord, score: Double)] = []
        for orphan in orphans {
            let scores = faces.map { (face: $0, score: Double(dot(orphan.embedding, $0.embedding))) }.sorted { $0.score > $1.score }
            guard let best = scores.first, best.score >= t.matching else { continue }
            if scores.count > 1, best.score - scores[1].score < t.margin { continue }
            options.append((orphan.id, best.face, best.score))
        }
        // Strongest match first, so two labels in one picture do not fight over a face by row order.
        for option in options.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.label < $1.label }) where !taken.contains(option.face.id) {
            taken.insert(option.face.id)
            let f = option.face
            try db.run("UPDATE label SET face_id = ?, x = ?, y = ?, w = ?, h = ?, embedding = ? WHERE id = ?",
                       [.int(f.id), .double(f.box.x), .double(f.box.y), .double(f.box.w), .double(f.box.h), .blob(blob(f.embedding)), .int(option.label)])
        }
    }

    /// Labels whose face could not be found again after a change: never deleted silently, listed for review.
    public func reviewList() throws -> [FaceLabel] {
        try labels(where: "face_id IS NULL AND source != 'ignored'")
    }

    // MARK: reading

    static func record(_ s: Statement) -> FaceRecord {
        FaceRecord(id: s.int(0), path: s.text(1) ?? "", size: s.int(2), mtime: s.int(3),
                   taken: s.isNull(4) ? nil : s.int(4), contentKey: s.text(5),
                   box: FaceBox(x: s.double(6), y: s.double(7), w: s.double(8), h: s.double(9)),
                   landmarks: s.text(10).map { $0.split(separator: ",").compactMap { Double($0) } },
                   confidence: s.double(11), sharpness: s.double(12), embedding: floats(s.blob(13) ?? Data()))
    }

    static let faceColumns = "id, path, size, mtime, taken, content_key, x, y, w, h, landmarks, confidence, sharpness, embedding"

    public func faceRecords(path: String) throws -> [FaceRecord] {
        var out: [FaceRecord] = []
        try db.query("SELECT \(Self.faceColumns) FROM face WHERE path = ? ORDER BY id", [.text(path)]) { out.append(Self.record($0)) }
        return out
    }

    public func faceRecords(ids: [Int64]) throws -> [FaceRecord] {
        var out: [FaceRecord] = []
        for id in ids {
            try db.query("SELECT \(Self.faceColumns) FROM face WHERE id = ?", [.int(id)]) { out.append(Self.record($0)) }
        }
        return out
    }

    public func allFaces() throws -> [FaceRecord] {
        var out: [FaceRecord] = []
        try db.query("SELECT \(Self.faceColumns) FROM face ORDER BY id") { out.append(Self.record($0)) }
        return out
    }

    public func faceCount() throws -> Int {
        var n = 0
        try db.query("SELECT COUNT(*) FROM face") { n = Int($0.int(0)) }
        return n
    }

    func labels(where clause: String, _ values: [SQLValue] = []) throws -> [FaceLabel] {
        var out: [FaceLabel] = []
        try db.query("SELECT id, path, x, y, w, h, face_id, person_id, source, confidence FROM label WHERE \(clause) ORDER BY id", values) {
            out.append(FaceLabel(id: $0.int(0), path: $0.text(1) ?? "", box: FaceBox(x: $0.double(2), y: $0.double(3), w: $0.double(4), h: $0.double(5)),
                                 faceID: $0.isNull(6) ? nil : $0.int(6), personID: $0.isNull(7) ? nil : $0.int(7),
                                 source: LabelSource(rawValue: $0.text(8) ?? "") ?? .auto, confidence: $0.double(9)))
        }
        return out
    }

    public func label(forFace id: Int64) throws -> FaceLabel? { try labels(where: "face_id = ?", [.int(id)]).first }

    // MARK: folders and deletion

    public struct Removal: Equatable, Sendable { public var faces = 0, scans = 0, labels = 0, rejections = 0 }

    /// Removing a folder in Settings deletes its faces, scan rows, labels and rejections, with their embedding copies (privacy, §11).
    /// A person left with no faces keeps their name and an empty album. This is the one case where labels are deleted by the program,
    /// and it is the user's explicit action, so either service may do it.
    @discardableResult
    public func removeFolder(_ folder: String) throws -> Removal {
        let separator = folder.contains("\\") ? "\\" : "/"
        let prefix = folder.hasSuffix(separator) ? folder : folder + separator
        let range: [SQLValue] = [.text(prefix), .text(prefix + "\u{10FFFF}")]
        var removal = Removal()
        try db.transaction {
            func count(_ table: String) throws -> Int {
                var n = 0
                try db.query("SELECT COUNT(*) FROM \(table) WHERE path >= ? AND path < ?", range) { n = Int($0.int(0)) }
                return n
            }
            removal = Removal(faces: try count("face"), scans: try count("scan"), labels: try count("label"), rejections: try count("rejection"))
            try db.run("DELETE FROM grp_face WHERE face_id IN (SELECT id FROM face WHERE path >= ? AND path < ?)", range)
            for table in ["face", "scan", "label", "rejection", "content"] {
                try db.run("DELETE FROM \(table) WHERE path >= ? AND path < ?", range)
            }
            try db.run("DELETE FROM grp WHERE id NOT IN (SELECT group_id FROM grp_face)")
            // Undo must not bring a removed folder's labels back, so the log (which holds copies of rows) goes too.
            try db.run("DELETE FROM op_log")
        }
        return removal
    }

    /// DOWNSTREAM-FORK (2026-11-18, review): what the index does at start for folders taken out of Settings: faces, scan rows, labels and
    /// rejections of every photo that is not under one of `roots` go, with their embeddings (privacy, §11). Same path rules as `IndexStore.prune`.
    @discardableResult
    public func prune(keepingUnder roots: [String]) throws -> Removal {
        let prefixes = roots.flatMap { IndexStore.pathRanges(under: $0).map(\.from) }
        var gone: [String] = []
        for table in ["face", "scan", "label", "rejection", "content"] {
            try db.query("SELECT DISTINCT path FROM \(table)") { row in
                let path = row.text(0) ?? ""
                if !prefixes.contains(where: { path.hasPrefix($0) }) { gone.append(path) }
            }
        }
        gone = Array(Set(gone))
        var removal = Removal()
        guard !gone.isEmpty else { return removal }
        try db.transaction {
            for path in gone {
                let at: [SQLValue] = [.text(path)]
                func count(_ table: String) throws -> Int {
                    var n = 0
                    try db.query("SELECT COUNT(*) FROM \(table) WHERE path = ?", at) { n = Int($0.int(0)) }
                    return n
                }
                removal.faces += try count("face"); removal.scans += try count("scan")
                removal.labels += try count("label"); removal.rejections += try count("rejection")
                try db.run("DELETE FROM grp_face WHERE face_id IN (SELECT id FROM face WHERE path = ?)", at)
                for table in ["face", "scan", "label", "rejection", "content"] { try db.run("DELETE FROM \(table) WHERE path = ?", at) }
            }
            try db.run("DELETE FROM grp WHERE id NOT IN (SELECT group_id FROM grp_face)")
            try db.run("DELETE FROM op_log")   // as removeFolder: undo must not bring removed labels back
        }
        return removal
    }

    /// "Delete all face data": the faces file goes (the cached crops are the caller's, in the previews folder). Not undoable.
    public static func deleteAllData(in directory: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent(file + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
