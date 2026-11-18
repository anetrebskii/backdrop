import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PanelView: View {
    @ObservedObject var pipeline: Pipeline
    @ObservedObject var library: BackgroundLibrary
    @ObservedObject var installer: ExtensionInstaller
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Replace background").font(.headline)
                Spacer()
                Toggle("Replace background", isOn: $pipeline.effectOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            PreviewView(pipeline: pipeline)
            HStack {
                Text("Camera")
                Spacer()
                if pipeline.cameras.isEmpty {
                    Text("No camera found").foregroundStyle(.secondary)
                } else {
                    Picker("Camera", selection: $pipeline.cameraID) {
                        ForEach(pipeline.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            HStack {
                Text("Background")
                    .foregroundStyle(pipeline.effectOn ? .primary : .secondary)
                Spacer()
                Picker("Background", selection: $pipeline.style) {
                    ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!pipeline.effectOn)
            if pipeline.style == .image {
                BackgroundGrid(pipeline: pipeline, library: library)
                    .disabled(!pipeline.effectOn)
                    .opacity(pipeline.effectOn ? 1 : 0.5)
            }
            Divider()
            CameraStatusRow(pipeline: pipeline, installer: installer)
            Divider()
            HStack(spacing: 4) {
                Button {
                    dismiss()
                    showSettings()
                } label: {
                    Label("Settings...", systemImage: "gearshape")
                }
                .keyboardShortcut(",")
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Backdrop", systemImage: "power")
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320)
    }
}

extension PanelView {
    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?.makeKeyAndOrderFront(nil)
        }
    }
}

struct PreviewView: View {
    @ObservedObject var pipeline: Pipeline

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
            if let image = pipeline.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if pipeline.preview != nil, !pipeline.stats.isEmpty {
                Text(pipeline.stats)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Preview of Backdrop Camera")
    }

    @ViewBuilder private var placeholder: some View {
        switch pipeline.cameraState {
        case .starting, .running:
            ProgressView { Text("Starting camera...").foregroundStyle(.white.opacity(0.8)) }
                .controlSize(.small)
        case .noCamera:
            Text("No camera found.\nConnect your iPhone or a camera.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
        case .denied:
            VStack(spacing: 8) {
                Text("Backdrop needs camera access.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                Button("Open Privacy Settings", action: pipeline.openPrivacySettings)
                    .controlSize(.small)
            }
        }
    }
}

struct BackgroundGrid: View {
    @ObservedObject var pipeline: Pipeline
    @ObservedObject var library: BackgroundLibrary

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(library.items) { item in
                    Button {
                        pipeline.backgroundURL = item.url
                    } label: {
                        Thumbnail(image: item.thumbnail, selected: pipeline.backgroundURL == item.url)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.url.deletingPathExtension().lastPathComponent)
                    .accessibilityAddTraits(pipeline.backgroundURL == item.url ? .isSelected : [])
                    .contextMenu {
                        Button("Remove") {
                            if pipeline.backgroundURL == item.url { pipeline.backgroundURL = nil }
                            library.remove(item)
                        }
                    }
                }
                Button(action: addImage) {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a background image")
                .help("Add a background image")
            }
            if library.items.isEmpty {
                Text("Add a background image")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a background image"
        let movies = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/backgrounds")
        if FileManager.default.fileExists(atPath: movies.path) { panel.directoryURL = movies }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let copied = library.add(url) {
            pipeline.backgroundURL = copied
        }
    }
}

struct Thumbnail: View {
    let image: CGImage?
    let selected: Bool

    var body: some View {
        Color.secondary.opacity(0.2)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1)
            }
            .contentShape(Rectangle())
    }
}

struct CameraStatusRow: View {
    @ObservedObject var pipeline: Pipeline
    @ObservedObject var installer: ExtensionInstaller

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(pipeline.virtualCameraConnected ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            action.controlSize(.small)
        }
    }

    private var title: String {
        if pipeline.virtualCameraConnected { return "Backdrop Camera is ready" }
        return installer.state == .needsApproval ? "Approve Backdrop Camera" : "Backdrop Camera is not installed"
    }

    private var detail: String {
        if pipeline.virtualCameraConnected { return "Choose it as the camera in your video app." }
        switch installer.state {
        case .working: return "Installing..."
        case .needsApproval: return "Allow Backdrop in System Settings > General > Login Items & Extensions."
        case .needsRestart: return "Restart your Mac to finish installing."
        case .failed(let message): return message
        case .idle: return "Install it to use Backdrop in video apps."
        }
    }

    @ViewBuilder private var action: some View {
        if pipeline.virtualCameraConnected {
            EmptyView()
        } else if installer.state == .needsApproval {
            Button("Open", action: installer.openApprovalSettings)
        } else if installer.state == .working {
            ProgressView().controlSize(.small)
        } else {
            Button("Install", action: installer.install).buttonStyle(.borderedProminent)
        }
    }
}
