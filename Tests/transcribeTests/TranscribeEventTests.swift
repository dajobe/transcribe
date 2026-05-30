import Foundation
import XCTest
@testable import transcribe

final class TranscribeEventTests: XCTestCase {
    func testTextRendererUsesLogfmtWithEscapedValues() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = try XCTUnwrap(formatter.date(from: "2026-05-29T16:28:08Z"))
        let event = TranscribeEvent(
            timestamp: date,
            level: .info,
            name: "phase_done",
            fields: [
                TranscribeEventField("source", .string("file")),
                TranscribeEventField("session", .string("1/1")),
                TranscribeEventField("input", .strings(["clip one.m4a"])),
                TranscribeEventField("outputs", .strings(["clip.txt", "clip.json"])),
                TranscribeEventField("elapsed_s", .double(4.2)),
                TranscribeEventField("path", .string(#"a "quoted" path"#)),
            ],
            message: "model loaded"
        )

        let line = TranscribeEventTextRenderer.render(event)

        XCTAssertEqual(
            line,
            #"2026-05-29T16:28:08Z INFO event=phase_done source=file session=1/1 input="clip one.m4a" outputs="clip.txt,clip.json" elapsed_s=4.2 path="a \"quoted\" path" message="model loaded""#
        )
    }

    func testTextRendererRendersDebugLevel() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = try XCTUnwrap(formatter.date(from: "2026-05-29T16:28:08Z"))
        let event = TranscribeEvent(
            timestamp: date,
            level: .debug,
            name: "session_skipped",
            fields: [TranscribeEventField("session", .string("1/2"))],
            message: "session skipped"
        )

        let line = TranscribeEventTextRenderer.render(event)

        XCTAssertEqual(
            line,
            #"2026-05-29T16:28:08Z DEBUG event=session_skipped session=1/2 message="session skipped""#
        )
    }

    func testReporterFiltersByMinimumLevel() throws {
        let pipe = Pipe()
        let reporter = TranscribeEventReporter(minimumLevel: .warn, handle: pipe.fileHandleForWriting)

        reporter.debug("debug_event", message: "hidden")
        reporter.info("info_event", message: "hidden")
        reporter.warning("shown")
        reporter.error("error_event", message: "also shown")
        pipe.fileHandleForWriting.closeFile()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(output.contains("debug_event"), output)
        XCTAssertFalse(output.contains("info_event"), output)
        XCTAssertTrue(output.contains("WARN event=warning"), output)
        XCTAssertTrue(output.contains("ERROR event=error_event"), output)
    }

    func testReporterEmitsDebugAtDebugLevel() throws {
        let pipe = Pipe()
        let reporter = TranscribeEventReporter(minimumLevel: .debug, handle: pipe.fileHandleForWriting)

        reporter.debug("debug_event", message: "shown")
        pipe.fileHandleForWriting.closeFile()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("DEBUG event=debug_event"), output)
        XCTAssertTrue(output.contains("message=shown"), output)
    }

    func testReporterSuppressesWarnAtErrorLevel() throws {
        let pipe = Pipe()
        let reporter = TranscribeEventReporter(minimumLevel: .error, handle: pipe.fileHandleForWriting)

        reporter.warning("hidden")
        reporter.error("error_event", message: "shown")
        pipe.fileHandleForWriting.closeFile()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(output.contains("WARN event=warning"), output)
        XCTAssertTrue(output.contains("ERROR event=error_event"), output)
    }

    func testReporterSuppressesStatusWhenDisabledButKeepsWarnings() throws {
        let pipe = Pipe()
        let reporter = TranscribeEventReporter(statusEnabled: false, handle: pipe.fileHandleForWriting)

        reporter.info("phase_done", message: "hidden")
        reporter.debug("debug_event", message: "hidden")
        reporter.warning("shown")
        pipe.fileHandleForWriting.closeFile()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(output.contains("phase_done"), output)
        XCTAssertFalse(output.contains("debug_event"), output)
        XCTAssertTrue(output.contains("WARN event=warning"), output)
        XCTAssertTrue(output.contains("message=shown"), output)
    }

    func testReporterSendsTuiDiagnosticsForNonInfoOnly() throws {
        let pipe = Pipe()
        var diagnostics: [TranscribeEvent] = []
        let reporter = TranscribeEventReporter(
            statusEnabled: false,
            minimumLevel: .debug,
            handle: pipe.fileHandleForWriting,
            textOutputEnabled: false,
            diagnosticsSink: { event in diagnostics.append(event) }
        )

        reporter.info("phase_done", message: "hidden")
        reporter.debug("verbose", message: "shown")
        reporter.warning("warned")
        reporter.error("run_failed", message: "failed")
        pipe.fileHandleForWriting.closeFile()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(output, "")
        XCTAssertEqual(diagnostics.map(\.level), [.debug, .warn, .error])
        XCTAssertEqual(diagnostics.map(\.name), ["verbose", "warning", "run_failed"])
    }

    func testReporterAppliesMinimumLevelToDiagnostics() throws {
        var warnDiagnostics: [TranscribeEvent] = []
        let warnReporter = TranscribeEventReporter(
            statusEnabled: false,
            minimumLevel: .warn,
            handle: Pipe().fileHandleForWriting,
            textOutputEnabled: false,
            diagnosticsSink: { event in warnDiagnostics.append(event) }
        )

        warnReporter.debug("verbose", message: "hidden")
        warnReporter.warning("shown")
        warnReporter.error("run_failed", message: "also shown")

        XCTAssertEqual(warnDiagnostics.map(\.level), [.warn, .error])

        var errorDiagnostics: [TranscribeEvent] = []
        let errorReporter = TranscribeEventReporter(
            statusEnabled: false,
            minimumLevel: .error,
            handle: Pipe().fileHandleForWriting,
            textOutputEnabled: false,
            diagnosticsSink: { event in errorDiagnostics.append(event) }
        )

        errorReporter.warning("hidden")
        errorReporter.error("run_failed", message: "shown")

        XCTAssertEqual(errorDiagnostics.map(\.level), [.error])
    }
}
