import Foundation

/// Where a local model runs: the person's own Ollama or LM Studio, on this Mac.
///
/// Codex CLI's local mode (`codex exec --oss --local-provider <name>`) talks to either. Bupsy only
/// asks each one, over localhost, which models it has, so the picker can offer them and a run can
/// refuse a model that is not there. Nothing is sent anywhere else.
public enum LocalProvider: String, Sendable, Codable, CaseIterable {
    // In order of preference: Ollama first when both are running.
    case ollama
    case lmstudio

    public var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        }
    }

    /// The local endpoint that lists installed models. Each provider's default port.
    public var modelsURL: URL {
        switch self {
        case .ollama: URL(string: "http://localhost:11434/api/tags")!
        case .lmstudio: URL(string: "http://localhost:1234/v1/models")!
        }
    }

    /// How to get a first model, in words that fit after "Pull a model first, e.g.".
    var firstModelHint: String {
        switch self {
        case .ollama: "Pull a model first, e.g. ollama pull qwen3:8b"
        case .lmstudio: "Download a model in LM Studio first, e.g. Qwen3 8B"
        }
    }

    /// The model names in a provider's reply, or nil when the reply is not that provider's shape
    /// (something else is listening on the port).
    ///
    /// Ollama's `/api/tags` is `{"models":[{"name":"qwen3:8b",…}]}`; LM Studio's OpenAI-style
    /// `/v1/models` is `{"data":[{"id":"qwen/qwen3-8b",…}]}`. Embedding models are left out: they
    /// cannot hold a conversation, so offering one would only make a bot fail on its first turn.
    public func modelNames(in data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let entries: [[String: Any]]?
        let key: String
        switch self {
        case .ollama: entries = object["models"] as? [[String: Any]]; key = "name"
        case .lmstudio: entries = object["data"] as? [[String: Any]]; key = "id"
        }
        guard let entries else { return nil }
        var seen = Set<String>()
        return entries.compactMap { $0[key] as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().contains("embed") && seen.insert($0).inserted }
    }
}

/// One installed model, and the provider it is in.
///
/// Stored as a bot's model id in the form `<provider>:<name>`, e.g. `ollama:qwen3:8b` or
/// `lmstudio:qwen/qwen3-8b`: the provider is everything before the first colon, so a name keeps
/// any colons of its own (Ollama's tags have one). The run splits it back into
/// `--local-provider <provider>` and `-m <name>`.
public struct LocalModel: Sendable, Hashable {
    public var provider: LocalProvider
    public var name: String

    public init(provider: LocalProvider, name: String) {
        self.provider = provider
        self.name = name
    }

    public var id: String { "\(provider.rawValue):\(name)" }

    /// A stored id split back into provider and name, or nil when it does not name a provider.
    public init?(id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":"),
              let provider = LocalProvider(rawValue: String(trimmed[..<colon]).lowercased())
        else { return nil }
        let name = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        self.init(provider: provider, name: name)
    }

    /// For a model picker: the model's own name, with where it runs beside it.
    public var option: ModelOption {
        ModelOption(id: id, label: name, detail: provider.displayName)
    }
}

/// Why a local run cannot start, in words for the chat.
public enum LocalModelProblem: Error, Sendable, Equatable, CustomStringConvertible {
    case noModelChosen
    case noRuntime
    case providerNotRunning(LocalProvider)
    case noModels(LocalProvider)
    case notInstalled(name: String, provider: LocalProvider?)

    public var description: String {
        switch self {
        case .noModelChosen:
            "Pick a model in this bot's Model menu first. Without one, Codex would start "
                + "downloading gpt-oss:20b (about 13 GB) on its own."
        case .noRuntime:
            "Start Ollama or LM Studio, then try again."
        case .providerNotRunning(let provider):
            "\(provider.displayName) isn't running. Start it, then try again."
        case .noModels(let provider):
            "\(provider.displayName) has no models yet. \(provider.firstModelHint)."
        case .notInstalled(let name, let provider):
            switch provider {
            case .ollama?: "\(name) isn't in Ollama. Pull it first (ollama pull \(name)), or pick a model you have."
            case .lmstudio?: "\(name) isn't in LM Studio. Download it there first, or pick a model you have."
            case nil: "\(name) isn't installed in Ollama or LM Studio. Pick a model you have."
            }
        }
    }

    /// The failure a refused run shows. Runtime problems read like a sign-in problem, which has
    /// a "check again" in the chat; a model problem is fixed in the Model menu, then retried.
    public var failure: EngineFailure {
        switch self {
        case .noRuntime, .providerNotRunning, .noModels:
            EngineFailure(kind: .notSignedIn, message: description)
        case .noModelChosen, .notInstalled:
            EngineFailure(kind: .launchFailed, message: description)
        }
    }
}

/// What is running on this Mac right now, and the models in it.
public struct LocalRuntime: Sendable, Equatable {
    /// The providers that answered, in preference order.
    public var running: [LocalProvider]
    /// Every installed model across them, Ollama's first.
    public var models: [LocalModel]

    public init(running: [LocalProvider] = [], models: [LocalModel] = []) {
        self.running = running
        self.models = models
    }

    /// For the model picker.
    public var options: [ModelOption] { models.map(\.option) }

    /// The verdict onboarding and Settings show. About the runtime, not an account: there is none.
    public var status: AuthStatus {
        guard let first = running.first else { return .notReady("Start Ollama or LM Studio") }
        guard !models.isEmpty else {
            // The hint for the provider most likely to be used: Ollama when it is running.
            return .notReady(first.firstModelHint)
        }
        return .signedIn(method: .onThisMac)
    }

    /// The installed model a bot's stored id names, or why there is none.
    ///
    /// Takes the `<provider>:<name>` form a picker stores, and also a bare name someone typed
    /// ("qwen3:8b"), which is looked up in each running provider, Ollama first. Only a model that
    /// is installed comes back: Codex pulls one that is not, without asking.
    public func resolve(_ id: String?) -> Result<LocalModel, LocalModelProblem> {
        let wanted = id?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !wanted.isEmpty else { return .failure(.noModelChosen) }
        guard !running.isEmpty else { return .failure(.noRuntime) }
        if let exact = LocalModel(id: wanted) {
            guard running.contains(exact.provider) else { return .failure(.providerNotRunning(exact.provider)) }
            let inProvider = models.filter { $0.provider == exact.provider }
            if inProvider.isEmpty { return .failure(.noModels(exact.provider)) }
            if let found = inProvider.first(where: { $0.name == exact.name })
                ?? inProvider.first(where: { $0.name.caseInsensitiveCompare(exact.name) == .orderedSame }) {
                return .success(found)
            }
            return .failure(.notInstalled(name: exact.name, provider: exact.provider))
        }
        if models.isEmpty, let first = running.first { return .failure(.noModels(first)) }
        if let found = models.first(where: { $0.name == wanted })
            ?? models.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return .success(found)
        }
        return .failure(.notInstalled(name: wanted, provider: nil))
    }
}

/// Asks Ollama and LM Studio, on their default localhost ports, which models they have.
///
/// The fetch is injected so tests need no network and no runtime. Both are asked at once with a
/// short timeout, so a Mac with neither running answers in about a second and a half.
public struct LocalDiscovery: Sendable {
    /// Returns the body of a successful GET, or throws.
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let fetch: Fetch

    public init(fetch: @escaping Fetch = LocalDiscovery.localhost) {
        self.fetch = fetch
    }

    public func discover() async -> LocalRuntime {
        async let ollama = names(from: .ollama)
        async let lmstudio = names(from: .lmstudio)
        let found: [(LocalProvider, [String]?)] = [(.ollama, await ollama), (.lmstudio, await lmstudio)]
        var runtime = LocalRuntime()
        for (provider, names) in found {
            guard let names else { continue }
            runtime.running.append(provider)
            runtime.models += names.map { LocalModel(provider: provider, name: $0) }
        }
        return runtime
    }

    private func names(from provider: LocalProvider) async -> [String]? {
        guard let data = try? await fetch(provider.modelsURL) else { return nil }
        return provider.modelNames(in: data)
    }

    /// A plain GET to localhost: no cookies, no cache, no proxy, 1.5 seconds at most.
    public static let localhost: Fetch = { url in
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
