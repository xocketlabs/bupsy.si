import Foundation

extension Process {
    /// Starts the process and returns a function that blocks until it has exited.
    ///
    /// Use instead of `run()` + `waitUntilExit()`. That pair waits on the *current* run loop,
    /// which a background or concurrency-pool thread does not run, so it can wait forever for a
    /// process that has already gone. A termination handler set before launch cannot miss the exit.
    func launchForWaiting() throws -> () -> Void {
        let exited = DispatchSemaphore(value: 0)
        terminationHandler = { _ in exited.signal() }
        try run()
        return { exited.wait() }
    }
}
