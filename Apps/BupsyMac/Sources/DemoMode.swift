#if DEBUG
import AppKit
import BupsyKit
import Foundation

/// Debug-only: a staged Bupsy for recording a product video.
///
///     BUPSY_HOME=/tmp/bupsy-demo Bupsy --demo [--autoplay]
///
/// The real app, on a seeded roster (`DemoWorld`), with runs answered by a scripted engine
/// (`DemoHost`) instead of the real CLIs: the same parsing, the same thread, the same outbox and
/// hand-offs, so every frame is the real UI, but nothing calls a model, nothing costs anything and
/// every take plays out the same. `--autoplay` performs the whole sequence by itself
/// (`DemoAutoplay`), so a take can be recorded hands-free; `scripts/record-demo.sh` does that.
///
/// It only ever runs on a throwaway home. Without `BUPSY_HOME` the app refuses to start, before
/// the database is opened, so a demo can never seed, or play into, the person's real roster.
enum DemoMode {
    static let isOn: Bool = CommandLine.arguments.contains("--demo") && AppHome.isSandboxed
    static let autoplay: Bool = isOn && CommandLine.arguments.contains("--autoplay")

    /// The name in the sidebar's account row, in place of this Mac's account name.
    static let personName = "Alex Rivera"

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// `BUPSY_DEMO_APPEARANCE=dark` for a dark take. Light otherwise.
    static var appearance: AppModel.Appearance {
        environment["BUPSY_DEMO_APPEARANCE"] == "dark" ? .dark : .light
    }

    /// Called first thing in `AppModel.init`: `--demo` on the real home stops the app.
    static func refuseWithoutThrowawayHome() {
        guard CommandLine.arguments.contains("--demo"), !AppHome.isSandboxed else { return }
        FileHandle.standardError.write(Data("""
            bupsy: --demo needs a throwaway home, so it can never touch your real bots.
            Run it as: BUPSY_HOME=/tmp/bupsy-demo \(CommandLine.arguments[0]) --demo

            """.utf8))
        exit(64)
    }

    /// Neither restores the window from, nor leaves it to, macOS's saved window state, which
    /// the debug build shares with the real app. A window marked unrestorable instead is saved as
    /// "closed", and the next launch opens no window at all. Set before the app finishes
    /// launching, in the arguments domain, so it lasts for this run only and is written nowhere.
    static func keepWindowStateToItself() {
        guard isOn else { return }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        arguments["NSQuitAlwaysKeepsWindows"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    // MARK: - The window

    /// The window's size on screen, in points: `BUPSY_DEMO_SIZE=1360x765`. 16:9 by default, so a
    /// recording scales to 1080p without bars.
    static var windowSize: CGSize {
        let parts = (environment["BUPSY_DEMO_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 900, parts[1] >= 600 else { return CGSize(width: 1360, height: 765) }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// Around the window, filled by a backdrop of our own, so a recording of the region shows a
    /// clean ground and the window's own corners and shadow, never the desktop behind it.
    static var margin: CGSize {
        let parts = (environment["BUPSY_DEMO_MARGIN"] ?? "").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return CGSize(width: 48, height: 27) }
        return CGSize(width: parts[0], height: parts[1])
    }

    @MainActor private static var backdrop: NSWindow?

    /// Puts the window at a fixed size in the middle of the main screen, on a backdrop, and keeps
    /// it from saving its frame: the debug build shares the real app's bundle id, and with it the
    /// real app's preferences ("NSWindow Frame main"), where a demo take must leave nothing behind.
    ///
    /// Writes the recorded region to `BUPSY_DEMO_FRAME_FILE` as "x,y,w,h", in the top-left
    /// screen points `screencapture -R` takes.
    @discardableResult @MainActor static func prepareWindow() -> Bool {
        guard let window = NSApp.windows
            .filter({ $0.isVisible && $0.styleMask.contains(.titled) })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let screen = NSScreen.screens.first
        else { return false }
        window.setFrameAutosaveName("")

        let size = windowSize
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded(),
            width: size.width, height: size.height)
        window.setFrame(frame, display: true)

        let region = frame.insetBy(dx: -margin.width, dy: -margin.height)
        backdrop?.close()
        let ground = NSWindow(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
        ground.isReleasedWhenClosed = false
        ground.ignoresMouseEvents = true
        ground.hasShadow = false
        ground.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ground.contentView = DemoBackdropView(frame: NSRect(origin: .zero, size: region.size))
        // Above everything else on screen while autoplay records, so nothing wanders into the shot.
        let level: NSWindow.Level = autoplay ? .floating : .normal
        ground.level = level
        window.level = level
        // Hands-free: the pointer, wherever it is, must not light up hover states mid-take.
        if autoplay { window.ignoresMouseEvents = true }
        ground.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        backdrop = ground

        if let path = environment["BUPSY_DEMO_FRAME_FILE"] {
            // Top-left origin, measured from the main screen, as screencapture counts.
            let top = screen.frame.maxY - region.maxY
            let line = "\(Int(region.minX)),\(Int(top)),\(Int(region.width)),\(Int(region.height))\n"
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return true
    }
}

/// A soft gradient in the app's own colours, behind the window.
private final class DemoBackdropView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = DemoMode.appearance == .dark
        let colours: [NSColor] = dark
            ? [NSColor(srgbRed: 0.17, green: 0.13, blue: 0.19, alpha: 1),
               NSColor(srgbRed: 0.10, green: 0.10, blue: 0.14, alpha: 1)]
            : [NSColor(srgbRed: 0.97, green: 0.89, blue: 0.95, alpha: 1),
               NSColor(srgbRed: 0.90, green: 0.89, blue: 0.99, alpha: 1)]
        NSGradient(colors: colours)?.draw(in: bounds, angle: 35)
    }
}
#endif
