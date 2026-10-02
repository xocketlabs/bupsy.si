# Spike captures

Raw engine output captured by `make spike`, used to learn real stream shapes.

**Gitignored on purpose.** A capture comes from a real account and can contain session ids, local
paths and the machine's full tool inventory. Nothing here is committed.

To turn a capture into a test fixture: sanitise it — replace session ids, strip absolute paths,
trim tool lists — and move it to `Packages/BupsyKit/Tests/BupsyKitTests/Fixtures/`.
