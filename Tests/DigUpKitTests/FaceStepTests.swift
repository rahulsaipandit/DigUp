// DOWNSTREAM-FORK (2026-11-17): the face step and the face program (docs/person-recognition.md 5.1, 5.2; §17 rows 18, 20). The tests that run the real
// program need `digup-faces` (scripts/build-faces-rs.sh) and the model files, and are skipped when either is missing; the photos in scripts/test-photos
// are the owner's own and git-ignored, so a test that needs them is skipped on any other machine.
import Foundation
import Testing
@testable import DigUpKit

@Suite final class FaceStepTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-FaceStep-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    deinit { try? FileManager.default.removeItem(at: folder) }

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let executable: URL = {
        if let path = ProcessInfo.processInfo.environment["DIGUP_FACES_EXE"] { return URL(fileURLWithPath: path) }
        return repo.appendingPathComponent("Vendor/faces-build/release/digup-faces.exe")
    }()
    static let models: URL = {
        let base = ProcessInfo.processInfo.environment["DIGUP_MODELS"].map { URL(fileURLWithPath: $0) } ?? ModelFiles.installed
        return base.appendingPathComponent("faces")
    }()
    static let available = FileManager.default.isExecutableFile(atPath: executable.path)
        && FileManager.default.fileExists(atPath: models.appendingPathComponent("sface.onnx").path)
    static let photos: [String] = {
        let dir = repo.appendingPathComponent("scripts/test-photos")
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".jpg") }.sorted().prefix(3).map { dir.appendingPathComponent($0).path }
    }()

    func step() -> FaceStep { FaceStep(directory: folder, executable: Self.executable, models: Self.models) }

    @Test func aMissingFaceProgramIsReportedAndNothingThrows() throws {
        let missing = FaceStep(directory: folder, executable: folder.appendingPathComponent("nope.exe"), models: folder)
        missing.scan([.init(path: "/a.jpg", size: 1, mtime: 1, taken: nil, picture: "/a.png")])   // does not throw
        #expect(missing.lastError?.contains("missing") == true)
        #expect(try FaceStore(directory: folder, role: .index).faceCount() == 0)
    }

    @Test func aFaceProgramThatDiesFailsOnlyTheScanRow() throws {
        // A program that exits at once: the batch is recorded as failed, nothing is thrown, and the next attempt starts a new one.
        let script = folder.appendingPathComponent("dies.cmd")
        try "@echo {\"ready\":true,\"signature\":\"\(FaceWorker.signature)\",\"dim\":128}\r\n@exit /b 1\r\n".write(to: script, atomically: true, encoding: .utf8)
        #if os(Windows)
        let step = FaceStep(directory: folder, executable: script, models: folder)
        step.scan([.init(path: "/a.jpg", size: 1, mtime: 1, taken: nil, picture: "/a.png")])
        let store = try FaceStore(directory: folder, role: .index)
        #expect(try store.scanStatus(of: "/a.jpg")?.status == .failed)
        #expect(step.failed == 1)
        #expect(try store.faceCount() == 0)
        #endif
    }

    @Test(.enabled(if: FaceStepTests.available)) func aPictureWithNoFaceIsRecordedAndNotScannedAgain() throws {
        let picture = folder.appendingPathComponent("blank.png")
        // A one-pixel PNG: valid, and with no face in it.
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!.write(to: picture)
        let step = step()
        defer { step.close() }
        let item = FaceStep.Item(path: "/blank.jpg", size: 10, mtime: 5, taken: nil, picture: picture.path)
        step.scan([item])
        let store = try FaceStore(directory: folder, role: .index)
        #expect(try store.scanStatus(of: "/blank.jpg")?.status == .empty)
        #expect(try store.needsScan(path: "/blank.jpg", size: 10, mtime: 5, signature: FaceWorker.signature) == false)
    }

    @Test(.enabled(if: FaceStepTests.available && !FaceStepTests.photos.isEmpty)) func realPhotosGiveFacesThatAreStoredWithTheirMeasurements() throws {
        let step = step()
        defer { step.close() }
        // The program reads pictures at most 1024 px, which is what DigUp hands it; these are whole photos, which it reads as they are.
        step.scan(Self.photos.map { .init(path: $0, size: 1, mtime: 1, taken: "2025:01:01 07:28:17", picture: $0) })
        #expect(step.lastError == nil, "\(step.lastError ?? "")")
        let store = try FaceStore(directory: folder, role: .index)
        let faces = try store.allFaces()
        #expect(faces.count >= Self.photos.count)               // at least a face a photo in these photos
        for face in faces {
            #expect(face.embedding.count == 128)
            #expect(abs(face.embedding.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3)   // a unit vector
            #expect(face.confidence >= 0.5 && face.box.pixels >= 20)           // above the hard floor, as stored
            #expect(face.landmarks?.count == 10)
            #expect(face.sharpness >= 0)
        }
        #expect(faces.allSatisfy { $0.contentKey != nil })
        // Scanned once: a second pass finds nothing waiting.
        let before = try store.faceCount()
        step.scan(Self.photos.map { .init(path: $0, size: 1, mtime: 1, taken: nil, picture: $0) })
        #expect(try store.faceCount() == before)
    }

    @Test func modelsBesideTheProgramAreFoundWhenTheModelsFolderHasNone() throws {
        // An installer puts them in faces\ beside the helper; a person's own models folder wins when it has them.
        let bin = folder.appendingPathComponent("helper"), empty = folder.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: bin.appendingPathComponent("faces"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let exe = bin.appendingPathComponent("digup.exe"), faces = bin.appendingPathComponent("digup-faces.exe")
        #if os(Windows)
        // Windows asks whether it is a program: a real one stands in.
        for file in [exe, faces] { try FileManager.default.copyItem(atPath: #"C:\Windows\System32\cmd.exe"#, toPath: file.path) }
        #else
        for file in [exe, faces] {
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        #endif
        try Data("x".utf8).write(to: bin.appendingPathComponent("faces/sface.onnx"))
        let (step, why) = FaceStep.locate(directory: folder, models: empty, helper: exe)
        #expect(step != nil, "\(why ?? "")")
        let (none, reason) = FaceStep.locate(directory: folder, models: empty, helper: folder.appendingPathComponent("elsewhere/digup.exe"))
        #expect(none == nil && reason?.contains("missing") == true)
    }

    @Test func aCameraDateIsReadAsSeconds() {
        #expect(FaceStep.epoch("2025:01:01 07:28:17") == 1_735_716_497)
        #expect(FaceStep.epoch("garbage") == nil)
    }
}
