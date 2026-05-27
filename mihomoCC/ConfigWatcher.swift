import Foundation

/// Watches a single file for writes using a DispatchSource (no polling).
final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let callback: () -> Void

    init(path: String, callback: @escaping () -> Void) {
        self.callback = callback
        watch(path: path)
    }

    private func watch(path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }   // file doesn't exist yet — silent skip

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source?.setEventHandler  { [weak self] in self?.callback() }
        source?.setCancelHandler  { close(fd) }
        source?.resume()
    }

    deinit { source?.cancel() }
}
