import Foundation
import AppKit

final class PrivilegeManager {
    static let shared = PrivilegeManager()

    private let installPath = "/usr/local/bin/mihomo-ctl"
    private let sudoersPath = "/etc/sudoers.d/mihomo-ctl"

    private var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installPath)
    }
    private var hasSudoers: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    // MARK: - Setup

    func runSetupIfNeeded(completion: @escaping () -> Void) {
        guard !isInstalled || !hasSudoers else { completion(); return }

        let alert = NSAlert()
        alert.messageText     = "One-time Setup Required"
        alert.informativeText = """
            mihomoCC needs to:
            \u{2022} Install mihomo-ctl to /usr/local/bin/
            \u{2022} Add a sudoers rule so it can start/stop Mihomo without asking for your password each time.

            You'll be prompted for your admin password once.
            """
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runScript(makeInstallScript()) { success in
            if success {
                completion()
            } else {
                self.showError("Could not complete setup. Try relaunching the app, or install mihomo-ctl manually.")
            }
        }
    }

    // MARK: - Uninstall

    func uninstall() {
        let alert = NSAlert()
        alert.messageText     = "Uninstall mihomoCC?"
        alert.informativeText = "This will remove /usr/local/bin/mihomo-ctl and its sudoers entry, then quit the app."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let cmd = """
            #!/bin/sh
            rm -f "\(installPath)"
            rm -f "\(sudoersPath)"
            """

        runScript(cmd) { success in
            if success {
                NSApplication.shared.terminate(nil)
            } else {
                self.showError("Uninstall failed. You can remove the files manually:\n  sudo rm \(self.installPath) \(self.sudoersPath)")
            }
        }
    }

    // MARK: - Helpers

    private func makeInstallScript() -> String {
        guard let bundled = Bundle.main.path(forResource: "mihomo-ctl", ofType: nil) else {
            return "#!/bin/sh\nexit 1"
        }
        let rule = "%admin ALL=(ALL) NOPASSWD: \(installPath)"
        return """
            #!/bin/sh
            mkdir -p /usr/local/bin
            install -m 755 "\(bundled)" "\(installPath)"
            printf '%s\\n' "\(rule)" > "\(sudoersPath)"
            chmod 440 "\(sudoersPath)"
            """
    }

    /// Writes the script to a temp file and executes it with an admin prompt.
    private func runScript(_ body: String, completion: @escaping (Bool) -> Void) {
        let tmpPath = NSTemporaryDirectory() + "mihomo-bar-script.sh"
        do {
            try body.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tmpPath
            )
        } catch {
            completion(false)
            return
        }

        let source = "do shell script \"\(tmpPath)\" with administrator privileges"
        var errorDict: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorDict)
        try? FileManager.default.removeItem(atPath: tmpPath)

        if let err = errorDict { print("AppleScript error:", err) }
        completion(errorDict == nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText     = "Error"
        alert.informativeText = message
        alert.alertStyle      = .warning
        alert.runModal()
    }
}
