import AppKit
import ImageIO
import UniformTypeIdentifiers

struct BackgroundItem: Identifiable, Equatable {
    let url: URL
    let thumbnail: CGImage?
    var id: URL { url }
}

final class BackgroundLibrary: ObservableObject {
    @Published private(set) var items: [BackgroundItem] = []

    let folder: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["BACKDROP_LIBRARY"] {
            folder = URL(fileURLWithPath: override)
        } else {
            folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Backdrop/Backgrounds")
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        let images = urls
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            .sorted { creationDate($0) < creationDate($1) }
        items = images.map { BackgroundItem(url: $0, thumbnail: Self.thumbnail(for: $0)) }
    }

    func add(_ source: URL) -> URL? {
        var target = folder.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) \(counter).\(source.pathExtension)")
            counter += 1
        }
        guard (try? FileManager.default.copyItem(at: source, to: target)) != nil else { return nil }
        reload()
        return target
    }

    func remove(_ item: BackgroundItem) {
        NSWorkspace.shared.recycle([item.url]) { _, _ in
            DispatchQueue.main.async { self.reload() }
        }
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private static func thumbnail(for url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
