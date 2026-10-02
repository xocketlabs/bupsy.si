import SwiftUI

/// One place for the measurements the whole app is built on.
///
/// A messaging app lives or dies on rhythm — if every view picks its own padding the result reads
/// as unfinished no matter how good the individual pieces are. These are the only numbers views
/// should reach for.
enum Theme {
    enum Space {
        /// Between tightly related things: an icon and its label.
        static let tight: CGFloat = 6
        /// Inside a row or bubble.
        static let snug: CGFloat = 10
        /// The default gap between elements.
        static let step: CGFloat = 14
        /// Between groups.
        static let wide: CGFloat = 22
    }

    enum Radius {
        static let bubble: CGFloat = 16
        static let card: CGFloat = 12
        static let chip: CGFloat = 8
    }

    enum Size {
        static let rosterAvatar: CGFloat = 38
        static let bubbleAvatar: CGFloat = 26
        static let profileAvatar: CGFloat = 76
        /// Bubbles stop here rather than filling the window. Long lines are hard to read, and a
        /// reply that spans a wide display stops looking like a message.
        static let bubbleMaxWidth: CGFloat = 560
    }

    /// Time formatting that matches how people read a chat: today is a time, this week is a day,
    /// older is a date.
    static func stamp(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: now), date > week {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The heading above a day's messages.
    static func daySeparator(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
