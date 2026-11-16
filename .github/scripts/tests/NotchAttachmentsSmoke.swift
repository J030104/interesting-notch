import Foundation

@main
enum NotchAttachmentsSmoke {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hello world.txt")
        try Data("Example attachment".utf8).write(to: file)

        guard case .file(let fileURL)? = NotchAttachment(fileURL: file) else {
            fatalError("The composer cannot attach a text file.")
        }
        precondition(NotchAttachment(fileURL: directory) == nil, "Directories should be rejected.")

        let input = NotchComposerInput(files: [fileURL])
        precondition(!input.isEmpty, "A file-only draft should be sendable.")
        let items = try input.turnItems()
        guard items.count == 1, items[0]["type"] as? String == "text",
              let text = items[0]["text"] as? String, let jsonStart = text.firstIndex(of: "[") else {
            fatalError("Expected a text input with attachment paths.")
        }
        let paths = try JSONDecoder().decode([String].self, from: Data(text[jsonStart...].utf8))
        precondition(paths == [file.path(percentEncoded: false)], "Codex received an incorrect attachment path.")
        print("A file-only draft keeps its path and produces a Codex text input.")
    }
}
