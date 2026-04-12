import Foundation

let validOutputFormats: Set<String> = ["txt", "json", "srt", "vtt", "md"]

func parseOutputFormats(_ format: String) -> [String] {
    let trimmed = format.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "all" {
        return ["txt", "json", "srt", "vtt", "md"]
    }

    var seen: Set<String> = []
    var formats: [String] = []
    for candidate in trimmed.split(separator: ",") {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, seen.insert(value).inserted else { continue }
        formats.append(value)
    }
    return formats
}
