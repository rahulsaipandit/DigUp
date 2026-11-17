// DOWNSTREAM-FORK (2026-11-17): new in the fork. The files that could not be read: counted, listed, and put back to waiting
// (IndexStore.failedCount, failedFiles, requeueFailed; docs/design.md, "Files that could not be read").
import Foundation
import Testing
@testable import DigUpKit

@Suite final class FailedFilesTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-Failed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit { try? FileManager.default.removeItem(at: folder) }

    var files: URL { folder.appendingPathComponent("files") }

    /// Writes a file, trying again for a moment when Windows says another process has it open (security software scanning a file
    /// that was only just made does that, and it is not what these tests are about).
    func write(_ text: String, to url: URL) throws {
        var attempt = 0
        while true {
            do { return try text.write(to: url, atomically: false, encoding: .utf8) } catch {
                attempt += 1
                if attempt >= 20 { throw error }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    /// A store with five text files waiting.
    func storeWithFiles() throws -> (IndexStore, [FileRecord]) {
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for name in ["a", "b", "c", "d", "e"] {
            try write("words in file \(name) that make a few sentences about gardens and ferns.",
                      to: files.appendingPathComponent("\(name).txt"))
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([files])
        let waiting = try store.pending(limit: nil).sorted { $0.path < $1.path }
        try #require(waiting.count == 5)
        return (store, waiting)
    }

    @Test func failedFilesAreCountedAndListedWithTheirReasonsByPath() throws {
        let (store, waiting) = try storeWithFiles()
        #expect(try store.failedCount() == 0)
        try store.finish(waiting[2].id, state: "failed", detail: "unreadable: can't decode image")
        try store.finish(waiting[0].id, state: "failed", detail: "unreadable: PDF reader couldn't start")
        try store.finish(waiting[4].id, state: "done")
        #expect(try store.failedCount() == 2)
        let listed = try store.failedFiles(limit: 10)
        #expect(listed.map(\.id) == [waiting[0].id, waiting[2].id], "by path")
        #expect(listed.map(\.detail) == ["unreadable: PDF reader couldn't start", "unreadable: can't decode image"])
        #expect(try store.failedFiles(limit: 1).count == 1)
        #expect(try store.failedFiles(limit: 0).isEmpty, "a count alone is cheap: no list")
    }

    @Test func retryingPutsOnlyFailedFilesBackToWaitingAndClearsTheReason() throws {
        let (store, waiting) = try storeWithFiles()
        for index in [0, 1, 2] { try store.finish(waiting[index].id, state: "failed", detail: "unreadable: x") }
        try store.finish(waiting[3].id, state: "done")
        // One named file, and one that is not failed (done) is left as it is.
        let first = try store.requeueFailed(ids: [waiting[1].id, waiting[3].id])
        #expect(first == [waiting[1].id])
        #expect(try store.failedCount() == 2)
        let back = try store.pending(limit: nil).first { $0.id == waiting[1].id }
        #expect(back?.state == "pending" && back?.detail == nil)
        #expect(try store.pending(limit: nil).contains { $0.id == waiting[3].id } == false, "a done file stays done")
        // All of the rest.
        let rest = try store.requeueFailed(ids: nil)
        #expect(Set(rest) == [waiting[0].id, waiting[2].id])
        #expect(try store.failedCount() == 0)
        // Nothing failed: nothing happens, and an empty list means nothing.
        #expect(try store.requeueFailed(ids: nil).isEmpty)
        #expect(try store.requeueFailed(ids: []).isEmpty)
    }

    @Test func aFileThatFailsAgainIsCountedAgainNotTwice() throws {
        let (store, waiting) = try storeWithFiles()
        try store.finish(waiting[0].id, state: "failed", detail: "unreadable: x")
        try store.requeueFailed(ids: [waiting[0].id])
        #expect(try store.failedCount() == 0)
        try store.finish(waiting[0].id, state: "failed", detail: "unreadable: x")
        #expect(try store.failedCount() == 1)
    }
}
