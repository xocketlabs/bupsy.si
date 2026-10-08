import AVFoundation
import AppKit
import BupsyKit
import Speech

/// Talking to a bot instead of typing: the Mac's own speech recognition, free and with no
/// account. Neither engine gives Bupsy a voice of its own to use (Codex's realtime voice lives
/// inside its terminal interface, which Bupsy does not run), and a paid transcription service
/// would be a bill and a third party for something macOS already does. Recognition stays on this
/// Mac whenever the language allows it.
@MainActor
@Observable
final class VoiceInput {
    enum State: Equatable {
        case idle
        case listening
        /// Why it cannot listen, said in words the person can act on.
        case unavailable(String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var feed: AudioFeed?
    @ObservationIgnored private var silence: Task<Void, Never>?

    /// Stops by itself this long after the last word, so a person can just stop talking.
    static let silenceTimeout: Duration = .seconds(2.5)

    var isListening: Bool { state == .listening }

    /// Starts listening. `onText` gets everything heard so far, each time it grows.
    func start(onText: @escaping @MainActor (String) -> Void) async {
        guard state != .listening else { return }
        guard await Self.permitted() else {
            state = .unavailable("Bupsy needs the microphone and speech recognition. Allow them in System Settings › Privacy & Security.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            state = .unavailable("Speech recognition isn't available right now.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On this Mac when the language allows it: nothing said leaves the machine.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let feed = AudioFeed(request: request)
        self.feed = feed

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            feed.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state = .unavailable("Couldn't use the microphone: \(error.localizedDescription)")
            return
        }
        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                guard let self, self.state == .listening else { return }
                if let text, !text.isEmpty {
                    onText(text)
                    self.restartSilenceTimer()
                }
                if final { self.stop() }
            }
        }
    }

    func stop() {
        silence?.cancel()
        silence = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        feed?.end()
        feed = nil
        task?.finish()
        task = nil
        if state == .listening { state = .idle }
    }

    func dismissProblem() {
        if case .unavailable = state { state = .idle }
    }

    private func restartSilenceTimer() {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceTimeout)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// Asks for the microphone and for speech recognition, once each, the first time.
    private static func permitted() async -> Bool {
        let speech: Bool = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// Hands microphone buffers to the recognizer from the audio thread.
private final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        request?.endAudio()
        request = nil
    }
}

/// Reading replies aloud in the voice the person chose for their Mac (System Settings ›
/// Accessibility › Spoken Content), including the downloadable high-quality ones. Free, on this
/// Mac, no account.
@MainActor
@Observable
final class VoiceOutput: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceOutput()

    /// The message being read, so its button can say Stop.
    private(set) var speaking: UUID?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// The utterance playing now. A finished or cancelled one only clears `speaking` if it is
    /// still this one: starting a second message cancels the first, and that late callback must
    /// not wipe out the new one's Stop button.
    @ObservationIgnored private var current: ObjectIdentifier?

    static let readRepliesKey = "voice.readReplies"

    /// Whether a bot's new reply is read out when it finishes, in the chat that is open.
    static var readsReplies: Bool {
        get { AppHome.defaults.bool(forKey: readRepliesKey) }
        set { AppHome.defaults.set(newValue, forKey: readRepliesKey) }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Reads a reply, stopping whatever was being read. The same message again stops it.
    func toggle(_ markdown: String, id: UUID) {
        if speaking == id { stop(); return }
        speak(markdown, id: id)
    }

    func speak(_ markdown: String, id: UUID = UUID()) {
        let text = SpokenText.from(markdown)
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        speaking = id
        current = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speaking = nil
        current = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        ended(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        ended(ObjectIdentifier(utterance))
    }

    nonisolated private func ended(_ utterance: ObjectIdentifier) {
        Task { @MainActor in
            guard self.current == utterance else { return }
            self.speaking = nil
            self.current = nil
        }
    }
}
