import AppKit
import BupsyKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Using Bupsy from another device: a phone, another Mac.
///
/// Bupsy serves a small web app on this Mac's loopback only (`LocalHTTPServer`), and Tailscale
/// Serve carries it to the person's own devices over their private network with HTTPS. Nothing is
/// offered to the internet and no port opens on the Wi-Fi; a device must be on the person's
/// tailnet to reach it at all, and must then be paired here before it can see or do anything.
///
/// Every request from a device goes through the same calls the app's own buttons make, so an
/// approval answered from a phone is gated, recorded and expired exactly like one answered here.
@MainActor
@Observable
final class RemoteAccess {
    enum Status: Equatable {
        case off
        case starting
        /// Reachable at this address from the person's devices.
        case on(URL)
        /// Wanted on, but something is in the way; the message says what to do.
        case problem(String)
    }

    private(set) var status: Status = .off
    private(set) var tailscale: TailscaleStatus?
    /// The pairing code on screen, with the address that pairs by scanning it.
    private(set) var pairing: (code: String, link: URL)?
    private(set) var devices: [PairedDevice] = []

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var server: LocalHTTPServer?
    @ObservationIgnored private lazy var registry = RemoteDevices(
        file: AppHome.directory.appendingPathComponent("remote-devices.json"))
    @ObservationIgnored private var iconPNG: Data?

    /// The port Bupsy asks for on loopback; any free one is used if it is taken.
    static let preferredPort: UInt16 = 47815
    static let enabledKey = "remoteAccess.enabled"
    static let cookie = "bupsy_device"

    init(model: AppModel) {
        self.model = model
    }

    var isEnabled: Bool { AppHome.defaults.bool(forKey: Self.enabledKey) }

    var address: URL? {
        if case .on(let url) = status { return url }
        return nil
    }

    /// At launch: back on if it was on when the app quit.
    func resumeIfEnabled() {
        devices = registry.devices
        #if DEBUG
        // Testing only: the server alone on a fixed port, without Tailscale, with a fresh pairing
        // code printed after each pairing. Debug builds only; release builds have no such switch.
        if let port = ProcessInfo.processInfo.environment["BUPSY_REMOTE_TEST_PORT"].flatMap(UInt16.init) {
            Task {
                let server = LocalHTTPServer { [weak self] request in
                    guard let self else { return .error("closing", status: 503) }
                    let response = await self.handle(request)
                    if request.path == "/api/pair", response.status == 200 { await self.printTestCode() }
                    return response
                }
                self.server = server
                _ = try? await server.start(preferredPort: port)
                status = .on(URL(string: "http://127.0.0.1:\(port)")!)
                printTestCode()
            }
            return
        }
        #endif
        guard isEnabled else { return }
        Task { await start() }
    }

    func setEnabled(_ on: Bool) {
        AppHome.defaults.set(on, forKey: Self.enabledKey)
        Task { on ? await start() : await stop() }
    }

    func start() async {
        status = .starting
        let tail = await Tailscale.status()
        tailscale = tail
        switch tail.state {
        case .notInstalled:
            status = .problem("Install Tailscale on this Mac and your other devices, and sign in to the same account.")
            return
        case .notConnected(let message):
            status = .problem(message)
            return
        case .connected:
            break
        }
        guard let host = tail.dnsName else {
            status = .problem("Tailscale didn't give this Mac a name. Turn on MagicDNS in the Tailscale admin console.")
            return
        }
        do {
            let server = self.server ?? LocalHTTPServer { [weak self] request in
                guard let self else { return .error("Bupsy is closing", status: 503) }
                return await self.handle(request)
            }
            self.server = server
            let port = try await server.start(preferredPort: server.port ?? Self.preferredPort)
            try await Tailscale.serve(localPort: port)
            status = .on(URL(string: "https://\(host):\(Tailscale.httpsPort)")!)
        } catch {
            server?.stop()
            status = .problem(error.localizedDescription)
        }
    }

    func stop() async {
        pairing = nil
        registry.cancelCode()
        await Tailscale.stopServing()
        server?.stop()
        status = .off
    }

    #if DEBUG
    private func printTestCode() {
        FileHandle.standardError.write("REMOTE_TEST_CODE \(registry.newCode().value)\n".data(using: .utf8)!)
    }
    #endif

    // MARK: - Pairing

    func startPairing() {
        guard let address else { return }
        let code = registry.newCode()
        var components = URLComponents(url: address, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code", value: code.value)]
        pairing = (code.value, components.url ?? address)
    }

    func cancelPairing() {
        registry.cancelCode()
        pairing = nil
    }

    func remove(_ device: PairedDevice) {
        registry.remove(device.id)
        devices = registry.devices
    }

    /// A QR code for the pairing link, crisp at any size.
    func qrImage(for link: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Requests

    /// Every request lands here. The page itself, its manifest and icon are public: they hold
    /// nothing. Everything under /api needs a paired device's key, except pairing itself.
    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(RemoteWebApp.html)
        case ("GET", "/manifest.webmanifest"):
            return manifest()
        case ("GET", "/icon.png"):
            return icon()
        case ("POST", "/api/pair"):
            return pair(request)
        default:
            break
        }
        guard request.path.hasPrefix("/api/") else { return .error("Not found", status: 404) }
        guard registry.device(forKey: request.cookie(Self.cookie)) != nil else {
            return .error("This device isn't paired with Bupsy.", status: 401)
        }
        // Refresh the list so the Settings window shows when each device was last seen.
        devices = registry.devices
        return route(request)
    }

    private func pair(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.json ?? [:]
        do {
            let (_, key) = try registry.pair(code: body["code"] as? String ?? "",
                                             name: body["name"] as? String ?? "")
            devices = registry.devices
            pairing = nil
            var response = HTTPResponse.json(["ok": true])
            // HttpOnly so the page's own script never handles it, Secure because Tailscale Serve
            // is HTTPS, Strict so no other site can make the browser send it along.
            response.headers["Set-Cookie"] = "\(Self.cookie)=\(key); Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Strict"
            return response
        } catch RemoteDevices.PairingError.expired {
            return .error("That code has expired. Make a new one on your Mac.", status: 401)
        } catch RemoteDevices.PairingError.tooManyTries {
            return .error("Too many wrong tries. Make a new code on your Mac.", status: 429)
        } catch {
            return .error("That code didn't work. Check it, or make a new one on your Mac.", status: 401)
        }
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        guard let model else { return .error("Bupsy is closing", status: 503) }
        // "/api/bots/<id>/approvals/<approval>" becomes ["bots", "<id>", "approvals", "<approval>"].
        let parts = request.path.split(separator: "/").dropFirst()
            .map { String($0).removingPercentEncoding ?? String($0) }
        let get = request.method == "GET", post = request.method == "POST"

        if get, parts == ["session"] {
            return .json(["mac": Host.current().localizedName ?? "Your Mac"])
        }
        if get, parts == ["bots"] {
            let bots = orderedBots(model)
            return .json(["bots": bots.map { botJSON($0, model) },
                          "waiting": bots.filter { model.needsYou($0) }.count])
        }
        // A bot kept to this Mac answers exactly as a bot that does not exist: another device
        // cannot read it, act on it, or even learn that it is there.
        guard parts.count >= 3, parts[0] == "bots",
              let bot = model.bots.first(where: { $0.id.rawValue == parts[1] && $0.sharedWithDevices && !$0.hidden })
        else { return .error("Not found", status: 404) }
        let action = Array(parts.dropFirst(2))

        if get, action == ["messages"] {
            return .json(["bot": botJSON(bot, model), "entries": entriesJSON(bot, model)])
        }
        if post, action == ["messages"] {
            let text = (request.json?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .error("Write something first.", status: 400) }
            model.send(text, to: bot)
            return .json(["ok": true])
        }
        if post, action.count == 2, action[0] == "approvals" {
            guard let allow = request.json?["allow"] as? Bool else { return .error("Allow or deny?", status: 400) }
            guard let approval = pendingApproval(action[1], bot: bot, model) else {
                return .error("That request was already answered.", status: 409)
            }
            model.decide(approval, allow: allow, for: bot)
            return .json(["ok": true])
        }
        if post, action.count == 2, action[0] == "questions" {
            guard let answer = request.json?["answer"] as? String else { return .error("No answer given.", status: 400) }
            guard let question = openQuestion(action[1], bot: bot, model) else {
                return .error("That question was already answered.", status: 409)
            }
            model.answer(question, with: answer, for: bot)
            return .json(["ok": true])
        }
        if post, action == ["stop"] {
            model.stop(bot.id)
            return .json(["ok": true])
        }
        return .error("Not found", status: 404)
    }

    // MARK: - What the page is sent

    /// The sidebar's order: pinned, then bots in no section, then each section in turn. Only
    /// bots shared with the person's devices; "This Mac only" ones are left out entirely.
    private func orderedBots(_ model: AppModel) -> [Bot] {
        let visible = model.bots.filter { !$0.hidden && $0.sharedWithDevices }
        var ordered = visible.filter(\.pinned)
        ordered += visible.filter { !$0.pinned && ($0.folder ?? "").isEmpty }
        for section in model.folders {
            ordered += visible.filter { !$0.pinned && $0.folder == section }
        }
        return ordered
    }

    private func botJSON(_ bot: Bot, _ model: AppModel) -> [String: Any] {
        [
            "id": bot.id.rawValue,
            "name": bot.name,
            "role": bot.role as Any? ?? NSNull(),
            "section": bot.pinned ? NSNull() : (bot.folder as Any? ?? NSNull()),
            "colour": Self.hex(BotFace.colour(of: bot)),
            "mood": Self.moodName(model.mood(for: bot)),
            "running": model.isRunning(bot.id),
            "needsYou": model.needsYou(bot),
            "unread": model.isUnread(bot),
            "preview": model.thread(for: bot.id).preview as Any? ?? NSNull(),
        ]
    }

    /// The latest visible entries, oldest first: what someone glancing at a phone needs, without
    /// the bot's thinking or bookkeeping.
    private func entriesJSON(_ bot: Bot, _ model: AppModel) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        var out: [[String: Any]] = []
        for entry in model.thread(for: bot.id).entries.suffix(160) {
            var item: [String: Any] = ["id": entry.id.uuidString, "at": formatter.string(from: entry.at)]
            switch entry.kind {
            case .userMessage(let text):
                item["kind"] = "you"; item["text"] = Reply.split(text).body
            case .messageFrom(_, let name, let text):
                item["kind"] = "from"; item["author"] = name; item["text"] = text
            case .assistantText(let text):
                item["kind"] = "bot"; item["text"] = text
            case .tool(let name, let arguments, _, let failed):
                let info = ToolCallInfo(tool: name, argumentsJSON: arguments)
                switch info.line {
                case .hidden: continue
                case .messaged(let to, _):
                    item["kind"] = "note"; item["text"] = "Messaged \(to)"
                case .note(let text):
                    item["kind"] = "note"; item["text"] = text
                case .raw:
                    item["kind"] = "tool"
                    item["tool"] = ["verb": Self.verb(name), "target": info.summary, "failed": failed]
                }
            case .approval(let approval):
                item["kind"] = "approval"
                item["approval"] = [
                    "id": approval.id, "tool": approval.tool, "summary": approval.summary,
                    "reason": approval.reason,
                    "decided": approval.decided.map(Self.decisionName) as Any? ?? NSNull(),
                ]
            case .question(let question):
                item["kind"] = "question"
                item["question"] = ["id": question.id, "question": question.question,
                                    "options": question.options,
                                    "answer": question.answer as Any? ?? NSNull()]
            case .note(let text):
                if ThreadRowContext.holdsQueuedNote(entry.kind) { continue }
                item["kind"] = "note"; item["text"] = text
            case .failure(let failure):
                item["kind"] = "failure"; item["text"] = failure.message
            case .thinking, .finished:
                continue
            }
            out.append(item)
        }
        return Array(out.suffix(80))
    }

    private func pendingApproval(_ id: String, bot: Bot, _ model: AppModel) -> PendingApproval? {
        for thread in model.approvalThreads(for: bot.id) {
            for entry in thread.entries {
                if case .approval(let approval) = entry.kind, approval.id == id, approval.decided == nil {
                    return approval
                }
            }
        }
        return nil
    }

    private func openQuestion(_ id: String, bot: Bot, _ model: AppModel) -> BotQuestion? {
        for entry in model.thread(for: bot.id).entries {
            if case .question(let question) = entry.kind, question.id == id, question.answer == nil {
                return question
            }
        }
        return nil
    }

    private func manifest() -> HTTPResponse {
        var response = HTTPResponse.json([
            "name": "Bupsy", "short_name": "Bupsy", "start_url": "/", "display": "standalone",
            "background_color": "#202020", "theme_color": "#202020",
            "icons": [["src": "/icon.png", "sizes": "512x512", "type": "image/png"]],
        ])
        response.headers["Content-Type"] = "application/manifest+json"
        return response
    }

    private func icon() -> HTTPResponse {
        if iconPNG == nil {
            let image = NSApp.applicationIconImage ?? NSImage()
            let size = NSSize(width: 512, height: 512)
            let rendered = NSImage(size: size, flipped: false) { rect in
                image.draw(in: rect)
                return true
            }
            iconPNG = rendered.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:])
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"],
                            body: iconPNG ?? Data())
    }

    // MARK: - Names

    static func verb(_ tool: String) -> String {
        switch tool {
        case "Bash", "shell": "ran"
        case "Read": "read"
        case "Write", "Edit", "MultiEdit", "edit": "edited"
        case "WebFetch", "WebSearch": "looked up"
        case "Grep", "Glob": "searched"
        default: tool.hasPrefix("mcp__") ? "used" : tool.lowercased()
        }
    }

    static func moodName(_ mood: BotMood) -> String {
        switch mood {
        case .idle: "idle"
        case .working: "working"
        case .waitingForYou: "waitingForYou"
        case .done: "done"
        case .sleeping: "sleeping"
        case .failed: "failed"
        }
    }

    static func decisionName(_ decision: PendingApproval.Decision) -> String {
        switch decision {
        case .allowed: "allowed"
        case .alwaysAllowed: "alwaysAllowed"
        case .denied: "denied"
        case .expired: "expired"
        }
    }

    static func hex(_ colour: Color) -> String {
        guard let rgb = NSColor(colour).usingColorSpace(.sRGB) else { return "#e075c8" }
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
