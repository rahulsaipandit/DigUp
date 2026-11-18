// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md §7, §17 rows 1, 2, 15, 16, 17). People, labels and the
// correction operations: name a group, rename, merge, split, move a face, "not this person", dissolve, ignore, restore, and undo.
// All of them are the search service's (the UI talks to it). Each one is undoable: it records the rows it changed in `op_log`.
import Foundation

/// A row as it was, enough to put it back. Embeddings are base64 through `Data`'s Codable.
private struct LabelRow: Codable {
    var id: Int64, path: String, x: Double, y: Double, w: Double, h: Double, embedding: Data
    var faceID: Int64?, personID: Int64?, source: String, confidence: Double, date: Int64
}
private struct PersonRow: Codable { var id: Int64, name: String, aliases: String, isPrivate: Int64 }
private struct RejectionRow: Codable {
    var id: Int64, path: String, x: Double, y: Double, w: Double, h: Double, embedding: Data, personID: Int64, date: Int64
}

private enum UndoStep: Codable {
    case restoreLabel(LabelRow), restorePerson(PersonRow), restoreRejection(RejectionRow)
    case dropLabel(Int64), dropPerson(Int64), dropRejection(Int64)
}

/// What an operation changed, first state per row wins, so replaying it backwards restores everything.
private final class Journal {
    var steps: [UndoStep] = []
    var seen = Set<String>()
    func note(_ key: String, _ step: UndoStep) { if seen.insert(key).inserted { steps.append(step) } }
}

extension FaceStore {
    public static let undoKeepDays = 30

    // MARK: people

    public func people() throws -> [Person] {
        var out: [Person] = []
        try db.query("SELECT id, name, aliases, private FROM person ORDER BY id") {
            out.append(Person(id: $0.int(0), name: $0.text(1) ?? "", aliases: Self.splitAliases($0.text(2) ?? ""), isPrivate: $0.int(3) != 0))
        }
        return out
    }

    /// Names with the number of photos each has (one per content key), for the panel and the CLI.
    public func summaries() throws -> [PersonSummary] {
        try people().map { PersonSummary(id: $0.id, name: $0.name, aliases: $0.aliases, photos: try album(of: $0.id).count) }
    }

    static func splitAliases(_ text: String) -> [String] { text.split(separator: "\n").map(String.init) }

    /// One entry per photo (content key), newest first by date taken, then path. Copies are listed under the entry, not as other photos.
    /// Ignored faces are never listed. `auto` suggestions are included unless `includeSuggested` is false.
    public func album(of person: Int64, includeSuggested: Bool = true) throws -> [AlbumEntry] {
        let own = """
            FROM label l JOIN face f ON f.id = l.face_id
            WHERE l.person_id = ? AND l.source IN ('user', 'group'\(includeSuggested ? ", 'auto'" : ""))
            """
        var byKey: [String: (taken: Int64, paths: Set<String>)] = [:]
        try db.query("SELECT f.path, COALESCE(f.content_key, f.path), COALESCE(f.taken, f.mtime) \(own)", [.int(person)]) {
            let key = $0.text(1) ?? ""
            var entry = byKey[key] ?? ($0.int(2), [])
            entry.paths.insert($0.text(0) ?? "")
            byKey[key] = entry
        }
        // Copies of one photo that are in the content table but have no face row of their own are copies as well. One query for all the
        // photos: a query each made every search that names a person cost as many queries as that person has photos.
        try db.query("SELECT key, path FROM content WHERE key IN (SELECT COALESCE(f.content_key, f.path) \(own))", [.int(person)]) {
            byKey[$0.text(0) ?? ""]?.paths.insert($0.text(1) ?? "")
        }
        return byKey.values.map { entry in
            let paths = entry.paths.sorted()
            return AlbumEntry(path: paths[0], copies: Array(paths.dropFirst()), taken: entry.taken)
        }.sorted { $0.taken != $1.taken ? $0.taken > $1.taken : $0.path < $1.path }
    }

    // MARK: operations

    /// Runs `body`, which changes rows only through the journal's own helpers, and files the result in `op_log`.
    private func operation<T>(_ name: String, _ detail: String, _ body: (Journal) throws -> T) throws -> T {
        try requireOwner(.search, "people and corrections")
        return try db.transaction {
            let journal = Journal()
            let result = try body(journal)
            let steps = String(decoding: try JSONEncoder().encode(Array(journal.steps.reversed())), as: UTF8.self)
            let now = Int64(Date().timeIntervalSince1970)
            try db.run("INSERT INTO op_log(operation, detail, undo, date) VALUES (?, ?, ?, ?)", [.text(name), .text(detail), .text(steps), .int(now)])
            try db.run("DELETE FROM op_log WHERE date < ?", [.int(now - Int64(Self.undoKeepDays) * 86400)])
            return result
        }
    }

    private func labelRow(_ id: Int64) throws -> LabelRow? {
        var row: LabelRow?
        try db.query("SELECT id, path, x, y, w, h, embedding, face_id, person_id, source, confidence, date FROM label WHERE id = ?", [.int(id)]) {
            row = LabelRow(id: $0.int(0), path: $0.text(1) ?? "", x: $0.double(2), y: $0.double(3), w: $0.double(4), h: $0.double(5),
                           embedding: $0.blob(6) ?? Data(), faceID: $0.isNull(7) ? nil : $0.int(7), personID: $0.isNull(8) ? nil : $0.int(8),
                           source: $0.text(9) ?? "", confidence: $0.double(10), date: $0.int(11))
        }
        return row
    }

    private func personRow(_ id: Int64) throws -> PersonRow? {
        var row: PersonRow?
        try db.query("SELECT id, name, aliases, private FROM person WHERE id = ?", [.int(id)]) {
            row = PersonRow(id: $0.int(0), name: $0.text(1) ?? "", aliases: $0.text(2) ?? "", isPrivate: $0.int(3))
        }
        return row
    }

    private func rejectionRow(_ id: Int64) throws -> RejectionRow? {
        var row: RejectionRow?
        try db.query("SELECT id, path, x, y, w, h, embedding, person_id, date FROM rejection WHERE id = ?", [.int(id)]) {
            row = RejectionRow(id: $0.int(0), path: $0.text(1) ?? "", x: $0.double(2), y: $0.double(3), w: $0.double(4), h: $0.double(5),
                               embedding: $0.blob(6) ?? Data(), personID: $0.int(7), date: $0.int(8))
        }
        return row
    }

    private func newPerson(_ name: String, _ j: Journal) throws -> Int64 {
        try db.run("INSERT INTO person(name) VALUES (?)", [.text(name)])
        let id = db.lastInsertID
        j.note("person\(id)", .dropPerson(id))
        return id
    }

    private func changePerson(_ id: Int64, _ j: Journal, _ sql: String, _ values: [SQLValue]) throws {
        if let old = try personRow(id) { j.note("person\(id)", .restorePerson(old)) }
        try db.run(sql, values + [.int(id)])
    }

    private func deleteLabel(_ id: Int64, _ j: Journal) throws {
        if let old = try labelRow(id) { j.note("label\(id)", .restoreLabel(old)) }
        try db.run("DELETE FROM label WHERE id = ?", [.int(id)])
    }

    private func changeLabel(_ id: Int64, _ j: Journal, _ sql: String, _ values: [SQLValue]) throws {
        if let old = try labelRow(id) { j.note("label\(id)", .restoreLabel(old)) }
        try db.run(sql, values + [.int(id)])
    }

    private func deleteRejection(_ id: Int64, _ j: Journal) throws {
        if let old = try rejectionRow(id) { j.note("rejection\(id)", .restoreRejection(old)) }
        try db.run("DELETE FROM rejection WHERE id = ?", [.int(id)])
    }

    /// Sets a face's label: replaces what it had (journalled), and writes the face's anchor with its embedding copy.
    private func setLabel(face: FaceRecord, person: Int64?, source: LabelSource, _ j: Journal) throws {
        if let existing = try label(forFace: face.id) { try deleteLabel(existing.id, j) }
        // A label with this anchor but no face row (waiting in the review list) is replaced too.
        for stale in try labels(where: "path = ? AND x = ? AND y = ? AND w = ? AND h = ? AND face_id IS NULL",
                                [.text(face.path), .double(face.box.x), .double(face.box.y), .double(face.box.w), .double(face.box.h)]) {
            try deleteLabel(stale.id, j)
        }
        try db.run("""
            INSERT INTO label(path, x, y, w, h, embedding, face_id, person_id, source, confidence, date) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
            """, [.text(face.path), .double(face.box.x), .double(face.box.y), .double(face.box.w), .double(face.box.h), .blob(blob(face.embedding)),
                  .int(face.id), person.map { .int($0) } ?? .null, .text(source.rawValue), .int(Int64(Date().timeIntervalSince1970))])
        j.note("label\(db.lastInsertID)", .dropLabel(db.lastInsertID))
    }

    private func face(_ id: Int64) throws -> FaceRecord {
        guard let face = try faceRecords(ids: [id]).first else { throw Failure(message: "there is no face \(id)") }
        return face
    }

    private func requirePerson(_ id: Int64) throws {
        guard try personRow(id) != nil else { throw Failure(message: "there is no person \(id)") }
    }

    /// Names a group: a new person, and the group's faces become `group` labels, which are not checked one by one and may be wrong (they are
    /// flagged for review when they disagree with the core, never moved silently). A face that already carries a `user` label, or is
    /// ignored, keeps it. The group's own rows are a cache and are left to the next clustering run.
    @discardableResult
    public func name(group id: Int64, as name: String) throws -> Int64 {
        guard let group = try groups().first(where: { $0.id == id }) else { throw Failure(message: "there is no group \(id)") }
        return try operation("name", "group \(id) as \(name)") { j in
            let person = try newPerson(name, j)
            for face in try faceRecords(ids: group.faceIDs) {
                if let existing = try label(forFace: face.id), existing.source == .user || existing.source == .ignored { continue }
                try setLabel(face: face, person: person, source: .group, j)
            }
            return person
        }
    }

    /// DOWNSTREAM-FORK (2026-11-18): a group turns out to be someone already named. One operation, so one undo; the faces become `group` labels as in
    /// `name(group:as:)`, and a face with a `user` label or ignored keeps it.
    public func add(group id: Int64, to person: Int64) throws {
        try requirePerson(person)
        guard let group = try groups().first(where: { $0.id == id }) else { throw Failure(message: "there is no group \(id)") }
        try operation("name", "group \(id) as person \(person)") { j in
            for face in try faceRecords(ids: group.faceIDs) {
                if let existing = try label(forFace: face.id), existing.source == .user || existing.source == .ignored { continue }
                try setLabel(face: face, person: person, source: .group, j)
            }
        }
    }

    /// Names a person from faces the user picked. They are `user` labels, the strongest kind.
    @discardableResult
    public func enrol(faces ids: [Int64], as name: String) throws -> Int64 {
        let faces = try ids.map { try face($0) }
        return try operation("enrol", "\(ids.count) faces as \(name)") { j in
            let person = try newPerson(name, j)
            for face in faces { try setLabel(face: face, person: person, source: .user, j) }
            return person
        }
    }

    public func rename(person: Int64, to name: String) throws {
        try requirePerson(person)
        try operation("rename", "person \(person) to \(name)") { j in try changePerson(person, j, "UPDATE person SET name = ? WHERE id = ?", [.text(name)]) }
    }

    public func setAliases(person: Int64, _ aliases: [String]) throws {
        try requirePerson(person)
        try operation("aliases", "person \(person)") { j in
            try changePerson(person, j, "UPDATE person SET aliases = ? WHERE id = ?", [.text(aliases.joined(separator: "\n"))])
        }
    }

    /// The user confirms a face for a person (a suggestion, or a face from a group): a `user` label. A "not this person" on the pair is lifted.
    public func confirm(face id: Int64, person: Int64) throws { try move(face: id, to: person) }

    /// Moves a face to another person as a `user` label (the one-action fix for a wrong face in a named group).
    public func move(face id: Int64, to person: Int64) throws {
        try requirePerson(person)
        let face = try face(id)
        try operation("move", "face \(id) to person \(person)") { j in
            try setLabel(face: face, person: person, source: .user, j)
            for r in try rejections(of: face, person: person) { try deleteRejection(r, j) }
        }
    }

    private func rejections(of face: FaceRecord, person: Int64) throws -> [Int64] {
        var ids: [Int64] = []
        try db.query("SELECT id FROM rejection WHERE path = ? AND x = ? AND y = ? AND w = ? AND h = ? AND person_id = ?",
                     [.text(face.path), .double(face.box.x), .double(face.box.y), .double(face.box.w), .double(face.box.h), .int(person)]) { ids.append($0.int(0)) }
        return ids
    }

    /// "Not this person": a rejection that re-clustering and re-matching respect. If the face was labelled with that person it returns to the pool.
    public func reject(face id: Int64, notPerson person: Int64) throws {
        try requirePerson(person)
        let face = try face(id)
        try operation("reject", "face \(id) is not person \(person)") { j in
            if let existing = try label(forFace: id), existing.personID == person { try deleteLabel(existing.id, j) }
            guard try rejections(of: face, person: person).isEmpty else { return }
            try db.run("INSERT INTO rejection(path, x, y, w, h, embedding, person_id, date) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                       [.text(face.path), .double(face.box.x), .double(face.box.y), .double(face.box.w), .double(face.box.h), .blob(blob(face.embedding)),
                        .int(person), .int(Int64(Date().timeIntervalSince1970))])
            j.note("rejection\(db.lastInsertID)", .dropRejection(db.lastInsertID))
        }
    }

    /// Two people are one: the first's labels and rejections go to the second, its name stays as an alias, and the first is removed.
    public func merge(person from: Int64, into target: Int64) throws {
        guard from != target else { return }
        try requirePerson(from); try requirePerson(target)
        try operation("merge", "person \(from) into \(target)") { j in
            for label in try labels(where: "person_id = ?", [.int(from)]) {
                try changeLabel(label.id, j, "UPDATE label SET person_id = \(target) WHERE id = ?", [])
            }
            var moved: [Int64] = []
            try db.query("SELECT id FROM rejection WHERE person_id = ?", [.int(from)]) { moved.append($0.int(0)) }
            for id in moved {
                if let old = try rejectionRow(id) { j.note("rejection\(id)", .restoreRejection(old)) }
                try db.run("UPDATE rejection SET person_id = ? WHERE id = ?", [.int(target), .int(id)])
            }
            // A rejection that now contradicts a label on its own face is dropped.
            for r in try rejectionIDsContradictingLabels(person: target) { try deleteRejection(r, j) }
            let a = try personRow(from)!, b = try personRow(target)!
            var aliases = Self.splitAliases(b.aliases)
            for name in [a.name] + Self.splitAliases(a.aliases) where name != b.name && !aliases.contains(name) { aliases.append(name) }
            try changePerson(target, j, "UPDATE person SET aliases = ? WHERE id = ?", [.text(aliases.joined(separator: "\n"))])
            j.note("person\(from)", .restorePerson(a))
            try db.run("DELETE FROM person WHERE id = ?", [.int(from)])
        }
    }

    private func rejectionIDsContradictingLabels(person: Int64) throws -> [Int64] {
        var ids: [Int64] = []
        try db.query("""
            SELECT r.id FROM rejection r JOIN label l ON l.path = r.path AND l.x = r.x AND l.y = r.y AND l.w = r.w AND l.h = r.h
            WHERE r.person_id = ? AND l.person_id = r.person_id
            """, [.int(person)]) { ids.append($0.int(0)) }
        return ids
    }

    /// Splits faces off a person into a new person (a `user` label each).
    @discardableResult
    public func split(person: Int64, faces ids: [Int64], as name: String) throws -> Int64 {
        try requirePerson(person)
        let faces = try ids.map { try face($0) }
        return try operation("split", "\(ids.count) faces of person \(person) as \(name)") { j in
            let new = try newPerson(name, j)
            for face in faces { try setLabel(face: face, person: new, source: .user, j) }
            return new
        }
    }

    /// The name is removed: the person goes, and their faces return to the pool and may form a new unnamed group. Not the same as ignore.
    public func dissolve(person: Int64) throws {
        try requirePerson(person)
        try operation("dissolve", "person \(person)") { j in
            for label in try labels(where: "person_id = ?", [.int(person)]) { try deleteLabel(label.id, j) }
            var rejected: [Int64] = []
            try db.query("SELECT id FROM rejection WHERE person_id = ?", [.int(person)]) { rejected.append($0.int(0)) }
            for id in rejected { try deleteRejection(id, j) }
            if let old = try personRow(person) { j.note("person\(person)", .restorePerson(old)) }
            try db.run("DELETE FROM person WHERE id = ?", [.int(person)])
        }
    }

    /// Faces nobody wants named (strangers, people in the background): never clustered, matched, offered or searchable until restored.
    public func ignore(faces ids: [Int64]) throws {
        let faces = try ids.map { try face($0) }
        try operation("ignore", "\(ids.count) faces") { j in
            for face in faces { try setLabel(face: face, person: nil, source: .ignored, j) }
        }
    }

    public func ignore(group id: Int64) throws {
        guard let group = try groups().first(where: { $0.id == id }) else { throw Failure(message: "there is no group \(id)") }
        try ignore(faces: group.faceIDs)
    }

    public func restore(faces ids: [Int64]) throws {
        try operation("restore", "\(ids.count) faces") { j in
            for id in ids {
                if let label = try label(forFace: id), label.source == .ignored { try deleteLabel(label.id, j) }
            }
        }
    }

    // MARK: undo

    /// Reverses the newest operation, and returns its name, or nil when there is nothing to undo. Kept for `undoKeepDays` days.
    @discardableResult
    public func undo() throws -> String? {
        try requireOwner(.search, "undo")
        return try db.transaction {
            var entry: (id: Int64, name: String, steps: String)?
            try db.query("SELECT id, operation, undo FROM op_log ORDER BY id DESC LIMIT 1") { entry = ($0.int(0), $0.text(1) ?? "", $0.text(2) ?? "[]") }
            guard let entry else { return nil }
            let steps = try JSONDecoder().decode([UndoStep].self, from: Data(entry.steps.utf8))
            for step in steps {
                switch step {
                case .dropLabel(let id): try db.run("DELETE FROM label WHERE id = ?", [.int(id)])
                case .dropPerson(let id): try db.run("DELETE FROM person WHERE id = ?", [.int(id)])
                case .dropRejection(let id): try db.run("DELETE FROM rejection WHERE id = ?", [.int(id)])
                case .restorePerson(let p):
                    try db.run("INSERT OR REPLACE INTO person(id, name, aliases, private) VALUES (?, ?, ?, ?)", [.int(p.id), .text(p.name), .text(p.aliases), .int(p.isPrivate)])
                case .restoreLabel(let l):
                    try db.run("DELETE FROM label WHERE id = ? OR (face_id IS NOT NULL AND face_id = ?)", [.int(l.id), l.faceID.map { .int($0) } ?? .null])
                    try db.run("""
                        INSERT INTO label(id, path, x, y, w, h, embedding, face_id, person_id, source, confidence, date) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [.int(l.id), .text(l.path), .double(l.x), .double(l.y), .double(l.w), .double(l.h), .blob(l.embedding),
                              l.faceID.map { .int($0) } ?? .null, l.personID.map { .int($0) } ?? .null, .text(l.source), .double(l.confidence), .int(l.date)])
                case .restoreRejection(let r):
                    try db.run("INSERT OR REPLACE INTO rejection(id, path, x, y, w, h, embedding, person_id, date) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                               [.int(r.id), .text(r.path), .double(r.x), .double(r.y), .double(r.w), .double(r.h), .blob(r.embedding), .int(r.personID), .int(r.date)])
                }
            }
            try db.run("DELETE FROM op_log WHERE id = ?", [.int(entry.id)])
            return entry.name
        }
    }
}
