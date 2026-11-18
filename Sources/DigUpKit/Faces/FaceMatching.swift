// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md §7). A person's core, matching a face to a person
// by threshold and runner-up margin, the pool that clustering sees, and groups written atomically with ids carried across rebuilds.
import Foundation

/// A confirmed (`user` or `group`) face that may belong to a person's core.
public struct CoreCandidate: Sendable {
    public var embedding: [Float]
    public var yaw: Double?
    public var date: Int64?
    public init(embedding: [Float], yaw: Double? = nil, date: Int64? = nil) { (self.embedding, self.yaw, self.date) = (embedding, yaw, date) }
}

public enum PersonCore {
    /// The indices of the candidates that form the core. A face qualifies when it matches at least `coreSupport` OTHER labelled faces above
    /// the matching threshold: a stray wrong face matches nobody and drops out, while a profile that matches the three-quarter views
    /// stays (an average or a single "central" face would throw profiles away). Among qualifiers the pick is for variety: greedy
    /// farthest-first over embedding distance plus head turn and date taken, so a child's core is not only the age with most photos.
    /// The weights are starting values for spike F3.
    public static func select(_ candidates: [CoreCandidate], _ t: FaceThresholds) -> [Int] {
        let n = candidates.count
        var support = [Int](repeating: 0, count: n)
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) where Double(dot(candidates[i].embedding, candidates[j].embedding)) >= t.matching {
                support[i] += 1; support[j] += 1
            }
        }
        let qualified = (0..<n).filter { support[$0] >= t.coreSupport }
        guard qualified.count > t.coreSize else { return qualified }
        func distance(_ a: Int, _ b: Int) -> Double {
            var d = 1 - Double(dot(candidates[a].embedding, candidates[b].embedding))
            if let ya = candidates[a].yaw, let yb = candidates[b].yaw { d += 0.5 * abs(ya - yb) }
            if let da = candidates[a].date, let db = candidates[b].date { d += 0.05 * abs(Double(da - db)) / (365.25 * 86400) }
            return d
        }
        var chosen = [qualified.max { (support[$0], $1) < (support[$1], $0) }!]
        var rest = qualified.filter { $0 != chosen[0] }
        while chosen.count < t.coreSize, !rest.isEmpty {
            let next = rest.indices.max { a, b in
                let da = chosen.map { distance(rest[a], $0) }.min()!, db = chosen.map { distance(rest[b], $0) }.min()!
                return da != db ? da < db : rest[a] > rest[b]
            }!
            chosen.append(rest.remove(at: next))
        }
        return chosen.sorted()
    }

    /// The person a face matches, or nil. Compared with each person's core (their best match counts), accepted only above the
    /// matching threshold AND with a margin over the runner-up person. Persons in `excluded` (rejections) are skipped.
    public static func match(_ embedding: [Float], cores: [Int64: [[Float]]], excluded: Set<Int64> = [], _ t: FaceThresholds) -> (person: Int64, score: Double)? {
        var scores: [(person: Int64, score: Double)] = []
        for (person, core) in cores where !excluded.contains(person) {
            guard let best = core.map({ Double(dot(embedding, $0)) }).max() else { continue }
            scores.append((person, best))
        }
        scores.sort { $0.score != $1.score ? $0.score > $1.score : $0.person < $1.person }
        guard let top = scores.first, top.score >= t.matching else { return nil }
        if scores.count > 1, top.score - scores[1].score < t.margin { return nil }
        return top
    }
}

extension FaceStore {
    /// Each person's core vectors, from `user` and `group` labels only: `auto` faces never join the core, or a match would widen the
    /// target and the person would slowly absorb a lookalike.
    public func cores() throws -> [Int64: [[Float]]] {
        let t = try thresholds()
        var byPerson: [Int64: [CoreCandidate]] = [:]
        try db.query("""
            SELECT l.person_id, l.embedding, f.landmarks, COALESCE(f.taken, f.mtime) FROM label l LEFT JOIN face f ON f.id = l.face_id
            WHERE l.source IN ('user', 'group') AND l.person_id IS NOT NULL
            """) { s in
            var record = FaceRecord(id: 0, path: "", size: 0, mtime: 0, box: FaceBox(x: 0, y: 0, w: 0, h: 0), confidence: 0, sharpness: 0, embedding: [])
            record.landmarks = s.text(2).map { $0.split(separator: ",").compactMap { Double($0) } }
            byPerson[s.int(0), default: []].append(CoreCandidate(embedding: floats(s.blob(1) ?? Data()), yaw: record.yaw, date: s.isNull(3) ? nil : s.int(3)))
        }
        return byPerson.mapValues { items in PersonCore.select(items, t).map { items[$0].embedding } }
    }

    /// Persons a face may not be (the user said "not this person"), by the face's anchor.
    func rejectedPersons(path: String, box: FaceBox) throws -> Set<Int64> {
        var out = Set<Int64>()
        try db.query("SELECT person_id FROM rejection WHERE path = ? AND x = ? AND y = ? AND w = ? AND h = ?",
                     [.text(path), .double(box.x), .double(box.y), .double(box.w), .double(box.h)]) { out.insert($0.int(0)) }
        return out
    }

    func ignoredFaceIDs() throws -> Set<Int64> {
        var out = Set<Int64>()
        try db.query("SELECT face_id FROM label WHERE source = 'ignored' AND face_id IS NOT NULL") { out.insert($0.int(0)) }
        return out
    }

    public struct MatchResult: Equatable, Sendable { public var labelled = 0, kept = 0, returned = 0 }

    /// Index service. Unlabelled usable faces are tried against every person's core, and `auto` labels are re-checked: kept while they
    /// still match by the margin rule, else returned to the pool. `user`, `group` and `ignored` faces are not touched. Faces below the
    /// usable thresholds are never auto-labelled.
    @discardableResult
    public func matchFaces(now: Date = Date()) throws -> MatchResult {
        try requireOwner(.index, "automatic labels")
        let t = try thresholds()
        let cores = try cores()
        var result = MatchResult()
        try db.transaction {
            // Read inside the write transaction: the search service may name a face while this runs, and an `auto` label inserted for a face that
            // has just been labelled breaks the one-label-per-face index and rolls the whole run back.
            let faces = try allFaces()
            let fixed = try Set(labels(where: "source != 'auto'").compactMap(\.faceID))
            var autos: [Int64: FaceLabel] = [:]
            for label in try labels(where: "source = 'auto'") { if let id = label.faceID { autos[id] = label } }
            for face in faces where !fixed.contains(face.id) {
                var hit: (person: Int64, score: Double)?
                if isUsable(face, t), !cores.isEmpty {
                    hit = PersonCore.match(face.embedding, cores: cores, excluded: try rejectedPersons(path: face.path, box: face.box), t)
                }
                let existing = autos[face.id]
                switch (hit, existing) {
                case let (hit?, existing?) where existing.personID == hit.person:
                    result.kept += 1
                case let (hit?, existing):
                    if let existing { try db.run("DELETE FROM label WHERE id = ?", [.int(existing.id)]) }
                    try db.run("""
                        INSERT INTO label(path, x, y, w, h, embedding, face_id, person_id, source, confidence, date) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'auto', ?, ?)
                        """, [.text(face.path), .double(face.box.x), .double(face.box.y), .double(face.box.w), .double(face.box.h), .blob(blob(face.embedding)),
                              .int(face.id), .int(hit.person), .double(hit.score), .int(Int64(now.timeIntervalSince1970))])
                    result.labelled += 1
                case (nil, let existing?):
                    try db.run("DELETE FROM label WHERE id = ?", [.int(existing.id)])
                    result.returned += 1
                case (nil, nil):
                    break
                }
            }
        }
        return result
    }

    /// `group` labels that disagree with their person's core. They are flagged for review and never moved silently.
    public func flaggedForReview(person: Int64) throws -> [Int64] {
        let t = try thresholds()
        let core = try cores()[person] ?? []
        guard !core.isEmpty else { return [] }
        var flagged: [Int64] = []
        for label in try labels(where: "source = 'group' AND person_id = ? AND face_id IS NOT NULL", [.int(person)]) {
            guard let face = try faceRecords(ids: [label.faceID!]).first else { continue }
            // The face's own copy in the core does not vouch for it: compare with every core face that is not this one.
            let others = core.filter { $0 != face.embedding }
            if others.isEmpty || (others.map { Double(dot(face.embedding, $0)) }.max() ?? 0) < t.matching { flagged.append(face.id) }
        }
        return flagged
    }

    // MARK: groups

    public struct Group: Equatable, Sendable {
        public var id: Int64
        public var faceIDs: [Int64]
        /// Distinct photos by content key.
        public var photos: Int
    }

    /// Index service. Matches faces to people first, then clusters the leftovers (usable, unlabelled, not ignored) into groups, offered
    /// only with `groupFaces` faces from `groupPhotos` different photos counted by content key. Nothing is written until the end, then
    /// everything in one transaction: a cancelled or failed run changes nothing. Group ids carry over from the old groups by overlap.
    @discardableResult
    public func recluster(shouldStop: () -> Bool = { false }) throws -> [Group] {
        try requireOwner(.index, "groups")
        let t = try thresholds()
        try matchFaces()
        let labelled = try Set(labels(where: "face_id IS NOT NULL").compactMap(\.faceID))
        let pool = try allFaces().filter { isUsable($0, t) && !labelled.contains($0.id) }
        let raw = try FaceClustering.cluster(pool.map { ClusterInput(id: $0.id, path: $0.path, embedding: $0.embedding) },
                                             threshold: t.clustering, neighbours: t.neighbours, rounds: t.rounds, seed: t.seed, shouldStop: shouldStop)
        var fresh: [(faces: [FaceRecord], photos: Int)] = []
        for indices in raw {
            // Two faces of one photo are two people: when a group still holds both, the less confident goes back to the pool.
            var bestPerPath: [String: FaceRecord] = [:]
            for i in indices {
                let face = pool[i]
                if let kept = bestPerPath[face.path], (kept.confidence, -kept.id) >= (face.confidence, -face.id) { continue }
                bestPerPath[face.path] = face
            }
            let faces = bestPerPath.values.sorted { $0.id < $1.id }
            let photos = Set(faces.map(\.photo)).count
            if faces.count >= t.groupFaces && photos >= t.groupPhotos { fresh.append((faces, photos)) }
        }

        var old: [Int64: Set<Int64>] = [:]
        try db.query("SELECT group_id, face_id FROM grp_face") { old[$0.int(0), default: []].insert($0.int(1)) }
        var nextID = Int64(try meta("next_group_id") ?? "1") ?? 1
        // One-to-one, largest overlap first, fixed tie-break; accepted when the shared faces cover half of the smaller side.
        var pairs: [(old: Int64, new: Int, shared: Int)] = []
        for (oldID, oldFaces) in old {
            for (k, group) in fresh.enumerated() {
                let shared = group.faces.filter { oldFaces.contains($0.id) }.count
                if shared > 0, shared * 2 >= min(oldFaces.count, group.faces.count) { pairs.append((oldID, k, shared)) }
            }
        }
        pairs.sort { ($0.shared, -$0.old, -Int64($0.new)) > ($1.shared, -$1.old, -Int64($1.new)) }
        var ids = [Int64?](repeating: nil, count: fresh.count)
        var usedOld = Set<Int64>()
        for pair in pairs where ids[pair.new] == nil && !usedOld.contains(pair.old) {
            ids[pair.new] = pair.old; usedOld.insert(pair.old)
        }
        var groups: [Group] = []
        for (k, group) in fresh.enumerated() {
            var id = ids[k]
            if id == nil { id = nextID; nextID += 1 }
            groups.append(Group(id: id!, faceIDs: group.faces.map(\.id), photos: group.photos))
        }
        let run = Int64(try meta("group_run") ?? "0") ?? 0
        try db.transaction {
            try db.run("DELETE FROM grp_face")
            try db.run("DELETE FROM grp")
            for group in groups {
                try db.run("INSERT INTO grp(id, run) VALUES (?, ?)", [.int(group.id), .int(run + 1)])
                for face in group.faceIDs { try db.run("INSERT INTO grp_face(group_id, face_id) VALUES (?, ?)", [.int(group.id), .int(face)]) }
            }
            try setMeta("next_group_id", String(nextID))
            try setMeta("group_run", String(run + 1))
        }
        return groups
    }

    public func groups() throws -> [Group] {
        var byGroup: [Int64: [Int64]] = [:]
        try db.query("SELECT group_id, face_id FROM grp_face ORDER BY group_id, face_id") { byGroup[$0.int(0), default: []].append($0.int(1)) }
        return try byGroup.keys.sorted().map { id in
            let faces = try faceRecords(ids: byGroup[id]!)
            return Group(id: id, faceIDs: byGroup[id]!, photos: Set(faces.map(\.photo)).count)
        }
    }
}
