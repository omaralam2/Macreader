import Foundation

/// Remembers which volumes are open for writing, so that a volume unplugged
/// without a clean unmount is flagged and must be checked (chkdsk on Windows)
/// before MacReader will write to it again.
struct SafetyLedger: Equatable {
    /// Volume keys currently mounted read/write.
    var rwActive: Set<String>
    /// Volume keys that must be checked on Windows before writing again.
    var needsCheck: Set<String>

    /// Pure function: given the previous ledger and a fresh scan, returns the new ledger.
    /// - Parameters:
    ///   - transitioning: keys MacReader itself is currently ejecting/unmounting (ignored).
    ///   - isFirstScan: true for the first scan after launch, when we could not watch
    ///     what happened while the app was closed, so we are conservative.
    static func reconcile(
        _ old: SafetyLedger,
        volumes: [NTFSVolume],
        transitioning: Set<String>,
        isFirstScan: Bool
    ) -> SafetyLedger {
        var ledger = old

        for key in old.rwActive where !transitioning.contains(key) {
            if let volume = volumes.first(where: { $0.key == key }) {
                if volume.state != .readWrite {
                    // Unmounted while we were watching (e.g. Finder eject) = clean.
                    // If it happened while the app was closed we cannot know.
                    if isFirstScan { ledger.needsCheck.insert(key) }
                    ledger.rwActive.remove(key)
                }
            } else {
                // Disappeared while writable: unsafe removal.
                ledger.needsCheck.insert(key)
                ledger.rwActive.remove(key)
            }
        }

        // Any volume we see mounted read/write is tracked from now on.
        for volume in volumes where volume.state == .readWrite && !transitioning.contains(volume.key) {
            ledger.rwActive.insert(volume.key)
        }

        return ledger
    }
}
