import Foundation

/// One Raycast import as the Backup pane and onboarding both run it: file, passphrase, outcome.
@MainActor
@Observable
final class RaycastImportSession {
    enum Status {
        case success(String)
        case failure(String)
    }

    var passphrase = ""
    var selection: RaycastImportOptions = .all
    private(set) var file: URL?
    private(set) var isRaycastExport = false
    private(set) var importing = false
    private(set) var status: Status?

    var canImport: Bool {
        isRaycastExport && !passphrase.isEmpty && !selection.isEmpty && !importing
    }

    var didImport: Bool {
        if case .success = status { return true }
        return false
    }

    func fileSubtitle(placeholder: String) -> String {
        guard let name = file?.lastPathComponent else { return placeholder }
        return "\(name) — \(isRaycastExport ? "Raycast export" : "not a Raycast export")"
    }

    func chooseFile() {
        guard let url = BackupActions.pickRaycastFile() else { return }
        file = url
        isRaycastExport = BackupActions.isRaycastExport(url)
        status = nil
    }

    func run(core: AppCore) {
        guard canImport, let file else { return }
        importing = true
        status = nil
        Task {
            defer { importing = false }
            do {
                let outcome = try await BackupActions.importRaycast(
                    core: core, file: file, passphrase: passphrase, options: selection)
                status = .success(BackupActions.raycastText(outcome))
                passphrase = ""
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }
}
