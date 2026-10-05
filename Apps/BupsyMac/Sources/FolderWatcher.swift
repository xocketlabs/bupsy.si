import BupsyKit
import CoreServices
import Foundation

/// Watches one folder (recursively) with FSEvents and reports the paths that changed.
///
/// Changes arriving within `settle` seconds of each other are delivered together, so saving ten
/// files, or an app writing one file in several steps, is one run rather than ten.
@MainActor
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private var flush: Task<Void, Never>?
    private let settle: Duration
    private let onChange: @MainActor ([String]) -> Void

    init(path: String, settle: Duration = .seconds(4), onChange: @escaping @MainActor ([String]) -> Void) {
        self.settle = settle
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changed: [String] = []
            for index in 0..<count {
                let flag = Int(flags[index])
                // Directory housekeeping and Finder metadata are not "files changed".
                if flag & kFSEventStreamEventFlagItemIsDir != 0 { continue }
                let path = list[index]
                if (path as NSString).lastPathComponent.hasPrefix(".") { continue }
                changed.append(path)
            }
            MainActor.assumeIsolated { watcher.received(changed) }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        flush?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func received(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        pending.formUnion(paths)
        flush?.cancel()
        flush = Task { [weak self, settle] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, let self else { return }
            let batch = Array(self.pending)
            self.pending.removeAll()
            self.onChange(batch)
        }
    }
}
