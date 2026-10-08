import Foundation

/// What this phone last heard from one Mac.
struct MacState: Equatable {
    /// Whether it has answered since the app opened. Until one Mac has, the app says it's
    /// connecting rather than showing an empty list.
    var reached = false
    /// Why the last look failed. Nil when it worked, or before the first look.
    var problem: String?
    /// Its bots in its sidebar's order, as of the last look that worked.
    var bots: [Bot] = []
    /// How many of them need the person, by the Mac's own count.
    var waiting = 0

    /// Answered at the last look.
    var online: Bool { reached && problem == nil }
}

/// How a Mac is doing, in the words the "Your Macs" screen uses.
enum MacStatus: Equatable {
    case connecting
    case connected
    case offline
    /// It removed this phone. Only pairing again with a new code brings it back.
    case notPaired

    var label: String {
        switch self {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .offline: "Offline"
        case .notPaired: "Not paired any more"
        }
    }
}

/// A bot as the list shows it: the bot, the Mac it lives on, and how to name it.
struct ListedBot: Identifiable, Equatable {
    let bot: Bot
    let mac: PairedMac
    /// The bot's own name, or "Scout · Mac mini" when a bot on another Mac has the same name, so
    /// two Scouts can be told apart without opening either.
    let name: String
    /// Its Mac answered at the last look. A bot on a Mac that didn't is greyed out, and can't be
    /// sent anything until its Mac is back.
    let online: Bool
    /// Whether to mark which Mac it's on: only worth the space when there's more than one Mac.
    let showsMac: Bool

    var id: BotRef { bot.ref }
}

/// The bots under one section heading, in the Mac's sidebar order.
struct BotSection: Identifiable, Equatable {
    /// Nil for the bots above every section: pinned ones and those in no section.
    let title: String?
    let bots: [ListedBot]

    var id: String { title ?? "" }

    /// Keeps the order given. Bots in no section come first; sections follow in the order they
    /// first appear. Sections are matched by name, so a "Work" on two Macs is one "Work" here,
    /// the way the Mac app shows another Mac's bots in its own sections.
    static func group(_ bots: [ListedBot]) -> [BotSection] {
        var titles: [String?] = [nil]
        var members: [String?: [ListedBot]] = [:]
        for listed in bots {
            let title = listed.bot.section.flatMap { $0.isEmpty ? nil : $0 }
            if !titles.contains(title) { titles.append(title) }
            members[title, default: []].append(listed)
        }
        return titles.compactMap { title in
            members[title].map { BotSection(title: title, bots: $0) }
        }
    }
}

/// Every paired Mac's bots, made into one list.
///
/// Bots are not grouped by Mac: they join the same sections as everything else, each Mac's in its
/// own order, Macs in the order they were paired, and each marked with its Mac's icon. That is how
/// the Mac app shows its linked Macs' bots, so the two read the same.
enum BotDirectory {
    static func list(macs: [PairedMac], states: [String: MacState]) -> [ListedBot] {
        let paired = macs.filter { !$0.unpaired }
        let showsMac = paired.count > 1
        let all = paired.flatMap { mac in (states[mac.id]?.bots ?? []).map { (mac, $0) } }
        return all.map { mac, bot in
            let twin = all.contains { other, otherBot in
                other.id != mac.id && otherBot.name.caseInsensitiveCompare(bot.name) == .orderedSame
            }
            return ListedBot(bot: bot, mac: mac,
                             name: twin ? "\(bot.name) · \(mac.displayName)" : bot.name,
                             online: states[mac.id]?.online ?? false,
                             showsMac: showsMac)
        }
    }

    static func sections(macs: [PairedMac], states: [String: MacState]) -> [BotSection] {
        BotSection.group(list(macs: macs, states: states))
    }

    /// How many bots need the person, across every Mac that answered at the last look. A Mac that
    /// didn't is left out: what it last said may already be answered there.
    static func waiting(macs: [PairedMac], states: [String: MacState]) -> Int {
        macs.filter { !$0.unpaired }.reduce(0) { total, mac in
            guard let state = states[mac.id], state.online else { return total }
            return total + state.waiting
        }
    }

    static func status(of mac: PairedMac, _ state: MacState?) -> MacStatus {
        if mac.unpaired { return .notPaired }
        guard let state else { return .connecting }
        if state.problem != nil { return .offline }
        return state.reached ? .connected : .connecting
    }
}
