import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable {
    case general, effect, camera
}

struct SettingsView: View {
    @ObservedObject var pipeline: Pipeline
    @ObservedObject var installer: ExtensionInstaller
    @State var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(pipeline: pipeline)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            EffectSettings(pipeline: pipeline)
                .tabItem { Label("Effect", systemImage: "person.and.background.dotted") }
                .tag(SettingsTab.effect)
            CameraSettings(pipeline: pipeline, installer: installer)
                .tabItem { Label("Camera", systemImage: "video") }
                .tag(SettingsTab.camera)
        }
        .frame(width: 460)
    }
}

struct GeneralSettings: View {
    @ObservedObject var pipeline: Pipeline
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                if pipeline.cameras.isEmpty {
                    LabeledContent("Camera", value: "No camera found")
                } else {
                    Picker("Camera", selection: $pipeline.cameraID) {
                        ForEach(pipeline.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                }
            } footer: {
                Text("The camera Backdrop reads from. Pick your iPhone to use it through Continuity Camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change this: \(error.localizedDescription)"
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct EffectSettings: View {
    @ObservedObject var pipeline: Pipeline

    var body: some View {
        Form {
            Section {
                Picker("Quality", selection: $pipeline.quality) {
                    ForEach(SegmentationQuality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Accurate gives the cleanest hair and edges and uses the most power.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Frame rate", selection: $pipeline.frameRate) {
                    Text("15 fps").tag(15)
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("A lower frame rate uses less power. Motion looks less smooth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Update edges", selection: $pipeline.maskInterval) {
                    Text("Every frame").tag(1)
                    Text("Every 2nd").tag(2)
                    Text("Every 3rd").tag(3)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Updating less often uses less power. Edges can lag behind when you move quickly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Slider(value: $pipeline.softness, in: 0...4) {
                    Text("Edge softness")
                } minimumValueLabel: {
                    Text("Sharp")
                } maximumValueLabel: {
                    Text("Soft")
                }
                Slider(value: $pipeline.blurStrength, in: 0...1) {
                    Text("Blur strength")
                } minimumValueLabel: {
                    Text("Light")
                } maximumValueLabel: {
                    Text("Strong")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CameraSettings: View {
    @ObservedObject var pipeline: Pipeline
    @ObservedObject var installer: ExtensionInstaller
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Backdrop Camera") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(pipeline.virtualCameraConnected ? Color.green : Color.secondary.opacity(0.6))
                            .frame(width: 8, height: 8)
                        Text(pipeline.virtualCameraConnected ? "Installed" : "Not installed")
                    }
                }
                HStack {
                    Spacer()
                    if pipeline.virtualCameraConnected {
                        Button("Uninstall...") { confirmUninstall = true }
                    } else if installer.state == .needsApproval {
                        Button("Open System Settings", action: installer.openApprovalSettings)
                    } else {
                        Button("Install", action: installer.install)
                            .buttonStyle(.borderedProminent)
                            .disabled(installer.state == .working)
                    }
                }
            } footer: {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Uninstall Backdrop Camera?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive, action: installer.uninstall)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Video apps using it will lose the picture.")
        }
    }

    private var footer: String {
        switch installer.state {
        case .needsApproval: return "Allow Backdrop in System Settings > General > Login Items & Extensions."
        case .needsRestart: return "Restart your Mac to finish."
        case .failed(let message): return message
        case .working: return "Working..."
        case .idle:
            return pipeline.virtualCameraConnected
                ? "Choose Backdrop Camera in Chrome, Meet, Zoom or FaceTime. Backdrop must be running for it to show a picture."
                : "Backdrop Camera is the camera video apps see. Install it once; macOS asks you to allow it."
        }
    }
}
