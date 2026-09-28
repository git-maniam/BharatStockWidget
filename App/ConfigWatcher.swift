import Dispatch
import Foundation

/// Watches `config.json` and reports a change within about a second of a save (§4).
///
/// Re-arms after every event rather than watching a single file descriptor for its lifetime,
/// because the config is written atomically: the file the user saves is a *new* inode that replaces
/// the old one, so a descriptor-based watch would go deaf after the first edit. Editors that write
/// via a temp-file-and-rename dance — which is most of them — would otherwise be invisible.
/// `@unchecked Sendable` because every mutable property below is touched only from `queue`.
/// The public methods do nothing but hop onto it, which is what makes that true by construction.
final class ConfigWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.ravisubramaniam.bharatstockwidget.configwatch")

    private var source: (any DispatchSourceFileSystemObject)?
    private var descriptor: Int32 = -1
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in self?.arm() }
    }

    func stop() {
        queue.async { [weak self] in self?.disarm() }
    }

    deinit {
        // `cancel` closes the descriptor via the cancel handler.
        source?.cancel()
    }

    // MARK: - Private

    private func arm() {
        disarm()

        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The file does not exist yet. Poll gently until it does; this only happens before
            // first-run setup has completed.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        let descriptor = self.descriptor

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            notifyDebounced()
            // A rename or delete means our descriptor now points at an orphan; watch the new file.
            if events.contains(.rename) || events.contains(.delete) {
                queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.arm() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func disarm() {
        source?.cancel()  // closes the descriptor
        source = nil
        descriptor = -1
    }

    /// Coalesces the burst of events a single save produces into one callback.
    private func notifyDebounced() {
        debounce?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
