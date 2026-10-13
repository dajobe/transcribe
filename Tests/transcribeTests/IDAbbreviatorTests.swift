import Foundation
import XCTest
@testable import transcribe

final class IDAbbreviatorTests: XCTestCase {
    private let a = "aaaaaaaa-0000-4000-8000-000000000001"
    private let b = "bbbbbbbb-0000-4000-8000-000000000002"

    func testLoneIDShortensToTheFloor() {
        let abbreviator = IDAbbreviator(ids: [a])
        XCTAssertEqual(abbreviator.shorten(a), "aaaaaaaa")
        XCTAssertEqual("aaaaaaaa".count, IDAbbreviator.floor)
    }

    func testDistinctPrefixesShortenIndependently() {
        let abbreviator = IDAbbreviator(ids: [a, b])
        XCTAssertEqual(abbreviator.shorten(a), "aaaaaaaa")
        XCTAssertEqual(abbreviator.shorten(b), "bbbbbbbb")
    }

    func testSharedPrefixExtendsUntilUnique() {
        // Differ first at position 22 (0-based), so 23 characters are needed.
        let one = "aaaaaaaa-0000-4000-8000-000000000001"
        let two = "aaaaaaaa-0000-4000-8001-000000000002"
        let abbreviator = IDAbbreviator(ids: [one, two])
        XCTAssertEqual(abbreviator.shorten(one), "aaaaaaaa-0000-4000-8000")
        XCTAssertEqual(abbreviator.shorten(two), "aaaaaaaa-0000-4000-8001")
    }

    func testIDAbsentFromTheSetStaysWhole() {
        // A portable document's ID, or a store that could not be read:
        // without the prefix space there is no safe shortening.
        let abbreviator = IDAbbreviator(ids: [a])
        XCTAssertEqual(abbreviator.shorten(b), b)
        XCTAssertEqual(IDAbbreviator(ids: []).shorten(a), a)
    }

    func testIDShorterThanTheFloorStaysWhole() {
        let abbreviator = IDAbbreviator(ids: ["abc", a])
        XCTAssertEqual(abbreviator.shorten("abc"), "abc")
    }

    func testCorruptRowOccupiesPrefixSpace() {
        // A non-UUID row sharing the floor prefix forces the extension, the
        // same ambiguity ID resolution would see.
        let corrupt = "aaaaaaaa-not-a-uuid"
        let abbreviator = IDAbbreviator(ids: [a, corrupt])
        XCTAssertEqual(abbreviator.shorten(a), "aaaaaaaa-0")
        XCTAssertEqual(abbreviator.shorten(corrupt), "aaaaaaaa-n")
    }

    func testUppercaseRowCollidesWithItsLowercaseForm() {
        // Resolution lowercases typed input, so "AAAAAAAA" would reach the
        // lowercase row: the two rows are indistinguishable by any prefix.
        let upper = a.uppercased()
        let abbreviator = IDAbbreviator(ids: [a, upper])
        XCTAssertEqual(abbreviator.shorten(a), a)
        XCTAssertEqual(abbreviator.shorten(upper), upper)
    }

    func testNonLowercaseRowStaysWhole() {
        let mixed = "AAAAAAAA-0000-4000-8000-000000000001"
        let abbreviator = IDAbbreviator(ids: [mixed, b])
        XCTAssertEqual(abbreviator.shorten(mixed), mixed)
        XCTAssertEqual(abbreviator.shorten(b), "bbbbbbbb")
    }

    func testUppercaseRowOccupiesLowercasePrefixSpace() {
        let upper = "AAAAAAAA-0000-4000-8001-000000000002"
        let abbreviator = IDAbbreviator(ids: [a, upper])
        XCTAssertEqual(abbreviator.shorten(a), "aaaaaaaa-0000-4000-8000")
    }

    func testLowercaseFormOfAnUppercaseRowIsAbsent() {
        let abbreviator = IDAbbreviator(ids: [a.uppercased()])
        XCTAssertEqual(abbreviator.shorten(a), a)
    }

    func testIDThatPrefixesAnotherStaysWhole() {
        let longer = a + "-extra"
        let abbreviator = IDAbbreviator(ids: [a, longer])
        XCTAssertEqual(abbreviator.shorten(a), a)
        XCTAssertEqual(abbreviator.shorten(longer), a + "-")
    }

    func testNeighbourAlgorithmMatchesExhaustiveScan() {
        // Many IDs crowding a few shared prefixes, so the longest common
        // prefix often lies with a neighbour two or more places away in
        // insertion order.
        var generator = SplitMix64(seed: 0x1D_AB_B2)
        let groups = ["aaaaaaaa", "aaaaaaab", "abababab", "aaaaaaaa-0000-4000"]
        let ids = (0..<300).map { _ -> String in
            let head = groups.randomElement(using: &generator)!
            let tail = (0..<Int.random(in: 0...20, using: &generator))
                .map { _ in String("0123456789abcdef-".randomElement(using: &generator)!) }
                .joined()
            return head + tail
        }
        let abbreviator = IDAbbreviator(ids: ids)
        for id in ids {
            XCTAssertEqual(abbreviator.shorten(id), Self.exhaustiveShorten(id, in: ids), id)
        }
    }

    /// The definition, scanned directly: the shortest prefix of at least
    /// `floor` characters that no other row shares.
    private static func exhaustiveShorten(_ id: String, in ids: [String]) -> String {
        guard ids.filter({ $0 == id }).count == 1 else { return id }
        var length = IDAbbreviator.floor
        while length < id.count {
            let prefix = String(id.prefix(length))
            if !ids.contains(where: { $0 != id && $0.hasPrefix(prefix) }) { return prefix }
            length += 1
        }
        return id
    }
}

/// Seeded so a failure reproduces.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
