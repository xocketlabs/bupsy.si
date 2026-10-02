#if canImport(IOKit)
import Foundation
import IOKit.pwr_mgt

/// Holds the Mac awake while a bot is working.
///
/// This fixes a real failure rather than adding a nicety: an agent run lasting ten minutes is
/// killed at minute three when the Mac idles to sleep, leaving a half-finished task and a
/// truncated transcript. A half-finished run is worse than one that never started, because the
/// user has to work out what did and did not happen.
///
/// **It prevents sleep; it cannot end it.** Nothing here wakes a sleeping Mac — that needs root,
/// confirmed at the API rather than inferred: `IOPMSchedulePowerEvent` returns
/// `kIOReturnNotPrivileged` (0xe00002c1) from an ordinary process. Waking is tier 2b and needs a
/// privileged helper; see docs/04-wake-helper.md.
///
/// A closed lid on battery sleeps regardless of any assertion, so this helps a Mac that is awake
/// or idling, not one in a bag.
public final class PowerAssertion: @unchecked Sendable {
    private var id: IOPMAssertionID = 0
    private var held = false
    private let lock = NSLock()
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    /// Takes the assertion. Idempotent, so a caller does not have to track whether it already has one.
    @discardableResult
    public func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !held else { return true }

        // PreventUserIdleSystemSleep, not PreventSystemSleep: we are saying "the user is
        // effectively busy", not overriding an explicit sleep. Closing the lid or choosing Sleep
        // still works, which is the behaviour someone would expect and the polite thing to do.
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else { return false }
        id = assertionID
        held = true
        return true
    }

    /// Releases it. Also idempotent — and called from `deinit`, because an assertion leaked by a
    /// crashed run would keep someone's laptop awake all night with no indication why.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
        id = 0
    }

    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    deinit { release() }
}
#endif
