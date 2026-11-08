import XCTest
@testable import MacReader

final class MounterTests: XCTestCase {

    private let volume = NTFSVolume(
        id: "disk4s2", wholeDisk: "disk4", name: "My Backup", sizeBytes: 1_000,
        key: "UUID-1", mountPoint: "/Volumes/My Backup", state: .readOnly)

    private var enableScript: String {
        Mounter.enableWriteScript(volume: volume, ntfs3g: "/opt/homebrew/bin/ntfs-3g", uid: 501, gid: 20)
    }
    private var disableScript: String {
        Mounter.disableWriteScript(device: "/dev/disk4s2", mountPoint: "/Volumes/My Backup")
    }
    private var ejectScript: String {
        Mounter.ejectScript(wholeDisk: "disk4", writable: [("/dev/disk4s2", "/Volumes/My Backup")])
    }

    // MARK: - Data-safety rules

    func testScriptsAreValidShell() throws {
        for script in [enableScript, disableScript, ejectScript] {
            let result = try runSh(["-n"], script: script)
            XCTAssertEqual(result.status, 0, "syntax error: \(result.stderr)\n\(script)")
        }
    }

    func testScriptsNeverForceRepairOrFormat() {
        let forbidden = ["force", "umount -f", "remove_hiberfile", "ntfsfix", "mkntfs", "newfs",
                         "eraseDisk", "eraseVolume", "chkdsk", "-o recover", "rm -rf", "rm -r"]
        for script in [enableScript, disableScript, ejectScript] {
            // Only lines that actually run (comments may explain *why* we never force).
            let commands = script.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .joined(separator: "\n")
            XCTAssertFalse(commands.isEmpty)
            for word in forbidden {
                XCTAssertFalse(commands.contains(word), "script must not run \"\(word)\":\n\(commands)")
            }
        }
    }

    /// ntfs-3g may exit 0 with no mount (macFUSE blocked). Success must only be
    /// reported after a real mount exists, or the user writes to the Mac's own disk.
    func testSuccessRequiresARealMount() throws {
        let mountCheck = try XCTUnwrap(enableScript.range(of: "ntfs-3g did not create a mount"))
        let ntfs3g = try XCTUnwrap(enableScript.range(of: "\"$NTFS3G\" \"$DEV\""))
        let success = try XCTUnwrap(enableScript.range(of: "echo \"$MP\"", options: .backwards))
        XCTAssertLessThan(ntfs3g.lowerBound, mountCheck.lowerBound)
        XCTAssertLessThan(mountCheck.lowerBound, success.lowerBound)
        guard case .fuseProblem = Mounter.parseFailure(
            "MACREADER_MOUNT_FAILED fuse: ntfs-3g did not create a mount (is the macFUSE extension allowed?)") else {
            return XCTFail("a missing mount must be reported as a macFUSE problem")
        }
    }

    func testEnableScriptRefusesUncleanVolumes() {
        XCTAssertTrue(enableScript.contains("-o norecover"))
        // ntfs-3g silently falls back to read-only on hibernated volumes; we must detect it.
        XCTAssertTrue(enableScript.contains("read-only"))
        XCTAssertTrue(enableScript.contains("-o uid=501 -o gid=20"))
    }

    func testSignatureIsCheckedBeforeMounting() throws {
        let sigCheck = try XCTUnwrap(enableScript.range(of: "MACREADER_NOT_NTFS"))
        let mount = try XCTUnwrap(enableScript.range(of: "\"$NTFS3G\" \"$DEV\""))
        let unmount = try XCTUnwrap(enableScript.range(of: "diskutil unmount"))
        // macOS's NTFS driver holds the device while mounted, so the read-only
        // mount is released first, then the signature is checked, then ntfs-3g mounts.
        XCTAssertLessThan(unmount.lowerBound, sigCheck.lowerBound)
        XCTAssertLessThan(sigCheck.lowerBound, mount.lowerBound)
        // Every refusal after the unmount must put the volume back read-only.
        for marker in ["MACREADER_NOT_NTFS", "MACREADER_CANT_READ"] {
            let line = try XCTUnwrap(enableScript.split(separator: "\n").first { $0.contains(marker) })
            XCTAssertTrue(line.contains("diskutil mount readOnly"), "\(marker) must remount read-only")
        }
    }

    func testEjectWaitsForNtfs3gBeforeEjecting() throws {
        let wait = try XCTUnwrap(ejectScript.range(of: "pgrep"))
        let eject = try XCTUnwrap(ejectScript.range(of: "diskutil eject"))
        XCTAssertLessThan(wait.lowerBound, eject.lowerBound)
    }

    /// Runs the real signature-check lines from the script against fake boot sectors.
    func testBootSectorSignatureCheck() throws {
        let lines = enableScript.split(separator: "\n").filter {
            $0.hasPrefix("if ! RDERR=") || $0.hasPrefix("SIG=") || $0.hasPrefix("if [ \"$SIG\"")
        }
        XCTAssertEqual(lines.count, 3)

        // A device that cannot be read must be reported as unreadable, not as "not NTFS".
        let missing = "DEV='/nonexistent/macreader-dev'\n" + lines.joined(separator: "\n") + "\necho OK\n"
        XCTAssertEqual(try runSh([], script: missing).status, 68)

        func check(_ sector: [UInt8]) throws -> Int32 {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("macreader-\(UUID().uuidString).img")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(sector + [UInt8](repeating: 0, count: 600)).write(to: url)
            let script = "DEV=\(Shell.quote(url.path))\n" + lines.joined(separator: "\n") + "\necho OK\n"
            return try runSh([], script: script).status
        }

        let ntfs: [UInt8] = [0xEB, 0x52, 0x90] + Array("NTFS    ".utf8)
        let bitlocker: [UInt8] = [0xEB, 0x58, 0x90] + Array("-FVE-FS-".utf8)
        let exfat: [UInt8] = [0xEB, 0x76, 0x90] + Array("EXFAT   ".utf8)
        XCTAssertEqual(try check(ntfs), 0)
        XCTAssertEqual(try check(bitlocker), 64)
        XCTAssertEqual(try check(exfat), 64)
    }

    // MARK: - Error parsing

    func testParseFailure() {
        XCTAssertEqual(Mounter.parseFailure("MACREADER_NOT_NTFS"), .notNTFS)
        XCTAssertEqual(Mounter.parseFailure("MACREADER_CANT_READ dd: /dev/disk4s1: Operation not permitted"),
                       .cantRead("dd: /dev/disk4s1: Operation not permitted"))
        XCTAssertEqual(Mounter.parseFailure("MACREADER_STILL_WRITING"), .stillWriting)
        XCTAssertEqual(Mounter.parseFailure("MACREADER_BUSY\nPreview\rFinder\n"), .busy(["Preview", "Finder"]))
        XCTAssertEqual(Mounter.parseFailure("MACREADER_BUSY"), .busy([]))

        let hibernated = """
        MACREADER_MOUNT_FAILED Windows is hibernated, refused to mount.
        Falling back to read-only mount because the NTFS partition is in an
        unsafe state. Please resume and shutdown Windows fully (no hibernation
        or fast restarting.)
        """
        guard case .windowsUnclean = Mounter.parseFailure(hibernated) else {
            return XCTFail("hibernated volume must be reported as unclean")
        }
        let unclean = "MACREADER_MOUNT_FAILED The disk contains an unclean file system (0, 0).\nMetadata kept in Windows cache, refused to mount."
        guard case .windowsUnclean = Mounter.parseFailure(unclean) else {
            return XCTFail("unclean volume must be reported as unclean")
        }
        guard case .windowsUnclean = Mounter.parseFailure("MACREADER_MOUNT_FAILED unsafe state (read-only fallback) ") else {
            return XCTFail("read-only fallback must be reported as unclean")
        }
        guard case .fuseProblem = Mounter.parseFailure("MACREADER_MOUNT_FAILED fuse: device not found") else {
            return XCTFail("fuse errors must be detected")
        }
        guard case .failed = Mounter.parseFailure("something else") else {
            return XCTFail("unknown errors must be .failed")
        }
    }

    // MARK: - Names

    func testSanitizedName() {
        XCTAssertEqual(Mounter.sanitizedName("My Disk"), "My Disk")
        XCTAssertEqual(Mounter.sanitizedName("a/b:c,d'e\"f\\g"), "a_b_c_d_e_f_g")
        XCTAssertEqual(Mounter.sanitizedName("line\nbreak"), "line_break")
        XCTAssertEqual(Mounter.sanitizedName(""), "NTFS")
        XCTAssertEqual(Mounter.sanitizedName("   "), "NTFS")
        XCTAssertEqual(Mounter.sanitizedName(".hidden"), "NTFS")
        XCTAssertEqual(Mounter.sanitizedName("هارد عمر"), "هارد عمر")
        XCTAssertFalse(Mounter.sanitizedName("../../etc").contains("/"))
    }

    func testDeviceNameValidation() {
        XCTAssertTrue(NTFSVolume.isValidDeviceName("disk4"))
        XCTAssertTrue(NTFSVolume.isValidDeviceName("disk12s3"))
        XCTAssertFalse(NTFSVolume.isValidDeviceName("disk4s1;rm -rf /"))
        XCTAssertFalse(NTFSVolume.isValidDeviceName("disk4s1 "))
        XCTAssertFalse(NTFSVolume.isValidDeviceName("../disk4"))
        XCTAssertFalse(NTFSVolume.isValidDeviceName("rdisk4"))
        XCTAssertFalse(NTFSVolume.isValidDeviceName(""))
    }
}

// MARK: - Helpers

struct ShResult { let status: Int32; let stdout: String; let stderr: String }

func runSh(_ flags: [String], script: String) throws -> ShResult {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("macreader-\(UUID().uuidString).sh")
    defer { try? FileManager.default.removeItem(at: url) }
    try script.write(to: url, atomically: true, encoding: .utf8)
    let r = Shell.run("/bin/sh", flags + [url.path])
    return ShResult(status: r.status, stdout: r.stdout, stderr: r.stderr)
}
