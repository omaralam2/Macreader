import XCTest
@testable import MacReader

final class DiskScannerTests: XCTestCase {

    /// Shaped like real `diskutil list -plist external` output.
    private let listPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>AllDisks</key><array><string>disk4</string></array>
      <key>AllDisksAndPartitions</key>
      <array>
        <dict>
          <key>Content</key><string>GUID_partition_scheme</string>
          <key>DeviceIdentifier</key><string>disk4</string>
          <key>Partitions</key>
          <array>
            <dict>
              <key>Content</key><string>EFI</string>
              <key>DeviceIdentifier</key><string>disk4s1</string>
              <key>Size</key><integer>209715200</integer>
            </dict>
            <dict>
              <key>Content</key><string>Microsoft Basic Data</string>
              <key>DeviceIdentifier</key><string>disk4s2</string>
              <key>MountPoint</key><string>/Volumes/Backup</string>
              <key>Size</key><integer>500000000000</integer>
              <key>VolumeName</key><string>Backup</string>
            </dict>
            <dict>
              <key>Content</key><string>Microsoft Basic Data</string>
              <key>DeviceIdentifier</key><string>disk4s3</string>
              <key>MountPoint</key><string>/Volumes/USB</string>
              <key>Size</key><integer>64000000000</integer>
              <key>VolumeName</key><string>USB</string>
            </dict>
            <dict>
              <key>Content</key><string>Microsoft Basic Data</string>
              <key>DeviceIdentifier</key><string>disk4s4</string>
              <key>Size</key><integer>100000000000</integer>
            </dict>
            <dict>
              <key>Content</key><string>Microsoft Basic Data</string>
              <key>DeviceIdentifier</key><string>disk4s5;rm</string>
              <key>Size</key><integer>1</integer>
            </dict>
          </array>
        </dict>
        <dict>
          <key>Content</key><string>FDisk_partition_scheme</string>
          <key>DeviceIdentifier</key><string>disk5</string>
          <key>Partitions</key>
          <array>
            <dict>
              <key>Content</key><string>Windows_NTFS</string>
              <key>DeviceIdentifier</key><string>disk5s1</string>
              <key>Size</key><integer>2000000000000</integer>
              <key>VolumeName</key><string>Work</string>
            </dict>
          </array>
        </dict>
      </array>
    </dict>
    </plist>
    """

    private let infos: [String: [String: Any]] = [
        "disk4s2": ["FilesystemType": "ntfs", "FilesystemName": "Windows NT File System (NTFS)",
                    "VolumeName": "Backup", "VolumeUUID": "UUID-BACKUP", "TotalSize": 500_000_000_000 as Int64],
        "disk4s3": ["FilesystemType": "exfat", "FilesystemName": "ExFAT", "VolumeName": "USB"],
        "disk4s4": [:], // BitLocker: macOS cannot identify a filesystem
        "disk5s1": ["FilesystemType": "", "VolumeName": "Work", "DiskUUID": "UUID-WORK"],
    ]

    private func scan(mounts: [MountEntry], known: [String: String] = [:]) throws -> [NTFSVolume] {
        let root = try XCTUnwrap(DiskScanner.parsePlist(listPlist))
        return DiskScanner.parseVolumes(
            list: root,
            info: { self.infos[$0] ?? [:] },
            mounts: mounts,
            knownMounts: known)
    }

    func testDetectsNTFSAndIgnoresOthers() throws {
        let mounts = [
            MountEntry(from: "/dev/disk4s2", path: "/Volumes/Backup", type: "ntfs", readOnly: true),
            MountEntry(from: "/dev/disk4s3", path: "/Volumes/USB", type: "exfat", readOnly: false),
            MountEntry(from: "/dev/disk5s1", path: "/Volumes/Work", type: "macfuse", readOnly: false),
        ]
        let vols = try scan(mounts: mounts)
        let byID = Dictionary(uniqueKeysWithValues: vols.map { ($0.id, $0) })

        XCTAssertEqual(Set(byID.keys), ["disk4s2", "disk4s4", "disk5s1"],
                       "EFI, exFAT and invalid device names must be ignored")

        XCTAssertEqual(byID["disk4s2"]?.state, .readOnly)
        XCTAssertEqual(byID["disk4s2"]?.name, "Backup")
        XCTAssertEqual(byID["disk4s2"]?.key, "UUID-BACKUP")
        XCTAssertEqual(byID["disk4s2"]?.wholeDisk, "disk4")
        XCTAssertEqual(byID["disk4s2"]?.sizeBytes, 500_000_000_000)

        XCTAssertEqual(byID["disk4s4"]?.state, .unsupported, "BitLocker must never be offered for writing")

        XCTAssertEqual(byID["disk5s1"]?.state, .readWrite)
        XCTAssertEqual(byID["disk5s1"]?.mountPoint, "/Volumes/Work")
        XCTAssertEqual(byID["disk5s1"]?.key, "UUID-WORK")
    }

    func testNotMounted() throws {
        let vols = try scan(mounts: [])
        XCTAssertEqual(vols.first { $0.id == "disk4s2" }?.state, .notMounted)
    }

    func testFUSEMountWithReadOnlyFallbackIsNotWritable() throws {
        let mounts = [MountEntry(from: "/dev/disk5s1", path: "/Volumes/Work", type: "macfuse", readOnly: true)]
        let vols = try scan(mounts: mounts)
        XCTAssertEqual(vols.first { $0.id == "disk5s1" }?.state, .readOnly)
    }

    func testFUSEMountFoundThroughKnownMountPoint() throws {
        let mounts = [MountEntry(from: "ntfs-3g@macfuse0", path: "/Volumes/Work", type: "macfuse", readOnly: false)]
        let vols = try scan(mounts: mounts, known: ["disk5s1": "/Volumes/Work"])
        XCTAssertEqual(vols.first { $0.id == "disk5s1" }?.state, .readWrite)
    }

    /// FUSE-T mounts are NFS mounts from "fuse-t:/<volname>"; the device is
    /// matched through the running ntfs-3g process.
    func testFuseTMountIsWritable() throws {
        let mounts = [MountEntry(from: "fuse-t:/Work", path: "/Volumes/Work", type: "nfs", readOnly: false)]
        let vols = try scan(mounts: mounts, known: ["disk5s1": "/Volumes/Work"])
        XCTAssertEqual(vols.first { $0.id == "disk5s1" }?.state, .readWrite)

        let ro = [MountEntry(from: "fuse-t:/Work", path: "/Volumes/Work", type: "nfs", readOnly: true)]
        XCTAssertEqual(try scan(mounts: ro, known: ["disk5s1": "/Volumes/Work"]).first { $0.id == "disk5s1" }?.state,
                       .readOnly)
    }

    /// A volume without UUIDs must keep the same key whether macOS mounted it
    /// (TotalSize present) or FUSE-T did (TotalSize missing). Otherwise the
    /// safety ledger loses track and flags a cleanly ejected disk.
    func testKeyWithoutUUIDIsStableAcrossMountStates() throws {
        func key(_ info: [String: Any]) throws -> String? {
            let root = try XCTUnwrap(DiskScanner.parsePlist(listPlist))
            return DiskScanner.parseVolumes(list: root, info: { $0 == "disk5s1" ? info : (self.infos[$0] ?? [:]) },
                                            mounts: [], knownMounts: [:])
                .first { $0.id == "disk5s1" }?.key
        }
        let macOSMounted = try key(["FilesystemType": "ntfs", "VolumeName": "Work", "TotalSize": 1_999_999_000_000 as Int64])
        let fuseTMounted = try key(["FilesystemType": "ntfs", "VolumeName": "Work"])
        XCTAssertNotNil(macOSMounted)
        XCTAssertEqual(macOSMounted, fuseTMounted)
    }

    func testOrdinaryNFSShareIsNotTreatedAsOurs() {
        XCTAssertFalse(MountEntry(from: "server:/share", path: "/Volumes/share", type: "nfs", readOnly: false).isFUSE)
        XCTAssertTrue(MountEntry(from: "fuse-t:/X", path: "/Volumes/X", type: "nfs", readOnly: false).isFUSE)
    }

    func testParseNTFS3GProcesses() {
        let ps = """
        /sbin/launchd
        /opt/homebrew/bin/ntfs-3g /dev/disk5s1 /Volumes/My Work -o local -o allow_other
        ntfs-3g /dev/disk6s2 /Volumes/Other -o local
        /usr/bin/grep ntfs-3g /dev/disk7s1 /Volumes/Fake -o x
        /bin/sh -c echo ntfs-3g
        """
        let map = DiskScanner.parseNTFS3GProcesses(ps)
        XCTAssertEqual(map["disk5s1"], "/Volumes/My Work")
        XCTAssertEqual(map["disk6s2"], "/Volumes/Other")
        XCTAssertNil(map["disk7s1"], "only real ntfs-3g processes count")
    }

    func testMountTableReadsRealSystem() {
        let table = DiskScanner.mountTable()
        XCTAssertTrue(table.contains { $0.path == "/" }, "root filesystem must be listed")
    }
}
