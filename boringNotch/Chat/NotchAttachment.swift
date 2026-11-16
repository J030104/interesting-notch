import Foundation
import UniformTypeIdentifiers

enum NotchAttachment: Sendable {
    case screenshot(Data)
    case file(URL)

    init?(fileURL: URL) {
        guard fileURL.isFileURL else { return nil }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        if let screenshot = NotchScreenshot.encodeFile(fileURL, size: values.fileSize) {
            self = .screenshot(screenshot)
        } else {
            self = .file(fileURL)
        }
    }

    static func load(_ provider: NSItemProvider, completion: @escaping @Sendable (Self?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                completion(url.flatMap { Self(fileURL: $0) })
            }
        } else {
            let imageType = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
            provider.loadDataRepresentation(forTypeIdentifier: imageType ?? UTType.image.identifier) { data, _ in
                completion(data.flatMap(NotchScreenshot.encode).map(Self.screenshot))
            }
        }
    }
}
