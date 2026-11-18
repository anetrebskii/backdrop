import AppKit
import SystemExtensions

final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case idle, working, needsApproval, needsRestart
        case failed(String)
    }

    static let identifier = "com.anetrebskii.backdrop.camera"

    @Published var state: State = .idle

    func install() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            state = .failed("Move Backdrop to the Applications folder, then try again.")
            return
        }
        submit(.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main))
    }

    func uninstall() {
        submit(.deactivationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main))
    }

    func openApprovalSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        state = .working
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .needsApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        state = result == .completed ? .idle : .needsRestart
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        state = .failed(error.localizedDescription)
    }
}
