import Foundation
import AppKit
import Combine

// MARK: - Error state

enum MihomoErrorState: Equatable {
    case none
    case binaryNotFound
    case commandFailed(String)

    var message: String? {
        switch self {
        case .none:                  return nil
        case .binaryNotFound:        return "Mihomo binary not found. Is mihomo installed and on PATH?"
        case .commandFailed(let m):  return m
        }
    }

    /// Whether to show the "Open Log" shortcut alongside the error.
    var showLogLink: Bool {
        if case .commandFailed = self { return true }
        return false
    }
}

// MARK: - Manager

class MihomoManager: ObservableObject {

    // Fixed path — PrivilegeManager installs the bundled script here on first launch.
    static let ctlPath = "/usr/local/bin/mihomo-ctl"

    // ── Published state ───────────────────────────────────────────────────────
    @Published var isRunning   = false
    @Published var pid: Int?   = nil
    @Published var errorState: MihomoErrorState = .none
    @Published var configChanged = false   // set by ConfigWatcher
    @Published var hasWebUI    = false
    @Published var webUIURL: URL? = nil

    @Published var noDns: Bool {
        didSet { UserDefaults.standard.set(noDns,      forKey: "noDns") }
    }
    @Published var showSpeed: Bool {
        didSet { UserDefaults.standard.set(showSpeed,  forKey: "showSpeed") }
    }

    // ── Private ────────────────────────────────────────────────────────────────
    private var configWatcher: ConfigWatcher?
    private var configMtimeAtStart: Date?
    private var statusTimer: Timer?

    var cfgDir:  String { "\(NSHomeDirectory())/.config/mihomo" }
    var cfgFile: String { "\(cfgDir)/config.yaml" }

    // MARK: Init

    init() {
        noDns     = UserDefaults.standard.bool(forKey: "noDns")
        showSpeed = UserDefaults.standard.object(forKey: "showSpeed") as? Bool ?? true
        setupPolling()
        setupWatcher()
    }

    // MARK: - Actions

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard binaryOK() else { return }
        var args = [Self.ctlPath, "start"]
        if noDns { args.append("-no-dns") }
        args.append(cfgDir)

        runSudo(args) { [weak self] ok, _ in
            DispatchQueue.main.async {
                if ok {
                    self?.errorState = .none
                    self?.recordMtime()
                    self?.configChanged = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.refreshStatus()
                    }
                } else {
                    self?.errorState = .commandFailed("Failed to start Mihomo — check log.")
                }
            }
        }
    }

    func stop() {
        guard binaryOK() else { return }
        runSudo([Self.ctlPath, "stop"]) { [weak self] ok, _ in
            DispatchQueue.main.async {
                if ok {
                    self?.errorState = .none
                    self?.isRunning  = false
                    self?.pid        = nil
                } else {
                    self?.errorState = .commandFailed("Failed to stop Mihomo — check log.")
                }
            }
        }
    }

    func restart() {
        guard binaryOK() else { return }
        var args = [Self.ctlPath, "restart"]
        if noDns { args.append("-no-dns") }
        args.append(cfgDir)

        runSudo(args) { [weak self] ok, _ in
            DispatchQueue.main.async {
                if ok {
                    self?.errorState    = .none
                    self?.configChanged = false
                    self?.recordMtime()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.refreshStatus()
                    }
                } else {
                    self?.errorState = .commandFailed("Failed to restart Mihomo — check log.")
                }
            }
        }
    }

    /// Re-reads config metadata on the app side. If the file changed since
    /// Mihomo was last started, prompts the user to restart.
    func reloadConfig() {
        loadConfig()
        guard isRunning, configChangedSinceStart() else { return }

        let alert = NSAlert()
        alert.messageText     = "Config Changed"
        alert.informativeText = "config.yaml has been modified since Mihomo was started. Restart to apply changes?"
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            restart()
        }
    }

    // MARK: - Open helpers

    func openLog() {
        // .log files open in Console.app by default
        NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/mihomo.log"))
    }

    func openConfig() {
        let url = URL(fileURLWithPath: cfgFile)
        if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openWebUI() {
        guard let url = webUIURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Status

    func refreshStatus() {
        guard FileManager.default.fileExists(atPath: Self.ctlPath) else {
            DispatchQueue.main.async { self.errorState = .binaryNotFound }
            return
        }
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments  = [Self.ctlPath, "status"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        task.terminationHandler = { [weak self] _ in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.parseStatus(out) }
        }
        try? task.run()
    }

    private func parseStatus(_ output: String) {
        // "status : running (PID 12345)" or "status : stopped"
        if output.contains("running") {
            isRunning = true
            if let r = output.range(of: #"PID (\d+)"#, options: .regularExpression) {
                let token = String(output[r])           // e.g. "PID 12345"
                pid = token.components(separatedBy: " ").last.flatMap(Int.init)
            }
        } else {
            isRunning = false
            pid = nil
        }
    }

    // MARK: - Config

    func loadConfig() {
        guard let content = try? String(contentsOfFile: cfgFile, encoding: .utf8) else {
            hasWebUI  = false
            webUIURL  = nil
            return
        }

        hasWebUI = content.contains("external-ui:")

        // Parse external-controller: '127.0.0.1:9090'
        if let r = content.range(of: #"external-controller:\s*['\"]?[^:]+:(\d+)"#,
                                  options: .regularExpression) {
            let line = String(content[r])
            if let portRange = line.range(of: #"\d+$"#, options: .regularExpression) {
                let port = String(line[portRange])
                webUIURL = URL(string: "http://127.0.0.1:\(port)/ui")
            }
        } else {
            webUIURL = nil
        }
    }

    // MARK: - Change detection

    private func recordMtime() {
        configMtimeAtStart = fileMtime(cfgFile)
    }

    private func configChangedSinceStart() -> Bool {
        guard let start = configMtimeAtStart,
              let now   = fileMtime(cfgFile) else { return false }
        return now > start
    }

    private func fileMtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - Polling + watching

    private func setupPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func setupWatcher() {
        configWatcher = ConfigWatcher(path: cfgFile) { [weak self] in
            DispatchQueue.main.async {
                self?.loadConfig()
                if self?.isRunning == true { self?.configChanged = true }
            }
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func binaryOK() -> Bool {
        guard FileManager.default.fileExists(atPath: Self.ctlPath) else {
            errorState = .binaryNotFound
            return false
        }
        return true
    }

    private func runSudo(_ args: [String], completion: @escaping (Bool, String) -> Void) {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments  = args
        let errPipe = Pipe()
        task.standardOutput    = Pipe()
        task.standardError     = errPipe
        task.terminationHandler = { t in
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            completion(t.terminationStatus == 0, err)
        }
        do { try task.run() } catch {
            completion(false, error.localizedDescription)
        }
    }
}
