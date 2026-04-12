import XCTest
@testable import transcribe

final class OutputFormatTests: XCTestCase {
    func testParseOutputFormatsRejectsEmptyValues() {
        XCTAssertEqual(parseOutputFormats(""), [])
        XCTAssertEqual(parseOutputFormats(","), [])
        XCTAssertEqual(parseOutputFormats(" , "), [])
    }

    func testParseOutputFormatsDeduplicatesWhilePreservingOrder() {
        XCTAssertEqual(parseOutputFormats("json, txt, json, srt, txt"), ["json", "txt", "srt"])
    }

    func testParseOutputFormatsExpandsAll() {
        XCTAssertEqual(parseOutputFormats("all"), ["txt", "json", "srt", "vtt", "md"])
    }

    func testParseOutputFormatsAcceptsMd() {
        XCTAssertEqual(parseOutputFormats("md"), ["md"])
        XCTAssertEqual(parseOutputFormats("txt,md"), ["txt", "md"])
    }
}
