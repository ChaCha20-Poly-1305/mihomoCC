import Foundation
import Combine

class NetworkSpeedMonitor: ObservableObject {
    @Published var up   = "0 B/s"
    @Published var down = "0 B/s"

    private var timer: Timer?
    private var lastTx: UInt64 = 0
    private var lastRx: UInt64 = 0

    func start() {
        // Seed baseline silently so first tick shows real delta
        let (tx, rx) = readBytes()
        lastTx = tx; lastRx = rx

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        DispatchQueue.main.async {
            self.up = "0 B/s"; self.down = "0 B/s"
        }
    }

    private func tick() {
        let (tx, rx)  = readBytes()
        let upDelta   = tx > lastTx ? tx - lastTx : 0
        let downDelta = rx > lastRx ? rx - lastRx : 0
        lastTx = tx; lastRx = rx
        DispatchQueue.main.async {
            self.up   = Self.fmt(upDelta)
            self.down = Self.fmt(downDelta)
        }
    }

    /// Reads cumulative bytes from all non-loopback link-layer interfaces.
    /// Filtering for <Link#...> rows avoids double-counting IPv4/IPv6 entries.
    private func readBytes() -> (tx: UInt64, rx: UInt64) {
        let task = Process()
        task.launchPath = "/usr/sbin/netstat"
        task.arguments  = ["-ib"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        guard (try? task.run()) != nil else { return (0, 0) }
        task.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""

        // netstat -ib columns:
        // Name  Mtu  Network  Address  Ipkts  Ierrs  Ibytes  Opkts  Oerrs  Obytes  Coll
        //  [0]  [1]   [2]     [3]      [4]    [5]    [6]     [7]    [8]    [9]    [10]
        var tx: UInt64 = 0
        var rx: UInt64 = 0

        for line in output.components(separatedBy: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 10          else { continue }
            guard cols[2].hasPrefix("<Link#") else { continue } // link layer only
            guard !cols[0].hasPrefix("lo")   else { continue } // skip loopback
            guard let ibytes = UInt64(cols[6]),
                  let obytes = UInt64(cols[9]) else { continue }
            rx += ibytes
            tx += obytes
        }
        return (tx, rx)
    }

    private static func fmt(_ b: UInt64) -> String {
        switch b {
        case ..<1_024:
            return "\(b) B/s"
        case ..<(1_024 * 1_024):
            return String(format: "%.1f KB/s", Double(b) / 1_024)
        case ..<(1_024 * 1_024 * 1_024):
            return String(format: "%.1f MB/s", Double(b) / (1_024 * 1_024))
        default:
            return String(format: "%.1f GB/s", Double(b) / (1_024 * 1_024 * 1_024))
        }
    }

    deinit { stop() }
}
