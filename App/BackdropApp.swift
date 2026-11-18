import AppKit
import SwiftUI

final class AppModel {
    static let shared = AppModel()
    let pipeline = Pipeline()
    let library = BackgroundLibrary()
    let installer = ExtensionInstaller()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.pipeline.start()
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            Snapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if CommandLine.arguments.contains("--install") {
            AppModel.shared.installer.install()
        }
    }
}

@main
struct BackdropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var pipeline = AppModel.shared.pipeline

    var body: some Scene {
        MenuBarExtra {
            PanelView(pipeline: AppModel.shared.pipeline, library: AppModel.shared.library, installer: AppModel.shared.installer)
        } label: {
            Image(systemName: pipeline.effectOn ? "person.and.background.dotted" : "person.crop.rectangle")
                .accessibilityLabel("Backdrop")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(pipeline: AppModel.shared.pipeline, installer: AppModel.shared.installer)
        }
    }
}
