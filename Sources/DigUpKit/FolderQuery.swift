// DOWNSTREAM-FORK (2026-11-19): a folder limit typed in the query, as in
//
//     receipts folder:"D:\RP_Backup\RP_Bak_Photos_Videos\Photos"
//     receipts folder:D:\Photos,D:\Scans                       (several folders: a comma between complete paths)
//     receipts folder:"D:\My Photos", "E:\Old Pictures"         (quotes where a path has a space)
//
// The folders are complete paths (a drive and a path, a network share, or a path from the root), and everything inside them counts, subfolders
// included. A name like `folder:Receipts` is not understood and is reported, not guessed at. The words around the limit are searched as usual.
import Foundation

public struct FolderQuery: Sendable, Equatable {
    /// The query without its `folder:` parts (the query as typed when it has none).
    public var text: String
    /// The folders asked for: complete paths with forward slashes and no trailing slash.
    public var folders: [String] = []
    /// What was typed after `folder:` that is not a complete path.
    public var rejected: [String] = []
    /// The query has a `folder:` part, even an empty or a wrong one.
    public var found = false

    public var isFiltered: Bool { !folders.isEmpty }

    private static let keyword = Array("folder:")

    public static func parse(_ query: String) -> FolderQuery {
        let chars = Array(query)
        var result = FolderQuery(text: query)
        var text = ""
        var index = 0
        while index < chars.count {
            guard startsKeyword(chars, at: index) else {
                text.append(chars[index])
                index += 1
                continue
            }
            result.found = true
            var next = index + keyword.count
            while next < chars.count, chars[next] == " " { next += 1 }   // "folder: D:\Photos"
            var items: [String] = []
            while next < chars.count {
                var item = ""
                if chars[next] == "\"" {
                    next += 1
                    while next < chars.count, chars[next] != "\"" { item.append(chars[next]); next += 1 }
                    if next < chars.count { next += 1 }                    // the closing quote
                } else {
                    while next < chars.count, !chars[next].isWhitespace, chars[next] != "," { item.append(chars[next]); next += 1 }
                }
                if !item.isEmpty { items.append(item) }
                // A comma, with spaces around it, goes on to the next path.
                var comma = next
                while comma < chars.count, chars[comma] == " " { comma += 1 }
                guard comma < chars.count, chars[comma] == "," else { break }
                next = comma + 1
                while next < chars.count, chars[next] == " " { next += 1 }
            }
            for item in items {
                if let folder = normalize(item) {
                    if !result.folders.contains(folder) { result.folders.append(folder) }
                } else {
                    result.rejected.append(item)
                }
            }
            index = next
        }
        if result.found { result.text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        return result
    }

    private static func startsKeyword(_ chars: [Character], at index: Int) -> Bool {
        guard index == 0 || chars[index - 1].isWhitespace, index + keyword.count <= chars.count else { return false }
        return zip(chars[index..<index + keyword.count], keyword).allSatisfy { $0.lowercased() == String($1) }
    }

    /// A complete path as the index writes it (forward slashes, no trailing slash), or nil for anything else.
    public static func normalize(_ typed: String) -> String? {
        let slashed = typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        let network = slashed.hasPrefix("//")   // \\server\share
        var path = network ? "/" : ""
        var previous: Character?
        for character in slashed {
            if character == "/", previous == "/" { continue }   // one slash between names
            path.append(character)
            previous = character
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let drive = path.count >= 2 && path.first!.isLetter && path[path.index(after: path.startIndex)] == ":"
            && (path.count == 2 || path[path.index(path.startIndex, offsetBy: 2)] == "/")
        guard drive || path.hasPrefix("/") else { return nil }
        return path
    }

    /// Whether `path` is inside one of the folders (or there are none: everything is).
    public func contains(_ path: String) -> Bool {
        guard !folders.isEmpty else { return true }
        let candidate = Self.fold(path.replacingOccurrences(of: "\\", with: "/"))
        return folders.contains { folder in
            let base = Self.fold(folder)
            return candidate == base || candidate.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// Windows and macOS keep names whatever their case; Linux does not.
    private static func fold(_ path: String) -> String {
        #if os(Linux)
        return path
        #else
        return path.lowercased()
        #endif
    }

    /// What to tell the person when the folders did not do what they meant; nil when all is well. `empty`: the folders with no indexed file in them.
    public func note(empty: [String]) -> String? {
        var parts: [String] = []
        if !rejected.isEmpty {
            parts.append("folder: needs complete paths such as D:\\Photos (not understood: \(rejected.joined(separator: ", ")))")
        }
        if found, folders.isEmpty, rejected.isEmpty { parts.append("folder: needs a complete path, such as folder:\"D:\\Photos\"") }
        if !empty.isEmpty { parts.append("nothing is indexed under \(empty.joined(separator: ", ")) (a path with a space needs quotes)") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

extension IndexStore {
    /// The ids of the indexed files inside the query's folders, and the folders with none. Compared as `FolderQuery.contains` does (case, slashes),
    /// so a path typed as it is in Explorer finds them; the folders are not looked up by prefix in SQL, which would be case-sensitive.
    public func fileIDs(in query: FolderQuery) throws -> (ids: Set<Int64>, empty: [String]) {
        let each = query.folders.map { FolderQuery(text: "", folders: [$0]) }
        var ids = Set<Int64>()
        var used = Set<String>()
        try db.query("SELECT id, path FROM files") { row in
            let path = row.text(1) ?? ""
            for folder in each where folder.contains(path) {
                ids.insert(row.int(0))
                used.insert(folder.folders[0])
            }
        }
        return (ids, query.folders.filter { !used.contains($0) })
    }
}
