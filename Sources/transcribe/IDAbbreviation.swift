import Foundation

/// Git-style document-ID shortening for display: an ID is shown as its
/// shortest prefix, no shorter than `floor` characters, that no other stored
/// ID shares — computed against the actual store contents, like git's
/// per-object abbreviation. Resolution accepts any unique prefix
/// (`CanonicalTranscriptStore.documentIDs(withPrefix:)` matches the same
/// stored text), so a shown ID always resolves back.
///
/// Resolution lowercases what the user types, so collisions are judged on
/// lowercased IDs, and an ID that is not already lowercase (only a corrupt
/// row can be) is never shortened: no typed prefix could reach it.
struct IDAbbreviator {
    /// The first UUID hex group. Git's floor is 7 hex digits; 8 keeps the
    /// visual break at the UUID's own first dash.
    static let floor = 8

    private let stored: Set<String>
    /// Lowercased IDs as UTF-8, in byte order. In byte order the stored ID
    /// sharing the longest prefix with any entry is one of its two
    /// neighbours, so each shortening needs only those two comparisons.
    /// Duplicates are kept: two rows lowercasing alike share their full
    /// length, which leaves both whole.
    private let sorted: [[UInt8]]

    /// `ids` must be the complete set of stored document IDs as written,
    /// including rows that do not parse as UUIDs: those occupy prefix space
    /// during resolution too.
    init(ids: [String]) {
        stored = Set(ids)
        sorted = ids.map { Array($0.lowercased().utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// Built from the store. When the store cannot be read, shortening is
    /// disabled (full IDs are safe; a too-short one could turn ambiguous).
    static func fromStore() -> IDAbbreviator {
        IDAbbreviator(ids: (try? CanonicalTranscriptStore.allDocumentIDs()) ?? [])
    }

    func shorten(_ id: String) -> String {
        // An ID absent from the set (a portable document, or a stale set)
        // cannot be checked for collisions, so it stays whole.
        guard id.count > Self.floor, id == id.lowercased(), stored.contains(id) else { return id }
        let key = Array(id.utf8)
        let index = lowerBound(of: key)
        guard index < sorted.count, sorted[index] == key else { return id }
        var shared = 0
        if index > 0 { shared = max(shared, Self.commonPrefixLength(sorted[index - 1], key)) }
        if index + 1 < sorted.count { shared = max(shared, Self.commonPrefixLength(sorted[index + 1], key)) }
        // Uniqueness is decided in bytes; the shown prefix is whole
        // characters covering at least `shared + 1` of them.
        var bytes = 0
        var characters = 0
        for character in id {
            if bytes > shared && characters >= Self.floor { break }
            bytes += character.utf8.count
            characters += 1
        }
        return characters < id.count ? String(id.prefix(characters)) : id
    }

    private func lowerBound(of key: [UInt8]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle].lexicographicallyPrecedes(key) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func commonPrefixLength(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}
