// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md §17). These tests use generated vectors, never a real
// person's photo. They cover the store, the correction operations and undo, matching, clustering and name search; the face worker
// and models are not built yet, so nothing here says how well faces are recognised.
import Foundation
import Testing
@testable import DigUpKit

@Suite final class FaceTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-Faces-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    deinit { try? FileManager.default.removeItem(at: folder) }

    func index() throws -> FaceStore { try FaceStore(directory: folder, role: .index) }
    func search() throws -> FaceStore { try FaceStore(directory: folder, role: .search) }

    /// A unit vector for "identity" `who` (an axis), tilted by `noise` toward another axis, so same-identity vectors are close.
    func vector(_ who: Int, noise: Float = 0, tilt: Int = 31) -> [Float] {
        var v = [Float](repeating: 0, count: 32)
        v[who] = 1; v[tilt] = noise
        return normalised(v)
    }

    func detection(_ v: [Float], size: Double = 100, confidence: Double = 0.99, x: Double = 0) -> Detection {
        Detection(box: FaceBox(x: x, y: 0, w: size, h: size), confidence: confidence, sharpness: 500, embedding: v)
    }

    let sig = "yunet+sface/1"

    /// `count` photos of one identity, one face each, returning their face ids.
    @discardableResult
    func photos(_ store: FaceStore, of who: Int, count: Int, prefix: String? = nil, taken: Int64 = 1_000_000) throws -> [Int64] {
        var ids: [Int64] = []
        for i in 0..<count {
            let path = "/pics/\(prefix ?? "p\(who)")-\(i).jpg"
            try store.recordScan(path: path, size: 10, mtime: 1, taken: taken + Int64(i), contentKey: "k\(prefix ?? "p\(who)")-\(i)", signature: sig,
                                 detections: [detection(vector(who, noise: Float(i) * 0.01))])
            ids.append(try store.faceRecords(path: path)[0].id)
        }
        return ids
    }

    // MARK: store

    @Test func theHardFloorKeepsOutMeaninglessDetectionsAndNothingElse() throws {
        let store = try index()
        let n = try store.recordScan(path: "/a.jpg", size: 1, mtime: 1, signature: sig, detections: [
            detection(vector(1), size: 10),                 // a 10 px detection is never stored
            detection(vector(2), confidence: 0.2),          // below the confidence floor
            detection(vector(3), size: 25, confidence: 0.6) // low quality but above the floor: stored
        ])
        #expect(n == 1)
        #expect(try store.faceCount() == 1)
        #expect(try store.scanStatus(of: "/a.jpg")?.status == .faces)
        try store.recordScan(path: "/b.jpg", size: 1, mtime: 1, signature: sig, detections: [detection(vector(1), size: 10)])
        #expect(try store.scanStatus(of: "/b.jpg")?.status == .empty)   // a file with none above the floor is recorded, not rescanned
        #expect(try store.needsScan(path: "/b.jpg", size: 1, mtime: 1, signature: sig) == false)
    }

    @Test func aThresholdChangeChangesUsableFacesAndRescansNothing() throws {
        let index = try index(), search = try search()
        try index.recordScan(path: "/a.jpg", size: 1, mtime: 1, signature: sig, detections: [detection(vector(1), size: 50)])
        let face = try index.allFaces()[0]
        var t = try search.thresholds()
        #expect(index.isUsable(face, t))
        t.usablePixels = 80
        try search.setThresholds(t)
        #expect(try !index.isUsable(face, index.thresholds()))
        #expect(try index.needsScan(path: "/a.jpg", size: 1, mtime: 1, signature: sig) == false)    // no decode
        #expect(try index.needsScan(path: "/a.jpg", size: 1, mtime: 1, signature: "other-model") == true)   // a model change does
        #expect(try index.needsScan(path: "/a.jpg", size: 2, mtime: 1, signature: sig) == true)   // so does a changed file
    }

    @Test func aFailedScanIsRetriedAFewTimesAndTheIndexIsUntouched() throws {
        let store = try index()
        for _ in 0..<3 { try store.recordFailure(path: "/x.jpg", size: 1, mtime: 1, signature: sig) }
        #expect(try store.scanStatus(of: "/x.jpg")?.attempts == 3)
        #expect(try store.needsScan(path: "/x.jpg", size: 1, mtime: 1, signature: sig) == false)   // reported, not retried forever
    }

    @Test func eachServiceWritesOnlyItsOwnTables() throws {
        let index = try index(), search = try search()
        #expect(throws: FaceStore.Failure.self) { try search.recordScan(path: "/a", size: 1, mtime: 1, signature: sig, detections: []) }
        let person = try search.enrol(faces: try photos(index, of: 1, count: 1), as: "P")
        #expect(throws: FaceStore.Failure.self) { try index.rename(person: person, to: "x") }
        #expect(throws: FaceStore.Failure.self) { try search.matchFaces() }
        #expect(throws: FaceStore.Failure.self) { try search.recluster() }
        #expect(throws: FaceStore.Failure.self) { try index.undo() }
        #expect(try search.people().first?.name == "P")
    }

    @Test func twoServicesCanWriteTheFileAtOnce() throws {
        let index = try index(), search = try search()
        let ids = try photos(index, of: 1, count: 5)
        let person = try search.enrol(faces: ids, as: "Priya")
        try photos(index, of: 2, count: 3)
        try search.rename(person: person, to: "Priya S")
        #expect(try search.people().first?.name == "Priya S")
        #expect(try index.faceCount() == 8)
    }

    @Test func removingAFolderDeletesItsFacesLabelsAndCopies() throws {
        let index = try index(), search = try search()
        let ids = try photos(index, of: 1, count: 4)
        let person = try search.enrol(faces: ids, as: "Priya")
        try index.recordScan(path: "/other/x.jpg", size: 1, mtime: 1, signature: sig, detections: [detection(vector(2))])
        let removal = try search.removeFolder("/pics")
        #expect(removal.faces == 4 && removal.labels == 4)
        #expect(try search.faceCount() == 1)
        #expect(try search.labels(where: "1 = 1").isEmpty)
        #expect(try search.people().map(\.id) == [person])        // the person keeps their name, with an empty album
        #expect(try search.album(of: person).isEmpty)
        #expect(try search.undo() == nil)                         // undo cannot bring the labels back
        var rows = 0
        try search.db.query("SELECT COUNT(*) FROM scan WHERE path LIKE '/pics/%'") { rows = Int($0.int(0)) }
        #expect(rows == 0)
    }

    // DOWNSTREAM-FORK (2026-11-19): single photos in a folder that stays.
    @Test func aDeletedPhotoLosesItsFacesAndLabelsButTheRestStay() throws {
        let index = try index(), search = try search()
        let ids = try photos(index, of: 1, count: 4)
        let person = try search.enrol(faces: ids, as: "Priya")
        let removal = try index.follow(moved: [], removed: ["/pics/p1-0.jpg"])
        #expect(removal.faces == 1 && removal.scans == 1 && removal.labels == 1)
        #expect(try index.faceCount() == 3)
        #expect(try index.scanStatus(of: "/pics/p1-0.jpg") == nil)
        #expect(try search.labels(where: "path = '/pics/p1-0.jpg'").isEmpty)
        #expect(try search.labels(where: "1 = 1").count == 3)          // the other photos keep their names
        #expect(try search.people().map(\.id) == [person])
        #expect(try search.undo() == nil)                             // a label went: undo must not bring it back
    }

    @Test func aDeletedPhotoWithNoLabelLeavesTheUndoLogAlone() throws {
        let index = try index(), search = try search()
        let ids = try photos(index, of: 1, count: 3)
        _ = try search.enrol(faces: ids, as: "Priya")
        try index.recordScan(path: "/pics/stranger.jpg", size: 1, mtime: 1, signature: sig, detections: [detection(vector(7))])
        let removal = try index.follow(moved: [], removed: ["/pics/stranger.jpg"])
        #expect(removal.faces == 1 && removal.labels == 0)
        #expect(try search.undo() != nil)                             // naming Priya can still be undone
    }

    @Test func aMovedPhotoKeepsItsFacesAndNamesUnderTheNewPath() throws {
        let index = try index(), search = try search()
        let ids = try photos(index, of: 1, count: 3)
        let person = try search.enrol(faces: ids, as: "Priya")
        try index.follow(moved: [(from: "/pics/p1-0.jpg", to: "/trip/renamed.jpg")], removed: [])
        #expect(try index.faceRecords(path: "/pics/p1-0.jpg").isEmpty)
        #expect(try index.faceRecords(path: "/trip/renamed.jpg").count == 1)
        #expect(try index.scanStatus(of: "/trip/renamed.jpg")?.status == .faces)
        #expect(try search.labels(where: "path = '/trip/renamed.jpg'").count == 1)   // the name came along
        #expect(try search.album(of: person).count == 3)
    }

    @Test func pruneGoneForgetsOnlyPhotosThatAreGoneFromAFolderThatIsThere() throws {
        let index = try index()
        let root = folder.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let kept = root.appendingPathComponent("kept.jpg"), deleted = root.appendingPathComponent("deleted.jpg")
        try Data([1]).write(to: kept)
        for path in [kept.path, deleted.path, "/unplugged/drive/photo.jpg"] {
            try index.recordScan(path: path, size: 1, mtime: 1, signature: sig, detections: [detection(vector(3))])
        }
        // /unplugged is a chosen folder whose drive is away: nothing under it counts as deleted.
        let removal = try index.pruneGone(under: [root.path, "/unplugged"])
        #expect(removal.faces == 1)
        #expect(try index.scanStatus(of: deleted.path) == nil)
        #expect(try index.scanStatus(of: kept.path) != nil)
        #expect(try index.scanStatus(of: "/unplugged/drive/photo.jpg") != nil)
        #expect(try index.pruneGone(under: [root.path, "/unplugged"]) == FaceStore.Removal())
    }

    @Test func pruningKeepsOnlyThePhotosUnderTheFoldersStillIndexed() throws {
        let index = try index(), search = try FaceStore(directory: folder, role: .search)
        let ids = try photos(index, of: 1, count: 4)
        _ = try search.enrol(faces: ids, as: "Priya")
        try index.recordScan(path: "/other/x.jpg", size: 1, mtime: 1, signature: sig, detections: [detection(vector(2))])
        let removal = try index.prune(keepingUnder: ["/other"])
        #expect(removal.faces == 4)
        #expect(try index.faceCount() == 1)
        #expect(try index.prune(keepingUnder: ["/other"]) == FaceStore.Removal())   // nothing more to remove
    }

    @Test func deleteAllRemovesTheFile() throws {
        _ = try index()
        try FaceStore.deleteAllData(in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(FaceStore.file).path))
    }

    // MARK: labels survive a rescan

    @Test func aLabelSurvivesARescanAndReattaches() throws {
        let index = try index(), search = try search()
        let ids = try photos(index, of: 1, count: 5)
        let person = try search.enrol(faces: ids, as: "Priya")
        // The photo is edited: rescanned with the same face (a bit shifted).
        try index.recordScan(path: "/pics/p1-0.jpg", size: 99, mtime: 2, signature: sig, detections: [detection(vector(1), x: 5)])
        let labels = try search.labels(where: "person_id = ?", [.int(person)])
        #expect(labels.count == 5)
        #expect(labels.allSatisfy { $0.faceID != nil })
        #expect(try search.faceCount() == 5)                       // no duplicate faces
        #expect(try search.reviewList().isEmpty)
    }

    @Test func aLabelThatCannotReattachWaitsInTheReviewListAndIsNeverDeleted() throws {
        let index = try index(), search = try search()
        let ids = try photos(index, of: 1, count: 4)
        let person = try search.enrol(faces: ids, as: "Priya")
        try index.recordScan(path: "/pics/p1-0.jpg", size: 99, mtime: 2, signature: sig, detections: [detection(vector(9))])   // someone else now
        #expect(try search.reviewList().count == 1)
        #expect(try search.labels(where: "person_id = ?", [.int(person)]).count == 4)
    }

    @Test func siblingsDoNotStealALabel() throws {
        let index = try index(), search = try search()
        let ids = try photos(index, of: 1, count: 4)
        _ = try search.enrol(faces: ids, as: "Priya")
        // Rescan with two nearly identical faces: neither wins by the margin, so the label is not guessed.
        try index.recordScan(path: "/pics/p1-0.jpg", size: 99, mtime: 2, signature: sig,
                             detections: [detection(vector(1), x: 0), detection(vector(1, noise: 0.01), x: 200)])
        #expect(try search.reviewList().count == 1)
    }

    // MARK: corrections and undo

    @Test func aGroupCanJoinSomeoneAlreadyNamedInOneStepAndOneUndo() throws {
        let index = try index(), search = try search()
        _ = try photos(index, of: 1, count: 5)
        _ = try photos(index, of: 2, count: 5)
        let groups = try index.recluster()
        #expect(groups.count == 2)
        let person = try search.name(group: groups[0].id, as: "Priya")
        let before = try search.labels(where: "person_id IS NOT NULL").count
        try search.add(group: groups[1].id, to: person)
        #expect(try search.labels(where: "person_id = \(person)").count == before + 5)
        #expect(try search.undo() == "name")
        #expect(try search.labels(where: "person_id IS NOT NULL").count == before)   // one undo took the whole group back
        #expect(throws: (any Error).self) { try search.add(group: groups[1].id, to: 999) }
    }

    @Test func everyOperationIsUndoable() throws {
        let index = try index(), search = try search()
        let a = try photos(index, of: 1, count: 5), b = try photos(index, of: 2, count: 5)
        func snapshot() throws -> String {
            let people = try search.people().map { "\($0.id):\($0.name):\($0.aliases.joined(separator: "|"))" }
            let labels = try search.labels(where: "1 = 1").map { "\($0.faceID ?? -1):\($0.personID ?? -1):\($0.source.rawValue)" }
            var rejections: [String] = []
            try search.db.query("SELECT path, person_id FROM rejection ORDER BY id") { rejections.append("\($0.text(0) ?? ""):\($0.int(1))") }
            return (people + labels + rejections).joined(separator: ";")
        }
        let priya = try search.enrol(faces: a, as: "Priya")
        let rahul = try search.enrol(faces: b, as: "Rahul")
        let operations: [(String, () throws -> Void)] = [
            ("rename", { try search.rename(person: priya, to: "Priya S") }),
            ("aliases", { try search.setAliases(person: priya, ["Pri"]) }),
            ("move", { try search.move(face: a[0], to: rahul) }),
            ("reject", { try search.reject(face: a[1], notPerson: priya) }),
            ("split", { _ = try search.split(person: priya, faces: [a[2]], as: "Other") }),
            ("ignore", { try search.ignore(faces: [a[3]]) }),
            ("restore", { try search.ignore(faces: [a[3]]); try search.restore(faces: [a[3]]) }),
            ("merge", { try search.merge(person: rahul, into: priya) }),
            ("dissolve", { try search.dissolve(person: priya) }),
        ]
        for (name, run) in operations {
            let before = try snapshot()
            try run()
            if name == "restore" { try search.undo() }   // the ignore that set it up
            #expect(try snapshot() != before || name == "restore", "\(name) changed nothing")
            try search.undo()
            #expect(try snapshot() == before, "undo of \(name)")
        }
    }

    @Test func correctionsSurviveReindexing() throws {
        let index = try index(), search = try search()
        let a = try photos(index, of: 1, count: 6)
        let person = try search.enrol(faces: a, as: "Priya")
        try search.reject(face: a[5], notPerson: person)
        try index.recordScan(path: "/pics/new.jpg", size: 1, mtime: 1, signature: sig, detections: [detection(vector(1))])
        try index.recluster()
        try index.recluster()
        #expect(try search.people().map(\.id) == [person])
        #expect(try search.labels(where: "person_id = ? AND source = 'user'", [.int(person)]).count == 5)
        #expect(try search.label(forFace: a[5]) == nil)       // the rejected face stays out of the person
    }

    @Test func dissolveReturnsFacesToThePoolAndIgnoreKeepsThemOut() throws {
        let index = try index(), search = try search()
        let a = try photos(index, of: 1, count: 4), b = try photos(index, of: 2, count: 4)
        let priya = try search.enrol(faces: a, as: "Priya")
        let rahul = try search.enrol(faces: b, as: "Rahul")
        try search.dissolve(person: priya)
        try search.ignore(faces: b)
        #expect(try search.people().map(\.id) == [rahul])
        let groups = try index.recluster()
        #expect(groups.count == 1)                              // the dissolved person's faces regroup
        #expect(Set(groups[0].faceIDs) == Set(a))
        try photos(index, of: 2, count: 2, prefix: "later")      // more photos of the ignored person
        #expect(try index.recluster().allSatisfy { Set($0.faceIDs).isDisjoint(with: b) })
    }

    // MARK: matching

    @Test func namingAPersonLabelsNewPhotosByMargin() throws {
        let index = try index(), search = try search()
        let priya = try search.enrol(faces: try photos(index, of: 1, count: 5), as: "Priya")
        _ = try search.enrol(faces: try photos(index, of: 2, count: 5), as: "Rahul")
        try index.recordScan(path: "/pics/new.jpg", size: 1, mtime: 1, signature: sig, detections: [detection(vector(1, noise: 0.1))])
        let result = try index.matchFaces()
        #expect(result.labelled == 1)
        let face = try index.faceRecords(path: "/pics/new.jpg")[0]
        let label = try #require(try index.label(forFace: face.id))
        #expect(label.personID == priya && label.source == .auto)
    }

    @Test func aLookalikeBetweenTwoPeopleIsNotLabelled() throws {
        let index = try index(), search = try search()
        _ = try search.enrol(faces: try photos(index, of: 1, count: 5), as: "Priya")
        _ = try search.enrol(faces: try photos(index, of: 2, count: 5), as: "Rahul")
        // Halfway between the two: it matches both by the same margin, so neither is chosen.
        var between = [Float](repeating: 0, count: 32); between[1] = 1; between[2] = 1
        try index.recordScan(path: "/pics/twin.jpg", size: 1, mtime: 1, signature: sig, detections: [detection(between)])
        #expect(try index.matchFaces().labelled == 0)
    }

    @Test func autoLabelsDoNotWidenTheCore() throws {
        let index = try index(), search = try search()
        let priya = try search.enrol(faces: try photos(index, of: 1, count: 5), as: "Priya")
        try index.recordScan(path: "/pics/new.jpg", size: 1, mtime: 1, signature: sig, detections: [detection(vector(1, noise: 0.5))])
        try index.matchFaces()
        let core = try index.cores()[priya] ?? []
        #expect(core.count == 5)       // only the user's faces
    }

    @Test func theCoreDropsAStrayFaceButKeepsAProfile() throws {
        var t = FaceThresholds.defaults
        t.coreSupport = 3
        // Four frontal faces, a profile that matches three of them, and a stranger who matches nobody.
        func unit(_ a: Float, _ b: Float) -> [Float] { var v = [Float](repeating: 0, count: 8); v[0] = a; v[1] = b; return normalised(v) }
        var stranger = [Float](repeating: 0, count: 8); stranger[7] = 1
        let items = [unit(1, 0), unit(1, 0.1), unit(1, 0.2), unit(1, 0.3), unit(1, 1.2), stranger].map { CoreCandidate(embedding: $0) }
        let core = PersonCore.select(items, t)
        #expect(!core.contains(5))
        #expect(core.contains(4))
    }

    @Test func aGroupLabelThatDisagreesIsFlaggedNotMoved() throws {
        let index = try index(), search = try search()
        let a = try photos(index, of: 1, count: 6)
        let wrong = try photos(index, of: 3, count: 4, prefix: "wrong")
        let groups = try index.recluster()
        #expect(groups.count == 2)
        // The user names the mixed group by naming one of them: build it by hand, five good faces and one wrong one.
        let person = try search.enrol(faces: Array(a.prefix(5)), as: "Priya")
        try search.db.run("""
            INSERT INTO label(path, x, y, w, h, embedding, face_id, person_id, source, confidence, date)
            SELECT path, x, y, w, h, embedding, id, ?, 'group', 1, 0 FROM face WHERE id = ?
            """, [.int(person), .int(wrong[0])])
        #expect(try index.flaggedForReview(person: person) == [wrong[0]])
        #expect(try search.label(forFace: wrong[0])?.personID == person)   // flagged only
    }

    // MARK: clustering

    @Test func clusteringIsRepeatableAndSeparatesPeople() throws {
        var inputs: [ClusterInput] = []
        for who in 0..<3 { for i in 0..<10 { inputs.append(ClusterInput(id: Int64(who * 10 + i), path: "/\(who)-\(i)", embedding: vector(who, noise: Float(i) * 0.02))) } }
        let a = try FaceClustering.cluster(inputs, threshold: 0.45, neighbours: 80, rounds: 20, seed: 7)
        let b = try FaceClustering.cluster(inputs, threshold: 0.45, neighbours: 80, rounds: 20, seed: 7)
        #expect(a == b)
        #expect(a.count == 3)
        #expect(a.allSatisfy { $0.count == 10 })
    }

    @Test func twoFacesOfOnePhotoAreNeverLinked() throws {
        let inputs = [ClusterInput(id: 1, path: "/same", embedding: vector(1)), ClusterInput(id: 2, path: "/same", embedding: vector(1))]
        #expect(try FaceClustering.cluster(inputs, threshold: 0.1, neighbours: 5, rounds: 5, seed: 1).count == 2)
    }

    @Test func aCancelledRunChangesNothing() throws {
        let index = try index()
        try photos(index, of: 1, count: 6)
        let before = try index.recluster()
        try photos(index, of: 2, count: 6)
        var polls = 0
        #expect(throws: FaceClustering.Cancelled.self) { try index.recluster { polls += 1; return polls > 3 } }
        #expect(try index.groups() == before)
    }

    @Test func singletonsAndCopiesDoNotMakeGroups() throws {
        let index = try index()
        // 100 different people, one photo each (one-hot vectors are all unrelated): no group, so no new people.
        for i in 0..<100 {
            var v = [Float](repeating: 0, count: 128); v[i] = 1
            try index.recordScan(path: "/one/\(i).jpg", size: 1, mtime: 1, contentKey: "u\(i)", signature: sig, detections: [detection(v)])
        }
        #expect(try index.recluster().isEmpty)
        // Three copies of one photo (one content key) are one photo, not three: no group.
        for i in 0..<3 {
            var v = [Float](repeating: 0, count: 128); v[120] = 1
            try index.recordScan(path: "/backup/c\(i).jpg", size: 1, mtime: 1, contentKey: "same", signature: sig, detections: [detection(v)])
        }
        #expect(try index.recluster().isEmpty)
        // Three different photos of one person do make one.
        for i in 0..<3 {
            var v = [Float](repeating: 0, count: 128); v[121] = 1
            try index.recordScan(path: "/real/\(i).jpg", size: 1, mtime: 1, contentKey: "r\(i)", signature: sig, detections: [detection(v)])
        }
        #expect(try index.recluster().count == 1)
    }

    @Test func groupIdsCarryOverARebuild() throws {
        let index = try index()
        try photos(index, of: 1, count: 6)
        let first = try index.recluster()
        try photos(index, of: 1, count: 2, prefix: "more")
        let second = try index.recluster()
        #expect(first.count == 1 && second.count == 1)
        #expect(first[0].id == second[0].id)
        #expect(second[0].faceIDs.count == 8)
    }

    // MARK: albums and duplicates

    @Test func anAlbumHasOneEntryPerContentKeyNewestFirst() throws {
        let index = try index(), search = try search()
        var ids: [Int64] = []
        for (i, path) in ["/pics/a.jpg", "/backup/a.jpg", "/pics/b.jpg"].enumerated() {
            try index.recordScan(path: path, size: 1, mtime: 1, taken: i == 2 ? 50 : 10, contentKey: i == 2 ? "b" : "a", signature: sig, detections: [detection(vector(1))])
            ids.append(try index.faceRecords(path: path)[0].id)
        }
        let person = try search.enrol(faces: ids, as: "Priya")
        let album = try search.album(of: person)
        #expect(album.count == 2)
        #expect(album[0].path == "/pics/b.jpg")                         // newest first
        #expect(album[1].copies.count == 1)                              // the backup is a copy, not another photo
    }

    @Test func contentKeyTellsCopiesFromDifferentPhotos() throws {
        let a = folder.appendingPathComponent("a.bin"), b = folder.appendingPathComponent("b.bin"), c = folder.appendingPathComponent("c.bin")
        try Data(repeating: 1, count: 70_000).write(to: a)
        try Data(repeating: 1, count: 70_000).write(to: b)
        try Data(repeating: 2, count: 70_000).write(to: c)
        #expect(ContentKey.make(path: a.path, size: 70_000) == ContentKey.make(path: b.path, size: 70_000))
        #expect(ContentKey.make(path: a.path, size: 70_000) != ContentKey.make(path: c.path, size: 70_000))
        #expect(ContentKey.make(path: a.path, size: 70_000) != ContentKey.make(path: a.path, size: 70_001))
        #expect(ContentKey.make(path: folder.appendingPathComponent("missing").path, size: 1) == nil)
    }

    // MARK: name search

    func person(_ id: Int64, _ name: String, _ aliases: [String] = []) -> Person { Person(id: id, name: name, aliases: aliases, isPrivate: false) }

    @Test func aNameIsFoundInAQueryAndRemoved() {
        let people = [person(1, "Priya")]
        #expect(NameResolver.resolve("priya at the beach", people: people) == .init(slots: [.init(phrase: "priya", people: [1])], remaining: "at the beach"))
        #expect(NameResolver.resolve("Priya's birthday", people: people).remaining == "birthday")       // possessive
        #expect(NameResolver.resolve("Priyá", people: people).slots.count == 1)                          // accents
        #expect(NameResolver.resolve("priya", people: people).remaining == "")                           // exactly a name: an album
        #expect(NameResolver.resolve("priyanka", people: people).slots.isEmpty)                          // whole words only
    }

    @Test func longestNameWinsAndSeveralPeopleCombine() {
        let people = [person(1, "Mary"), person(2, "Mary Ann"), person(3, "Rahul", ["Rahu"])]
        let r = NameResolver.resolve("Mary Ann and rahu on a boat", people: people)
        #expect(r.slots.map(\.people) == [[2], [3]])
        #expect(r.remaining == "and on a boat")
    }

    @Test func twoPeopleWithOneNameAreBothOfferedAndNeitherIsChosen() {
        let r = NameResolver.resolve("rose in the garden", people: [person(1, "Rose"), person(2, "Rose")])
        #expect(r.slots == [.init(phrase: "rose", people: [1, 2])])
    }

    @Test func aNameThatIsAlsoAWordIsStillOnlyASlotTheCallerMayIgnore() {
        let r = NameResolver.resolve("a rose in the garden", people: [person(1, "Rose")])
        #expect(r.slots.count == 1 && r.remaining == "a in the garden")   // the caller shows it beside normal results (§8)
    }

    @Test func photosWithAllTheNamedPeople() throws {
        let index = try index(), search = try search()
        var a: [Int64] = [], b: [Int64] = []
        for i in 0..<3 {
            let path = "/pics/both-\(i).jpg"
            try index.recordScan(path: path, size: 1, mtime: 1, taken: Int64(i), contentKey: "both\(i)", signature: sig,
                                 detections: [detection(vector(1), x: 0), detection(vector(2), x: 200)])
            let faces = try index.faceRecords(path: path)
            a.append(faces[0].id); b.append(faces[1].id)
        }
        a += try photos(index, of: 1, count: 2, prefix: "only")
        let priya = try search.enrol(faces: a, as: "Priya"), rahul = try search.enrol(faces: b, as: "Rahul")
        #expect(try search.photos(containingAll: [priya]).count == 5)
        #expect(try search.photos(containingAll: [priya, rahul]).map(\.path) == ["/pics/both-2.jpg", "/pics/both-1.jpg", "/pics/both-0.jpg"])
    }
}
