import BupsyKit
import CoreServices
import Foundation

/// Watches one folder (recursively) with FSEvents and reports the paths that changed.
///
/// Changes arriving within `settle` seconds of each other are delivered together, so saving ten
/// files, or an app writing one file in several steps, is one run rather than ten.
@MainActor
final class FolderWatcher {
    /// At most this many deliveries in any hour. A watch whose bot writes into the folder it
    /// watches (or whose folder something else keeps touching) would otherwise run again after
    /// every run, all day, on the person's quota; this bounds such a loop to a handful of runs an
    /// hour. Changes past it are not dropped: they are kept and handed over together once the
    /// oldest delivery is an hour old, so someone dropping files in steadily still gets them all.
    static let maxDeliveriesPerHour = 10

    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private var flush: Task<Void, Never>?
    private var delivered: [Date] = []
    /// The folder as the watch was saved, for telling which changes are hidden below it.
    nonisolated private let root: String
    private let settle: Duration
    private let onChange: @MainActor ([String]) -> Void

    init(path: String, settle: Duration = .seconds(4), onChange: @escaping @MainActor ([String]) -> Void) {
        self.settle = settle
        self.onChange = onChange
        self.root = path
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
                // Hidden files anywhere below the folder (.git, editors' swap files) and the
                // folders agents write to while they work. Left out here, not only when the watch
                // matches, so they never count against the hourly cap below.
                if FolderWatch.isIgnored(path, watching: watcher.root) { continue }
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
            self.deliver()
        }
    }

    private func deliver() {
        let now = Date()
        delivered.removeAll { now.timeIntervalSince($0) >= 3600 }
        if delivered.count >= Self.maxDeliveriesPerHour, let oldest = delivered.first {
            // Over the cap: keep what is pending and try again when a slot frees up. A change that
            // arrives meanwhile restarts the settle wait and lands back here, still kept.
            let wait = max(1, 3600 - now.timeIntervalSince(oldest))
            flush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.deliver()
            }
            return
        }
        guard !pending.isEmpty else { return }
        let batch = Array(pending)
        pending.removeAll()
        delivered.append(now)
        onChange(batch)
    }
}
