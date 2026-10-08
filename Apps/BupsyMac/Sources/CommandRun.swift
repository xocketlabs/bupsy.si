import AppKit
import SwiftUI

/// Where a command in a reply runs, when it may run at all.
///
/// Set by a bot's chat for a bot on this Mac, to that bot's own folder, so a command it wrote
/// about its files ("open video", "ls sites") means what it said. Unset elsewhere — a group, a
/// bot on a cloud machine whose files are not here — and code blocks there offer only Copy.
private struct CommandDirectoryKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    var commandDirectory: URL? {
        get { self[CommandDirectoryKey.self] }
        set { self[CommandDirectoryKey.self] = newValue }
    }
}

/// One run of a command from a reply: its output as it arrives, and how it ended.
@MainActor
@Observable
final class CommandRun {
    enum State: Equatable {
        case running
        case finished(status: Int32)
        case failedToStart(String)
    }

    private(set) var state: State = .running
    private(set) var output = ""
    private var process: Process?

    /// Output kept on screen. A command that prints forever (a dev server, `yes`) must not grow
    /// the transcript without end, so the oldest text goes first.
    private static let outputLimit = 20_000

    var isRunning: Bool { state == .running }

    /// Runs through the person's login shell, so PATH and their aliases are what their own
    /// terminal has: `brew`, `node` and friends resolve as they do there.
    func start(_ command: String, in directory: URL) {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text) }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.append(rest)
                self?.state = .finished(status: status)
                self?.process = nil
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            state = .failedToStart(error.localizedDescription)
        }
    }

    func stop() {
        process?.terminate()
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        output += text
        if output.count > Self.outputLimit {
            output = "…" + String(output.suffix(Self.outputLimit))
        }
    }
}

/// What a run printed, under the command, with how it ended and a way to stop it.
struct CommandRunOutput: View {
    @Environment(\.palette) private var palette
    let run: CommandRun
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.tight) {
                status
                Spacer(minLength: 0)
                if run.isRunning {
                    Button("Stop") { run.stop() }
                        .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .sm))
                        .help("Stop this command")
                } else {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: Theme.scaled(9), weight: .semibold))
                    }
                    .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .sm))
                    .help("Hide the output")
                    .accessibilityLabel("Hide the output")
                }
            }
            if !run.output.isEmpty {
                ScrollView {
                    Text(run.output)
                        .font(.system(size: Theme.scaled(11.5), design: .monospaced))
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Space.step)
        .padding(.bottom, Theme.Space.step)
    }

    @ViewBuilder
    private var status: some View {
        switch run.state {
        case .running:
            HStack(spacing: Theme.Space.xs) {
                ProgressView().controlSize(.mini)
                Text("Running").foregroundStyle(palette.mutedForeground)
            }
            .font(Theme.Typography.caption)
        case .finished(let status):
            Label(status == 0 ? "Done" : "Exited with \(status)",
                  systemImage: status == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(Theme.Typography.caption)
                .foregroundStyle(status == 0 ? palette.success : palette.destructiveText)
        case .failedToStart(let message):
            Label("Couldn't run: \(message)", systemImage: "exclamationmark.circle.fill")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.destructiveText)
        }
    }
}
