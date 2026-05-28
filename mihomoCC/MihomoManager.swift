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

    var showLogLink: Bool {
        if case .commandFailed = self { return true }
        return false
    }
}

// MARK: - Manager

class MihomoManager: ObservableObject {

    static let ctlPath = "/usr/local/bin/mihomo-ctl"

    // ── Published state ───────────────────────────────────────────────────────
    @Published var isRunning   = false
    @Published var pid: Int?   = nil
    @Published var errorState: MihomoErrorState = .none
    @Published var configChanged = false
    @Published var hasWebUI    = false
    @Published var webUIURL: URL? = nil

    // Runtime mode — populated by parsing cmd_status output
    @Published var tunActive   = false
    @Published var tunStack    = ""
    @Published var proxyActive = false
    @Published var proxyPort   = ""
    @Published var proxyType   = ""

    // Profiles — activeProfile has a didSet so the file watcher repoints
    // to the new yaml whenever the selection changes.
    @Published var profiles: [String] = []
    @Published var activeProfile: String? = nil {
        didSet {
            guard activeProfile != oldValue else { return }
            updateProfileFileWatcher()
        }
    }

    @Published var noDns: Bool {
        didSet { UserDefaults.standard.set(noDns,     forKey: "noDns") }
    }
    @Published var showSpeed: Bool {
        didSet { UserDefaults.standard.set(showSpeed, forKey: "showSpeed") }
    }

    // ── Private ────────────────────────────────────────────────────────────────
    private var configWatcher: ConfigWatcher?       // watches config.yaml for loadConfig()
    private var profileDirWatcher: ConfigWatcher?   // watches user-profiles/ for list changes
    private var profileFileWatcher: ConfigWatcher?  // watches the active profile yaml for edits
    private var configMtimeAtStart: Date?
    private var statusTimer: Timer?

    var cfgDir:      String { "\(NSHomeDirectory())/.config/mihomo" }
    var cfgFile:     String { "\(cfgDir)/config.yaml" }
    var profilesDir: String { "\(cfgDir)/user-profiles" }
    private var activeMarker: String { "\(profilesDir)/.active" }

    // MARK: Init

    init() {
        noDns     = UserDefaults.standard.bool(forKey: "noDns")
        showSpeed = UserDefaults.standard.object(forKey: "showSpeed") as? Bool ?? true
        ensureDirectories()
        setupPolling()
        setupConfigWatcher()
        setupProfileDirWatcher()
        loadProfiles()
        detectActiveProfile()
    }

    // MARK: - Directory management

    /// Creates ~/.config/mihomo and user-profiles/ if either is missing.
    /// Called on init and from the polling timer so deleted dirs are recreated.
    func ensureDirectories() {
        let fm = FileManager.default
        var profilesDirRecreated = false

        for dir in [cfgDir, profilesDir] {
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if dir == profilesDir { profilesDirRecreated = true }
            }
        }

        // If user-profiles was just recreated, restart the dir watcher and refresh
        if profilesDirRecreated {
            setupProfileDirWatcher()
            loadProfiles()
        }
    }

    // MARK: - Toggle / start / stop / restart

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard binaryOK() else { return }
        if let profile = activeProfile { copyProfile(profile) }

        var args = [Self.ctlPath, "start"]
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
                    self?.clearModeState()
                } else {
                    self?.errorState = .commandFailed("Failed to stop Mihomo — check log.")
                }
            }
        }
    }

    func restart() {
        guard binaryOK() else { return }
        if let profile = activeProfile { copyProfile(profile) }

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

    // MARK: - Profiles

    func loadProfiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else {
            profiles = []
            return
        }
        profiles = files
            .filter { $0.hasSuffix(".yaml") && !$0.hasPrefix(".") }
            .map    { String($0.dropLast(5)) }
            .sorted()
    }

    func detectActiveProfile() {
        guard
            let name = try? String(contentsOfFile: activeMarker, encoding: .utf8)
                                .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty,
            FileManager.default.fileExists(atPath: "\(profilesDir)/\(name).yaml")
        else {
            activeProfile = nil
            return
        }
        activeProfile = name
    }

    /// Copies the profile to config.yaml, writes .active, then prompts to
    /// restart if Mihomo is running.
    func switchProfile(_ name: String) {
        guard name != activeProfile else { return }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(profilesDir)/\(name).yaml"))
            try data.write(to: URL(fileURLWithPath: cfgFile))
            try name.write(toFile: activeMarker, atomically: true, encoding: .utf8)
        } catch {
            errorState = .commandFailed("Failed to switch profile — check log.")
            return
        }

        activeProfile = name   // triggers updateProfileFileWatcher via didSet
        configChanged = false
        loadConfig()

        guard isRunning else { return }

        let alert = NSAlert()
        alert.messageText     = "Restart Mihomo?"
        alert.informativeText = "Profile \"\(name)\" loaded. Restart Mihomo to apply it?"
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { restart() }
    }

    /// Re-copies the active profile to config.yaml and refreshes UI state.
    /// Does not prompt for restart — the user did this intentionally.
    func reloadProfile() {
        guard let profile = activeProfile else { return }
        copyProfile(profile)
        loadConfig()
        configChanged = false
    }

    // MARK: - Open helpers

    /// Opens the active profile yaml in TextEdit (falls back to config.yaml
    /// if no profile is selected).
    func openConfig() {
        let target: String
        if let profile = activeProfile {
            target = "\(profilesDir)/\(profile).yaml"
        } else {
            target = cfgFile
        }
        openInTextEdit(URL(fileURLWithPath: target))
    }

    func openProfileFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: profilesDir))
    }

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/mihomo.log"))
    }

    func openWebUI() {
        guard let url = webUIURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func openInTextEdit(_ url: URL) {
        if let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
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
        if output.contains("running") {
            isRunning = true
            if let r = output.range(of: #"PID (\d+)"#, options: .regularExpression) {
                let token = String(output[r])
                pid = token.components(separatedBy: " ").last.flatMap(Int.init)
            }
        } else {
            isRunning = false; pid = nil
            clearModeState()
            return
        }

        if let r = output.range(of: #"tun\s+:\s+\S+"#, options: .regularExpression) {
            let line = String(output[r])
            tunActive = line.contains("active") && !line.contains("inactive")
            if tunActive,
               let sr = output.range(of: #"stack: \w+"#, options: .regularExpression) {
                tunStack = String(output[sr]).components(separatedBy: ": ").last ?? ""
            } else {
                tunStack = ""
            }
        }

        if let r = output.range(of: #"proxy\s+:.*"#, options: .regularExpression) {
            let line = String(output[r])
            if line.contains("off") {
                proxyActive = false; proxyPort = ""; proxyType = ""
            } else {
                proxyActive = true
                if let pr = line.range(of: #":\d+"#, options: .regularExpression) {
                    proxyPort = String(String(line[pr]).dropFirst())
                }
                if let tr = line.range(of: #"\(\w+\)"#, options: .regularExpression) {
                    let raw = String(line[tr])
                    proxyType = String(raw.dropFirst().dropLast())
                }
            }
        }
    }

    private func clearModeState() {
        tunActive = false; tunStack = ""
        proxyActive = false; proxyPort = ""; proxyType = ""
    }

    // MARK: - Config

    func loadConfig() {
        guard let content = try? String(contentsOfFile: cfgFile, encoding: .utf8) else {
            hasWebUI = false; webUIURL = nil
            return
        }
        hasWebUI = content.contains("external-ui:")
        if let r = content.range(of: #"external-controller:\s*['\"]?[^:]+:(\d+)"#,
                                  options: .regularExpression) {
            let line = String(content[r])
            if let pr = line.range(of: #"\d+$"#, options: .regularExpression) {
                webUIURL = URL(string: "http://127.0.0.1:\(String(line[pr]))/ui")
            }
        } else {
            webUIURL = nil
        }
    }

    // MARK: - Change detection

    private func recordMtime() { configMtimeAtStart = fileMtime(cfgFile) }

    private func fileMtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - Polling + watchers

    private func setupPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.ensureDirectories()   // recreate dirs if deleted
            self?.refreshStatus()
        }
    }

    /// Watches config.yaml only for UI metadata (web UI detection).
    /// configChanged is no longer set here — the profile file watcher handles that.
    private func setupConfigWatcher() {
        configWatcher = ConfigWatcher(path: cfgFile) { [weak self] in
            DispatchQueue.main.async { self?.loadConfig() }
        }
    }

    /// Watches user-profiles/ for additions and removals so the picker stays fresh.
    private func setupProfileDirWatcher() {
        profileDirWatcher = ConfigWatcher(path: profilesDir) { [weak self] in
            DispatchQueue.main.async {
                self?.loadProfiles()
                self?.detectActiveProfile()
            }
        }
    }

    /// Points the profile file watcher at the currently selected yaml.
    /// Cancels the old watcher automatically (ConfigWatcher.deinit cancels).
    private func updateProfileFileWatcher() {
        profileFileWatcher = nil    // cancel previous
        guard let profile = activeProfile else { return }
        let path = "\(profilesDir)/\(profile).yaml"
        profileFileWatcher = ConfigWatcher(path: path) { [weak self] in
            DispatchQueue.main.async {
                guard let self, let current = self.activeProfile else { return }
                // Auto-sync the edited profile yaml into config.yaml
                self.copyProfile(current)
                self.loadConfig()
                // Only show the restart banner if Mihomo is actually running
                if self.isRunning { self.configChanged = true }
            }
        }
    }

    /// Copies the named profile yaml to config.yaml silently.
    private func copyProfile(_ name: String) {
        let src = "\(profilesDir)/\(name).yaml"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: src)) else { return }
        try? data.write(to: URL(fileURLWithPath: cfgFile))
    }

    // MARK: - Helpers

    @discardableResult
    private func binaryOK() -> Bool {
        guard FileManager.default.fileExists(atPath: Self.ctlPath) else {
            errorState = .binaryNotFound; return false
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
        do { try task.run() } catch { completion(false, error.localizedDescription) }
    }
}
