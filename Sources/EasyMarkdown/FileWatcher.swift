import CoreServices
import Foundation

/// Watches a single file for changes using FSEvents on its parent directory.
///
/// Watching the directory (rather than the file descriptor) survives editors that save
/// atomically by writing a temp file and renaming it over the original, which is what
/// Neovim and most other editors do by default.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let watchedPath: String
    private let onChange: () -> Void

    init?(url: URL, onChange: @escaping () -> Void) {
        let directory = Self.realPath(url.deletingLastPathComponent().path)
        watchedPath = (directory as NSString).appendingPathComponent(url.lastPathComponent)
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // Case-insensitive: APFS is usually case-insensitive and FSEvents reports on-disk case.
            if changed.contains(where: { $0.caseInsensitiveCompare(watcher.watchedPath) == .orderedSame }) {
                watcher.onChange()
            }
        }

        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, FSEventStreamCreateFlags(flags))
        else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// FSEvents reports fully resolved paths (e.g. /private/tmp rather than /tmp).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
