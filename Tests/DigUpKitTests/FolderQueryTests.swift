// DOWNSTREAM-FORK (2026-11-19): `folder:` in a query (Sources/DigUpKit/FolderQuery.swift).
import Foundation
import Testing
@testable import DigUpKit

@Suite final class FolderQueryTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-FolderQuery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    deinit { try? FileManager.default.removeItem(at: folder) }

    @Test func aQueryWithoutFolderIsLeftExactlyAsTyped() {
        let query = FolderQuery.parse("  receipts   from the  hardware store ")
        #expect(query.text == "  receipts   from the  hardware store ")
        #expect(!query.found && !query.isFiltered && query.contains("/anywhere/at/all.jpg"))
    }

    @Test func aQuotedPathWithSpacesIsOneFolder() {
        let query = FolderQuery.parse(#"receipts folder:"D:\RP_Backup\RP Bak Photos\Photos""#)
        #expect(query.text == "receipts")
        #expect(query.folders == ["D:/RP_Backup/RP Bak Photos/Photos"])
        #expect(query.rejected.isEmpty)
    }

    @Test func severalFoldersAreSeparatedByCommas() {
        for typed in [#"folder:D:\Photos,E:\Scans receipts"#, #"receipts folder:D:\Photos, E:\Scans"#, #"receipts folder:D:\Photos ,E:\Scans"#,
                      #"receipts folder:"D:\Photos","E:\Scans""#, #"receipts folder:  "D:\Photos" , "E:\Scans""#] {
            let query = FolderQuery.parse(typed)
            #expect(query.folders == ["D:/Photos", "E:/Scans"], "\(typed)")
            #expect(query.text == "receipts", "\(typed)")
        }
    }

    @Test func theKeywordMayBeInAnyCaseAndAnywhereButOnlyAtTheStartOfAWord() {
        #expect(FolderQuery.parse(#"Folder:D:\A cats"#).folders == ["D:/A"])
        #expect(FolderQuery.parse(#"cats FOLDER:D:\A dogs"#).text == "cats dogs")
        #expect(!FolderQuery.parse(#"subfolder:D:\A"#).found)    // a word that merely ends in it
        #expect(FolderQuery.parse(#"a folder:D:\A and folder:E:\B"#).folders == ["D:/A", "E:/B"])
    }

    @Test func onlyCompletePathsAreUnderstood() {
        let query = FolderQuery.parse(#"receipts folder:Receipts,D:\Photos,..\up"#)
        #expect(query.folders == ["D:/Photos"])
        #expect(query.rejected == ["Receipts", "..\\up"])
        #expect(query.note(empty: [])?.contains("complete paths") == true)
        #expect(FolderQuery.normalize("//server/share/Pics/") == "//server/share/Pics")      // a network share
        #expect(FolderQuery.normalize("/home/me/photos") == "/home/me/photos")
        #expect(FolderQuery.normalize("D:") == "D:" && FolderQuery.normalize("D:\\") == "D:")
        #expect(FolderQuery.normalize("DD:\\x") == nil && FolderQuery.normalize("photos") == nil)
        #expect(FolderQuery.parse("receipts folder:").note(empty: [])?.contains("needs a complete path") == true)
    }

    @Test func everythingInsideCountsSubfoldersToo() {
        let query = FolderQuery.parse(#"folder:D:\RP_Backup\Photos"#)
        #expect(query.contains("D:/RP_Backup/Photos/2006/a.jpg"))
        #expect(query.contains(#"D:\RP_Backup\Photos\b.jpg"#))             // the path as Windows writes it
        #expect(query.contains("d:/rp_backup/photos/c.jpg"))               // whatever the case (Windows and macOS)
        #expect(!query.contains("D:/RP_Backup/Photos2/d.jpg"))             // a folder that only starts with the same letters
        #expect(!query.contains("D:/RP_Backup/Videos/e.mp4"))
        #expect(FolderQuery.parse(#"folder:D:\A,E:\B"#).contains("E:/B/x.png"))
        #expect(FolderQuery.parse("folder:D:").contains("D:/anything.png"))   // a whole drive
    }

    @Test func aFolderThatHoldsNothingSaysSo() {
        let query = FolderQuery.parse(#"folder:D:\Nowhere receipts"#)
        #expect(query.note(empty: ["D:/Nowhere"]) == "nothing is indexed under D:/Nowhere (a path with a space needs quotes)")
        #expect(query.note(empty: []) == nil)
    }

    // MARK: the search itself

    func store() throws -> IndexStore {
        let store = try IndexStore(directory: folder)
        func add(_ path: String, _ text: String) throws {
            let id = try store.insert(Candidate(path: path, kind: .doc, size: 1, mtime: 1, inode: UInt64(path.count), device: 1))
            try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1, text: text)
        }
        try add("D:/Photos/2025/receipt-hardware.txt", "Receipt from the hardware store: screws and glue")
        try add("D:/Photos/receipt-pharmacy.txt", "Receipt from the pharmacy")
        try add("E:/Scans/receipt-taxi.txt", "Taxi receipt to the airport")
        try add("D:/Photos2/receipt-books.txt", "Receipt for the books")
        try add("D:/Other/receipt-lunch.txt", "Lunch receipt")
        return store
    }

    func found(_ store: IndexStore, _ typed: String) throws -> [String] {
        let query = FolderQuery.parse(typed)
        let scope = query.isFiltered ? try store.fileIDs(in: query).ids : nil
        return try Searcher(store: store, loadVectors: false).search(query.text, queryVector: nil, onlyFiles: scope).map(\.path).sorted()
    }

    @Test func theSearchStaysInsideTheFoldersAndTheirSubfolders() throws {
        let store = try store()
        #expect(try found(store, "receipt").count == 5)
        #expect(try found(store, #"receipt folder:D:\Photos"#) == ["D:/Photos/2025/receipt-hardware.txt", "D:/Photos/receipt-pharmacy.txt"])
        #expect(try found(store, #"receipt folder:"d:\photos", E:\Scans"#)
                == ["D:/Photos/2025/receipt-hardware.txt", "D:/Photos/receipt-pharmacy.txt", "E:/Scans/receipt-taxi.txt"])
        #expect(try found(store, #"receipt folder:D:\Nowhere"#).isEmpty)
    }

    @Test func theIdsOfAFolderAreExactlyItsIndexedFiles() throws {
        let store = try store()
        #expect(try store.fileIDs(in: FolderQuery.parse(#"folder:D:\Photos"#)).ids.count == 2)
        #expect(try store.fileIDs(in: FolderQuery.parse(#"folder:D:\Photos,E:\Scans"#)).ids.count == 3)
        let none = try store.fileIDs(in: FolderQuery.parse(#"folder:D:\Photos,D:\Nowhere"#))
        #expect(none.ids.count == 2 && none.empty == ["D:/Nowhere"])     // one folder of two holds nothing: it is named
    }
}
