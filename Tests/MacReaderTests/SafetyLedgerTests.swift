import XCTest
@testable import MacReader

final class SafetyLedgerTests: XCTestCase {

    private func vol(_ key: String, _ state: VolumeState) -> NTFSVolume {
        NTFSVolume(id: "disk4s2", wholeDisk: "disk4", name: key, sizeBytes: 1, key: key,
                   mountPoint: state == .notMounted ? nil : "/Volumes/\(key)", state: state)
    }

    func testUnpluggedWhileWritableIsFlagged() {
        let old = SafetyLedger(rwActive: ["A"], needsCheck: [])
        let new = SafetyLedger.reconcile(old, volumes: [], transitioning: [], isFirstScan: false)
        XCTAssertEqual(new, SafetyLedger(rwActive: [], needsCheck: ["A"]))
    }

    func testCleanUnmountWhileWatchingIsNotFlagged() {
        let old = SafetyLedger(rwActive: ["A"], needsCheck: [])
        let new = SafetyLedger.reconcile(old, volumes: [vol("A", .readOnly)], transitioning: [], isFirstScan: false)
        XCTAssertEqual(new, SafetyLedger(rwActive: [], needsCheck: []))
    }

    func testUnknownHistoryAtLaunchIsFlagged() {
        let old = SafetyLedger(rwActive: ["A"], needsCheck: [])
        let new = SafetyLedger.reconcile(old, volumes: [vol("A", .readOnly)], transitioning: [], isFirstScan: true)
        XCTAssertEqual(new, SafetyLedger(rwActive: [], needsCheck: ["A"]))
    }

    func testStillWritableAtLaunchIsFine() {
        let old = SafetyLedger(rwActive: ["A"], needsCheck: [])
        let new = SafetyLedger.reconcile(old, volumes: [vol("A", .readWrite)], transitioning: [], isFirstScan: true)
        XCTAssertEqual(new, old)
    }

    func testOwnEjectIsIgnored() {
        let old = SafetyLedger(rwActive: ["A"], needsCheck: [])
        let new = SafetyLedger.reconcile(old, volumes: [], transitioning: ["A"], isFirstScan: false)
        XCTAssertEqual(new, old)
    }

    func testWritableVolumeIsTracked() {
        let old = SafetyLedger(rwActive: [], needsCheck: [])
        let new = SafetyLedger.reconcile(old, volumes: [vol("B", .readWrite)], transitioning: [], isFirstScan: false)
        XCTAssertEqual(new.rwActive, ["B"])
    }

    func testFlagStaysUntilUserConfirms() {
        let old = SafetyLedger(rwActive: [], needsCheck: ["A"])
        let new = SafetyLedger.reconcile(old, volumes: [vol("A", .readOnly)], transitioning: [], isFirstScan: false)
        XCTAssertEqual(new.needsCheck, ["A"])
    }
}
