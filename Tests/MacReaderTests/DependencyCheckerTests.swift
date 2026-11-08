import XCTest
@testable import MacReader

final class DependencyCheckerTests: XCTestCase {
    private let fuseTBin = "/usr/local/bin/ntfs-3g"
    private let macFUSEBin = "/opt/homebrew/bin/ntfs-3g"
    private func links(_ path: String) -> Bool { path == fuseTBin }

    func testPrefersFuseTWhenItsNtfs3gExists() {
        let d = DependencyChecker.choose(fuseTInstalled: true, macFUSEInstalled: true,
                                         candidates: [fuseTBin, macFUSEBin], linksFuseT: links)
        XCTAssertEqual(d.backend, .fuseT)
        XCTAssertEqual(d.ntfs3gPath, fuseTBin)
        XCTAssertTrue(d.ready)
    }

    /// An ntfs-3g linked to macFUSE must never be used with FUSE-T, and vice versa.
    func testBinaryIsPairedWithItsOwnBackend() {
        let onlyMacFUSEBuild = DependencyChecker.choose(fuseTInstalled: true, macFUSEInstalled: true,
                                                        candidates: [macFUSEBin], linksFuseT: links)
        XCTAssertEqual(onlyMacFUSEBuild.backend, .macFUSE)
        XCTAssertEqual(onlyMacFUSEBuild.ntfs3gPath, macFUSEBin)

        let fuseTBuildWithoutFuseT = DependencyChecker.choose(fuseTInstalled: false, macFUSEInstalled: true,
                                                              candidates: [fuseTBin], linksFuseT: links)
        XCTAssertFalse(fuseTBuildWithoutFuseT.ready)
    }

    func testNothingInstalled() {
        let d = DependencyChecker.choose(fuseTInstalled: false, macFUSEInstalled: false,
                                         candidates: [], linksFuseT: links)
        XCTAssertNil(d.backend)
        XCTAssertFalse(d.ready)
    }

    func testFuseTOptionsKeepSafetyAndDropMacFUSEOnlyOptions() {
        let t = Mounter.mountOptions(backend: .fuseT, uid: 501, gid: 20)
        XCTAssertTrue(t.contains("-o norecover"))
        XCTAssertFalse(t.contains("-o local"))
        XCTAssertFalse(t.contains("auto_xattr"))
        let m = Mounter.mountOptions(backend: .macFUSE, uid: 501, gid: 20)
        XCTAssertTrue(m.contains("-o norecover"))
        XCTAssertTrue(m.contains("-o local"))
    }
}
