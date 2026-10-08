import LocalAuthentication

/// Face ID, Touch ID or the passcode before a request is allowed.
///
/// Allow runs something on the person's Mac, from wherever the phone is. An unlocked phone left
/// on a table, or one handed to a child, shouldn't be enough to run a shell command at home.
/// Deny needs no check: refusing never does harm.
///
/// A phone with no passcode can't prove who's holding it, so it can't allow anything. That is
/// deliberate; the person can still allow from the Mac.
enum OwnerCheck {
    enum Outcome: Equatable {
        case confirmed
        /// The person backed out. Nothing to say.
        case cancelled
        /// It can't be done on this phone, and the message says why.
        case unavailable(String)
    }

    static func confirm(_ reason: String) async -> Outcome {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? .confirmed : .cancelled
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback:
                return .cancelled
            case .passcodeNotSet:
                return .unavailable("Set a passcode on this iPhone to allow requests from it. You can still allow on your Mac.")
            default:
                return .unavailable(error.localizedDescription)
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
