import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var manager: MihomoManager
    @EnvironmentObject var speed: NetworkSpeedMonitor

    @State private var selectedProfile: String? = nil

    var body: some View {
        VStack(spacing: 0) {

            // ── On/off toggle + status ───────────────────────────────────
            VStack(spacing: 4) {
                Toggle("", isOn: Binding(
                    get: { manager.isRunning },
                    set: { _ in manager.toggle() }
                ))
                .toggleStyle(PillToggleStyle())
                .padding(.top, 14)

                StatusRow(running: manager.isRunning, pid: manager.pid)

                if manager.isRunning {
                    ModeRow(
                        tunActive:   manager.tunActive,
                        tunStack:    manager.tunStack,
                        proxyActive: manager.proxyActive,
                        proxyPort:   manager.proxyPort,
                        proxyType:   manager.proxyType
                    )
                }
            }
            .padding(.horizontal, 14)

            // ── Profile picker (always shown) ────────────────────────────
            Divider().padding(.vertical, 6)

            if manager.profiles.isEmpty {
                // No profiles — warn and offer to open the folder
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("No profiles found")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Open Folder") { manager.openProfileFolder() }
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 14)
            } else {
                HStack {
                    Text("Profile")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { selectedProfile ?? "" },
                        set: { selectedProfile = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(manager.profiles, id: \.self) { p in
                            Text(p).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 12))
                    .frame(maxWidth: 150)
                    .onChange(of: selectedProfile) { newVal in
                        guard let name = newVal, name != manager.activeProfile else { return }
                        manager.switchProfile(name)
                    }
                }
                .padding(.horizontal, 14)
            }

            Divider().padding(.vertical, 8)

            // ── Settings ─────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 7) {

                Toggle("No DNS Switching", isOn: $manager.noDns)
                    .font(.system(size: 12))
                    .disabled(manager.isRunning)
                    .help(manager.isRunning ? "Stop Mihomo before changing this" : "")
                    .padding(.horizontal, 14)

                Toggle("Speed in Menu Bar", isOn: $manager.showSpeed)
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)

                Divider().padding(.vertical, 1)

                // ── Button rows ───────────────────────────────────────────
                VStack(spacing: 4) {

                    // Row 1 — always present
                    HStack(spacing: 4) {
                        CtlButton("Log",    fullWidth: true) { manager.openLog()       }
                        CtlButton("Config", fullWidth: true) { manager.openConfig()    }
                        CtlButton("Reload", fullWidth: true) { manager.reloadProfile() }
                    }

                    // Row 2 — only when external-ui is detected
                    if manager.hasWebUI {
                        CtlButton("Open Web UI", fullWidth: true) { manager.openWebUI() }
                    }

                    // Row 3 — always present
                    CtlButton("Open Profile Folder", fullWidth: true) {
                        manager.openProfileFolder()
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 8)

            // ── Profile updated banner ───────────────────────────────────
            if manager.configChanged {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("Profile updated")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Restart") { manager.restart() }
                        .font(.system(size: 11))
                    Button {
                        manager.configChanged = false
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }

            // ── Error ────────────────────────────────────────────────────
            if let msg = manager.errorState.message {
                Divider()
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(msg)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                        if manager.errorState.showLogLink {
                            Button("Open Log") { manager.openLog() }
                                .font(.system(size: 11))
                                .buttonStyle(.plain)
                                .foregroundColor(.accentColor)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }

            // ── Footer ───────────────────────────────────────────────────
            Divider()
            HStack(spacing: 0) {
                footerButton("Uninstall", color: .red) {
                    PrivilegeManager.shared.uninstall()
                }
                Divider().frame(height: 16)
                footerButton("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 250)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { selectedProfile = manager.activeProfile }
        .onChange(of: manager.activeProfile) { selectedProfile = $0 }
    }

    private func footerButton(
        _ label: String,
        color: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sub-views

private struct StatusRow: View {
    let running: Bool
    let pid: Int?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(running ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Group {
                if running, let pid {
                    Text("Active · PID \(pid)")
                } else {
                    Text(running ? "Active" : "Inactive")
                }
            }
            .font(.system(size: 12))
            .foregroundColor(running ? .primary : .secondary)
        }
        .padding(.bottom, 2)
    }
}

private struct ModeRow: View {
    let tunActive:   Bool
    let tunStack:    String
    let proxyActive: Bool
    let proxyPort:   String
    let proxyType:   String

    var body: some View {
        HStack(spacing: 10) {
            if tunActive {
                modeTag(icon: "network",
                        text: "TUN" + (tunStack.isEmpty ? "" : " · \(tunStack)"))
            }
            if proxyActive {
                modeTag(icon: "arrow.triangle.2.circlepath",
                        text: ":\(proxyPort)" +
                              (proxyType.isEmpty || proxyType == "mixed" ? "" : " · \(proxyType)"))
            }
        }
        .padding(.bottom, 4)
    }

    private func modeTag(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10))
        }
        .foregroundColor(.secondary)
    }
}

private struct CtlButton: View {
    let title: String
    var fullWidth = false
    let action: () -> Void

    init(_ title: String, fullWidth: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.fullWidth = fullWidth; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(5)
        .buttonStyle(.plain)
    }
}

// MARK: - Toggle style

private struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(configuration.isOn
                          ? Color.accentColor
                          : Color.secondary.opacity(0.22))
                    .frame(width: 72, height: 32)
                Circle()
                    .fill(.white)
                    .shadow(radius: 1.5)
                    .frame(width: 24, height: 24)
                    .offset(x: configuration.isOn ? 18 : -18)
                    .animation(.spring(response: 0.22, dampingFraction: 0.8),
                               value: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
    }
}
