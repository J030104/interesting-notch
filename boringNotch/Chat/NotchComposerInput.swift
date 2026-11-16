import Foundation

struct NotchComposerInput {
    var prompt = ""
    var screenshots: [Data] = []
    var files: [URL] = []

    var isEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && screenshots.isEmpty && files.isEmpty
    }

    var question: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if !files.isEmpty {
            return files.count + screenshots.count == 1 ? "Please summarize the attached file." : "Please summarize the attachments."
        }
        return screenshots.count == 1 ? "Please explain this screenshot." : "Please explain these screenshots."
    }

    func turnItems() throws -> [[String: Any]] {
        var text = question
        if !files.isEmpty {
            // The local app server takes images directly and reads other files from disk.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let paths = try encoder.encode(files.map { $0.path(percentEncoded: false) })
            text += "\n\nRead these local file attachments when answering:\n" + String(decoding: paths, as: UTF8.self)
        }
        return [["type": "text", "text": text]] + screenshots.map {
            ["type": "image", "url": "data:image/png;base64," + $0.base64EncodedString()]
        }
    }
}
