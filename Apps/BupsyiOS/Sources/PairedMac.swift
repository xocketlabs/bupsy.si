import Foundation

/// One of the person's Macs that this iPhone is paired with.
///
/// What's here is safe to keep in plain sight: a name, an address, what sort of Mac it is. The key
/// that proves the pairing is the secret, and it lives in the Keychain under this Mac's id (see
/// `MacStore`), one item per Mac, so forgetting one Mac can never touch another's.
struct PairedMac: Codable, Identifiable, Equatable, Sendable {
    /// Made on this phone when the Mac is first paired. Stays the same when it's paired again at
    /// the same address, so its bots, drafts and notifications carry on as before.
    let id: String
    /// The Mac's own name, as the person set it in System Settings. Empty until it first answers.
    var name: String
    /// Scheme, host and port only, e.g. `https://studio.tail1234.ts.net:8443`.
    var address: URL
    /// "laptop" or "desktop", for the icon beside its bots. A Mac on an older Bupsy doesn't say,
    /// and is drawn as a desktop.
    var kind: String
    /// The Mac turned this phone's key away: it was removed in Bupsy's settings there. Kept in the
    /// list, so the person sees which Mac it was and can pair it again, rather than it vanishing.
    var unpaired: Bool

    init(id: String = UUID().uuidString, name: String, address: URL, kind: String = "desktop", unpaired: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.kind = kind
        self.unpaired = unpaired
    }

    /// Its name, or its Tailscale name's first part until it has said what it's called.
    var displayName: String {
        if !name.isEmpty { return name }
        return address.host?.split(separator: ".").first.map(String.init) ?? "Your Mac"
    }

    /// The SF Symbol the Mac app uses for the same Mac, so both apps mark a bot the same way.
    var symbol: String { kind == "laptop" ? "laptopcomputer" : "desktopcomputer" }
}

/// A bot's identity on this phone: which Mac it lives on, and its id there.
///
/// Two Macs can't be trusted to keep their ids apart, so everything that names a bot (the
/// navigation path, drafts, notifications) uses this rather than the bot's own id, and a chat can
/// never open on the wrong Mac's bot.
struct BotRef: Hashable, Codable, Sendable, CustomStringConvertible {
    let macID: String
    /// The bot's id on its own Mac, which is what that Mac's API takes.
    let botID: String

    /// `macID:botID`, as a notification carries it.
    var description: String { "\(macID):\(botID)" }

    init(macID: String, botID: String) {
        self.macID = macID
        self.botID = botID
    }

    /// From `macID:botID`. Mac ids are UUIDs and never hold a colon, so the first one splits them
    /// whatever the bot's own id looks like.
    init?(_ text: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let macID = String(text[..<colon]), botID = String(text[text.index(after: colon)...])
        guard !macID.isEmpty, !botID.isEmpty else { return nil }
        self.init(macID: macID, botID: botID)
    }
}
