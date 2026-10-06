import Foundation

/// Reads a pipe and yields whole lines.
///
/// Replaces `FileHandle.bytes.lines`, which is an Apple-platform extension and does not exist in
/// corelibs-foundation — found by the Linux CI job. Rather than branch on platform, there is one
/// implementation everywhere: fewer paths, and the thing most likely to break in a port is the
/// part that spawns and drains agent processes, so it is worth it being the same code the Mac
/// has been exercising all along.
///
/// Reads in chunks and splits on newlines, holding any trailing partial line until the rest of it
/// arrives. Engine output is line-delimited JSON, so a line split across two reads would be
/// unparseable — which is exactly the kind of failure that shows up only under load.
struct LineReader {
    private let handle: FileHandle
    private var pending = Data()

    /// Yields each complete line as it arrives, then any final line without a trailing newline.
    ///
    /// Blocking reads on a thread of their own: `FileHandle` has no portable async read.
    ///
    /// Not a detached task. A task blocked in `read()` holds one of the few Swift concurrency
    /// threads — one per core — for as long as the engine runs, two per run (stdout and
    /// stderr). A handful of busy bots took the whole pool, and every other task in the app,
    /// the approval gate's poll included, stalled behind them.
    static func lines(of handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let stopped = StopFlag()
            let thread = Thread {
                var reader = LineReader(handle)
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while !stopped.isSet {
                    guard let chunk = readSome(handle, into: &buffer), !chunk.isEmpty else {
                        // Empty read means end of file: the process closed the pipe.
                        for line in reader.flush() { continuation.yield(line) }
                        break
                    }
                    for line in reader.take(chunk) { continuation.yield(line) }
                }
                continuation.finish()
            }
            thread.name = "bupsy.line-reader"
            continuation.onTermination = { _ in stopped.set() }
            thread.start()
        }
    }

    /// Checked between reads, as `Task.isCancelled` was. A read already blocked returns when the
    /// pipe closes, which stopping the process brings about.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// Whatever the pipe has right now, up to the buffer's size, blocking only until there is
    /// something. Empty at end of file, nil on a read error.
    ///
    /// Not `FileHandle.read(upToCount:)`: that keeps reading until it has the full count or the
    /// pipe closes, so a short line — "running tests…", the pid a test waits for — sat in the
    /// buffer until 4 KB more arrived or the process exited. Measured: a line written at once
    /// came back three seconds later, when its writer finished.
    static func readSome(_ handle: FileHandle, into buffer: inout [UInt8]) -> Data? {
        #if os(Windows)
        return handle.availableData
        #else
        while true {
            let count = buffer.withUnsafeMutableBytes {
                read(handle.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count >= 0 { return Data(buffer[0..<count]) }
            if errno == EINTR { continue }
            return nil
        }
        #endif
    }

    /// The longest line kept whole. Engine lines are JSON events, and even one carrying a large
    /// tool result is far below this; a line past it is a runaway (a binary dumped to stdout, a
    /// process that never writes a newline) and would otherwise grow without bound in memory.
    static let defaultMaximumLineLength = 16 * 1024 * 1024

    /// Stands in for a line that went past the limit, so the drop is visible in the log rather
    /// than silent. Not JSON, so no normaliser will mistake it for an event.
    static let truncatedLineMarker = "[bupsy: line longer than the limit was dropped]"

    private let maximumLineLength: Int
    /// How far into `pending` has already been searched for a newline. Without it every chunk
    /// rescanned the whole partial line from the start, which made one long line quadratic.
    private var scanned = 0
    /// True while discarding the rest of a line that already went past the limit.
    private var discarding = false

    init(_ handle: FileHandle, maximumLineLength: Int = LineReader.defaultMaximumLineLength) {
        self.handle = handle
        self.maximumLineLength = maximumLineLength
    }

    /// Consumes a chunk and returns whatever complete lines it completed.
    mutating func take(_ chunk: Data) -> [String] {
        var lines: [String] = []
        var chunk = chunk[...]

        // Still inside an over-long line: throw bytes away until its newline turns up.
        if discarding {
            guard let newline = chunk.firstIndex(of: 0x0A) else { return [] }
            discarding = false
            chunk = chunk[chunk.index(after: newline)...]
        }

        pending.append(contentsOf: chunk)
        var start = pending.startIndex
        var searchFrom = start + scanned

        while let newline = pending[searchFrom...].firstIndex(of: 0x0A) {
            if newline - start > maximumLineLength {
                lines.append(Self.truncatedLineMarker)
            } else {
                lines.append(Self.decode(pending[start..<newline]))
            }
            start = pending.index(after: newline)
            searchFrom = start
        }

        // Drop the consumed prefix once per chunk, not once per line, and only when a line was
        // actually completed: copying a still-growing partial line on every chunk would bring
        // the quadratic cost straight back.
        if start != pending.startIndex { pending = Data(pending[start...]) }
        scanned = pending.count

        if pending.count > maximumLineLength {
            lines.append(Self.truncatedLineMarker)
            pending = Data()
            scanned = 0
            discarding = true
        }
        return lines
    }

    /// Whatever is left when the pipe closes without a final newline.
    mutating func flush() -> [String] {
        defer { pending = Data(); scanned = 0; discarding = false }
        guard !pending.isEmpty else { return [] }
        return [Self.decode(pending)]
    }

    /// Engine output should be UTF-8. A chunk boundary can land mid-character, so a lossy decode
    /// is better than dropping a line: a replacement character in one log line beats losing a
    /// tool result.
    private static func decode(_ data: some DataProtocol) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }
}
