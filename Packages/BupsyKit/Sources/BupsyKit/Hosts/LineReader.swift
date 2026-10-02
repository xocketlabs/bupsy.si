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

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    /// Yields each complete line as it arrives, then any final line without a trailing newline.
    ///
    /// Blocking reads on a detached task: `FileHandle` has no portable async read, and a pipe
    /// that is drained on its own task is exactly the arrangement `ProcessBox` already uses.
    static func lines(of handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task.detached {
                var reader = LineReader(handle)
                while !Task.isCancelled {
                    guard let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty else {
                        // Empty read means end of file: the process closed the pipe.
                        for line in reader.flush() { continuation.yield(line) }
                        break
                    }
                    for line in reader.take(chunk) { continuation.yield(line) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Consumes a chunk and returns whatever complete lines it completed.
    mutating func take(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []

        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            lines.append(Self.decode(line))
            pending = pending[pending.index(after: newline)...]
        }
        return lines
    }

    /// Whatever is left when the pipe closes without a final newline.
    mutating func flush() -> [String] {
        defer { pending = Data() }
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
