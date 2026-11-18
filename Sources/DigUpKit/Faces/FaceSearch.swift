// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md §5.2, §8). The content key that tells copies of
// one photo apart from different photos, and the resolver that finds a person's name inside a search query.
import Foundation

public enum ContentKey {
    /// size, date taken (when known) and a hash of the first 64 KB. Cheap (one small read), and a collision needs the same size, date and
    /// opening bytes. Whether it separates this library's files without false matches is spike F6; until then it is an assumption.
    public static func make(path: String, size: Int64, taken: Int64? = nil) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024) else { return nil }
        // FNV-1a, 64 bits: not a security hash, only a fingerprint of the opening bytes.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in head { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(size)-\(taken.map(String.init) ?? "")-" + String(hash, radix: 16)
    }
}

public enum NameResolver {
    public struct Slot: Equatable, Sendable {
        /// The words as typed.
        public var phrase: String
        /// More than one person when two people share a name: neither is chosen for the user.
        public var people: [Int64]
    }

    public struct Resolution: Equatable, Sendable {
        public var slots: [Slot]
        /// The query with the names removed, for the usual meaning and word search. Empty when nothing is left (an album).
        public var remaining: String
    }

    /// Case, accents and a trailing "'s" do not matter: "PRIYA's", "priya" and "Priyá" are one name.
    static func fold(_ word: String) -> String {
        var text = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "'’")))
        for suffix in ["'s", "’s", "'", "’"] where text.lowercased().hasSuffix(suffix) && text.count > suffix.count {
            text = String(text.dropLast(suffix.count)); break
        }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Finds whole words or phrases equal to a person's name or alias, longest first ("Mary Ann" wins over "Mary"). Each is removed from the text.
    /// A name that is also a word (Rose, Hunter) is still found here; whether it applies is the caller's choice (§8: a person result beside the
    /// normal ones, never in place of them).
    public static func resolve(_ query: String, people: [Person]) -> Resolution {
        var names: [String: Set<Int64>] = [:]
        for person in people {
            for name in [person.name] + person.aliases {
                let key = name.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
                if !key.isEmpty { names[key, default: []].insert(person.id) }
            }
        }
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let folded = words.map(fold)
        let longest = names.keys.map { $0.split(separator: " ").count }.max() ?? 0
        var slots: [Slot] = []
        var used = [Bool](repeating: false, count: words.count)
        var start = 0
        while start < words.count {
            var matched = false
            for length in stride(from: min(longest, words.count - start), through: 1, by: -1) {
                let key = folded[start..<start + length].joined(separator: " ")
                if let ids = names[key] {
                    slots.append(Slot(phrase: words[start..<start + length].joined(separator: " "), people: ids.sorted()))
                    for i in start..<start + length { used[i] = true }
                    start += length; matched = true; break
                }
            }
            if !matched { start += 1 }
        }
        let rest = words.enumerated().filter { !used[$0.offset] }.map(\.element).joined(separator: " ")
        return Resolution(slots: slots, remaining: rest)
    }
}

extension FaceStore {
    /// The photos that contain **all** the chosen people (one entry per content key), newest first. This is the set a search is restricted
    /// to, like the file-kind filter: held by the search service and rebuilt on reload, so the lookup is cheap.
    public func photos(containingAll people: [Int64], includeSuggested: Bool = true) throws -> [AlbumEntry] {
        guard var common = try people.first.map({ Set(try album(of: $0, includeSuggested: includeSuggested).map(\.path)) }) else { return [] }
        var entries = Dictionary(uniqueKeysWithValues: try album(of: people[0], includeSuggested: includeSuggested).map { ($0.path, $0) })
        for person in people.dropFirst() {
            let other = try album(of: person, includeSuggested: includeSuggested)
            // A photo and its copies count as one: compare by every path of the entry.
            let paths = Set(other.flatMap { [$0.path] + $0.copies })
            common = common.filter { path in paths.contains(path) || (entries[path]?.copies.contains(where: paths.contains) ?? false) }
        }
        entries = entries.filter { common.contains($0.key) }
        return entries.values.sorted { $0.taken != $1.taken ? $0.taken > $1.taken : $0.path < $1.path }
    }
}
