import AppKit
import SwiftUI
import Combine

private var speedCancellable: AnyCancellable?

// MARK: - Menu bar item view

struct StatusBarItemView: View {
    @ObservedObject var monitor: NetworkSpeedMonitor
    @ObservedObject var manager: MihomoManager

    // Adjust both this and statusItem.length in AppDelegate together.
    private let totalWidth: CGFloat = 100

    var body: some View {
        HStack(spacing: 13) {
            if manager.showSpeed {
                VStack(alignment: .leading, spacing: 0) {
                    speedRow(text: monitor.up)
                    speedRow(text: monitor.down)
                }
            }
            Image(systemName: manager.isRunning
                  ? "cube.fill"
                  : "cube")
                .font(.system(size: 13, weight: .bold))
                .opacity(manager.isRunning ? 1.0 : 0.4)
        }
        .fixedSize()                    // width follows content
        .padding(.horizontal, 4)
    }

    // Arrow sits in a fixed-width box so its position never drifts.
    // The value+unit field is right-aligned in a fixed-width box so only
    // the glyphs change — the arrow never moves as the number grows/shrinks.
    private func speedRow(text: String) -> some View {
        HStack(spacing: 2) {
            Text(text)
                .font(.system(size: 9, weight: .regular, design: .default))
                .frame(width: 53, alignment: .trailing) // value: right-aligned, fixed
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    let manager      = MihomoManager()
    let speedMonitor = NetworkSpeedMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let barView = StatusBarItemView(monitor: speedMonitor, manager: manager)
        let hosting = NSHostingView(rootView: barView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        if let button = statusItem.button {
            button.image = nil
            button.title = ""
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor .constraint(equalTo: button.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hosting.centerYAnchor .constraint(equalTo: button.centerYAnchor),
                hosting.heightAnchor  .constraint(equalTo: button.heightAnchor),
            ])
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView()
                .environmentObject(manager)
                .environmentObject(speedMonitor)
        )
        
        speedMonitor.start()
        
        speedCancellable = manager.$showSpeed
            .dropFirst()                    // skip the initial value on subscription
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }

        // Stop mihomo cleanly if the system shuts down or restarts while
        // the app is running. willPowerOffNotification fires as soon as the
        // user confirms shutdown/restart, giving us time to act before macOS
        // starts killing processes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        PrivilegeManager.shared.runSetupIfNeeded { [weak self] in
            self?.manager.refreshStatus()
            self?.manager.loadConfig()
        }
    }

    // Called on system shutdown / restart
    @objc private func systemWillPowerOff() {
        stopSync()
    }

    // Called when the app itself is quitting (Quit button, force-quit, etc.)
    func applicationWillTerminate(_ notification: Notification) {
        stopSync()
    }

    // Runs mihomo-ctl stop synchronously so DNS and proxies are restored
    // before we return control to the OS. waitUntilExit() blocks the
    // current thread — this is intentional; we must not return early.
    private func stopSync() {
        guard manager.isRunning else { return }
        let task = Process()
        task.launchPath    = "/usr/bin/sudo"
        task.arguments     = [MihomoManager.ctlPath, "stop"]
        task.standardOutput = Pipe()
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            manager.refreshStatus()
            manager.loadConfig()
            // Anchor to the icon's position at the trailing edge,
            // so the popover doesn't shift when speed monitor is toggled
            let iconRect = NSRect(
                x: button.bounds.width - 24,
                y: 0,
                width: 24,
                height: button.bounds.height
            )
            popover.show(relativeTo: iconRect, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
