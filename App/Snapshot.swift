import AppKit
import SwiftUI

enum Snapshot {
    static func run(into dir: URL) {
        Task { @MainActor in
            let model = AppModel.shared
            let pipeline = model.pipeline
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var log: [String] = []

            func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            func shootPanel(_ name: String) async {
                for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    await render(PanelView(pipeline: pipeline, library: model.library, installer: model.installer), to: dir.appendingPathComponent("\(name)-\(suffix).png"), appearance: appearance)
                }
            }

            await wait(3)
            pipeline.effectOn = false
            await wait(1)
            pipeline.snapshotOutput(to: dir.appendingPathComponent("out-off.png"))
            log.append("off: \(pipeline.stats)")
            await shootPanel("panel-off")

            pipeline.effectOn = true
            pipeline.style = .blur
            await wait(2)
            pipeline.snapshotOutput(to: dir.appendingPathComponent("out-blur.png"))
            log.append("blur accurate: \(pipeline.stats)")
            await shootPanel("panel-blur")

            pipeline.style = .image
            await wait(0.5)
            await shootPanel("panel-image-empty")
            for path in (ProcessInfo.processInfo.environment["BACKDROP_ADD"] ?? "").split(separator: ":") {
                if let copied = model.library.add(URL(fileURLWithPath: String(path))) { pipeline.backgroundURL = copied }
            }
            await wait(2)
            pipeline.snapshotOutput(to: dir.appendingPathComponent("out-image.png"))
            log.append("image accurate: \(pipeline.stats)")
            log.append("library: \(model.library.items.map(\.url.lastPathComponent)) selected: \(pipeline.backgroundURL?.lastPathComponent ?? "none")")
            await shootPanel("panel-image")
            pipeline.imageBlur = 0.5
            await wait(1)
            pipeline.snapshotOutput(to: dir.appendingPathComponent("out-image-blur.png"))
            await shootPanel("panel-image-blur")
            pipeline.systemBackgroundOn = true
            await shootPanel("panel-system-background")
            pipeline.imageBlur = 0

            for quality in [SegmentationQuality.balanced, .fast] {
                pipeline.quality = quality
                await wait(2)
                log.append("image \(quality.rawValue): \(pipeline.stats)")
            }
            pipeline.quality = .accurate

            model.installer.state = .needsApproval
            await shootPanel("panel-approval")
            model.installer.state = .idle

            for tab in [SettingsTab.general, .effect, .camera] {
                for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    await render(SettingsView(pipeline: pipeline, installer: model.installer, tab: tab), to: dir.appendingPathComponent("settings-\(tab)-\(suffix).png"), appearance: appearance)
                }
            }

            pipeline.stopForSnapshot(state: .denied)
            await wait(0.5)
            await shootPanel("panel-denied")
            pipeline.stopForSnapshot(state: .noCamera)
            await wait(0.3)
            await shootPanel("panel-nocamera")

            try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, to url: URL, appearance: NSAppearance.Name) async {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 400_000_000)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
