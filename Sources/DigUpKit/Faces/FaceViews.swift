// DOWNSTREAM-FORK (2026-11-18): what the People window and `digup faces` show (docs/person-recognition.md §10): groups waiting for a name
// with a few sample faces, people with a sample face, counts. Read-only queries; the corrections are in FacePeople.swift.
import Foundation

/// A face as a picture needs it: where it is, in the coordinates of the picture the face program read (the photo at most 1024 px on its
/// longer side, as `ImageExtractor.prepare` makes it).
public struct FaceCrop: Equatable, Sendable {
    public var id: Int64
    public var path: String
    public var box: FaceBox
    public var confidence: Double
}

public struct FaceCounts: Equatable, Sendable {
    public var faces = 0, photosWithFaces = 0, scanned = 0, failed = 0, groups = 0, people = 0, namedFaces = 0, ungroupedFaces = 0
}

extension FaceStore {
    private static func crop(_ row: Statement) -> FaceCrop {
        FaceCrop(id: row.int(0), path: row.text(1) ?? "", box: FaceBox(x: row.double(2), y: row.double(3), w: row.double(4), h: row.double(5)),
                 confidence: row.double(6))
    }

    public func crops(ids: [Int64]) throws -> [FaceCrop] {
        var out: [FaceCrop] = []
        for id in ids {
            try db.query("SELECT id, path, x, y, w, h, confidence FROM face WHERE id = ?", [.int(id)]) { out.append(Self.crop($0)) }
        }
        return out
    }

    /// Faces with a label of any kind that names a person (suggestions included).
    public func labelledFaceIDs() throws -> Set<Int64> {
        var out = Set<Int64>()
        try db.query("SELECT face_id FROM label WHERE face_id IS NOT NULL AND person_id IS NOT NULL") { out.insert($0.int(0)) }
        return out
    }

    /// Faces the person has been given, the best first: `user` labels, then group labels, then suggestions; larger and surer faces first.
    public func sampleFaces(ofPerson person: Int64, limit: Int) throws -> [FaceCrop] {
        var out: [FaceCrop] = []
        try db.query("""
            SELECT f.id, f.path, f.x, f.y, f.w, f.h, f.confidence FROM label l JOIN face f ON f.id = l.face_id
            WHERE l.person_id = ? ORDER BY CASE l.source WHEN 'user' THEN 0 WHEN 'group' THEN 1 ELSE 2 END, MIN(f.w, f.h) * f.confidence DESC, f.id
            LIMIT ?
            """, [.int(person), .int(Int64(limit))]) { out.append(Self.crop($0)) }
        return out
    }

    /// Groups still waiting for a name (no face of them is labelled yet), the biggest first, each with its faces, the clearest first.
    public func unnamedGroups(sample: Int) throws -> [(group: Group, samples: [FaceCrop])] {
        let named = try labelledFaceIDs()
        var out: [(Group, [FaceCrop])] = []
        for group in try groups() where !group.faceIDs.contains(where: named.contains) {
            let faces = try crops(ids: group.faceIDs).sorted { (min($0.box.w, $0.box.h) * $0.confidence) > (min($1.box.w, $1.box.h) * $1.confidence) }
            // Samples from different photos first, so the picture shows the variety and not one burst.
            var seen = Set<String>(), picked: [FaceCrop] = []
            for face in faces where seen.insert(face.path).inserted && picked.count < sample { picked.append(face) }
            out.append((group, picked))
        }
        return out.sorted { ($0.0.faceIDs.count, -$0.0.id) > ($1.0.faceIDs.count, -$1.0.id) }.map { (group: $0.0, samples: $0.1) }
    }

    public func counts() throws -> FaceCounts {
        var c = FaceCounts()
        func one(_ sql: String) throws -> Int { var n = 0; try db.query(sql) { n = Int($0.int(0)) }; return n }
        c.faces = try one("SELECT COUNT(*) FROM face")
        c.photosWithFaces = try one("SELECT COUNT(DISTINCT path) FROM face")
        c.scanned = try one("SELECT COUNT(*) FROM scan WHERE status IN ('faces', 'none')")
        c.failed = try one("SELECT COUNT(*) FROM scan WHERE status = 'failed'")
        c.people = try one("SELECT COUNT(*) FROM person")
        c.namedFaces = try one("SELECT COUNT(*) FROM label WHERE face_id IS NOT NULL AND person_id IS NOT NULL")
        let named = try labelledFaceIDs()
        let groups = try self.groups()
        c.groups = groups.filter { !$0.faceIDs.contains(where: named.contains) }.count
        c.ungroupedFaces = c.faces - c.namedFaces
        return c
    }
}

extension SearchHit {
    /// A photo as a result with no words behind it: a search for people alone lists their photos (docs/person-recognition.md §8).
    public init(photo path: String, modified: Double, size: Int64) {
        self.init(path: path, kind: .image, score: 0, z: nil, cosine: nil, keywordRank: nil, segment: .image, segmentID: 0, loc: nil,
                  locEnd: nil, excerpt: nil, modified: modified, size: size, info: [:])
    }
}
