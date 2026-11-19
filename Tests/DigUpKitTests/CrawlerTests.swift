import Foundation
import Testing
@testable import DigUpKit

/// The crawl's folder rules (`Crawler.crawl`).
@Suite final class CrawlerTests {
    /// In Caches, not the temporary folder: the walk reports /private/var/… for /var/… (see LongFilesTests).
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    func write(_ path: String, _ text: String = "x") throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    func names(_ report: CrawlReport) -> [String] {
        report.candidates.map { String($0.path.dropFirst(folder.path.count + 1)) }.sorted()
    }

    @Test func aChosenFolderIsReadWholeAndProjectsInsideItAreNot() throws {
        try write("package.json", "{}")          // a marker in the chosen folder itself (a home folder in git)
        try write("notes.md", "notes")
        try write("Screenshot 2026-10-19 at 10.00.00.png")
        try write("app/package.json", "{}")      // a project found inside: only its screenshots count
        try write("app/readme.md", "readme")
        try write("app/Screenshot 2026-10-19 at 10.01.00.png")
        let report = Crawler.crawl([folder], options: IndexOptions())
        #expect(names(report) == ["Screenshot 2026-10-19 at 10.00.00.png", "app/Screenshot 2026-10-19 at 10.01.00.png",
                                  "notes.md"])
        #expect(report.skipped["inside a code project"] == 1)
        #expect(report.leftOut[folder.path]?["inside a code project"] == 1)
        #expect(report.leftOut[folder.path]?["code or data file"] == 2)   // the two package.json files
    }

    // DOWNSTREAM-FORK (2026-11-19): the files behind the counts of "why" in Settings → Folders.
    @Test func theFilesLeftOutAreListedWhenAsked() throws {
        try write("package.json", "{}")
        try write("app/package.json", "{}")
        try write("notes.md", "notes")
        try write("data.xyz")                      // a type DigUp doesn't read
        try write("more/other.xyz")
        // Not asked: the counts only, as before.
        let plain = Crawler.crawl([folder], options: IndexOptions())
        #expect(plain.leftOutFiles.isEmpty)
        #expect(plain.leftOut[folder.path]?["other type"] == 2)
        // Asked: the same counts, and each file under its reason.
        let listed = Crawler.crawl([folder], options: IndexOptions(), collectPaths: 10)
        #expect(listed.leftOut == plain.leftOut)
        let others = (listed.leftOutFiles[folder.path]?["other type"] ?? []).map { String($0.dropFirst(folder.path.count + 1)) }.sorted()
        #expect(others == ["data.xyz", "more/other.xyz"])
        #expect(listed.leftOutFiles[folder.path]?["code or data file"]?.count == 2)
    }

    @Test func theListOfLeftOutFilesIsCappedButTheCountIsNot() throws {
        for number in 1...5 { try write("file\(number).xyz") }
        let report = Crawler.crawl([folder], options: IndexOptions(), collectPaths: 3)
        #expect(report.leftOut[folder.path]?["other type"] == 5)
        #expect(report.leftOutFiles[folder.path]?["other type"]?.count == 3)
    }

    @Test func aSkippedFolderIsListedUnderItsReason() throws {
        try write("keep.md", "x")
        let skipped = folder.appendingPathComponent("skip-me")
        try write("skip-me/inner.md", "x")
        var options = IndexOptions()
        options.excludedFolders = [skipped.path]
        let report = Crawler.crawl([folder], options: options, collectPaths: 10)
        let key = report.leftOut[folder.path]?.keys.first { $0.hasPrefix("folders ") }
        #expect(key != nil)
        #expect(key.flatMap { report.leftOutFiles[folder.path]?[$0] }?.count == 1)
    }
}
