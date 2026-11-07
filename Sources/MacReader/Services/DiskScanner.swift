import Foundation

struct MountEntry {
    let from: String
    let path: String
    let type: String
    let readOnly: Bool

    var isFUSE: Bool {
        let t = type.lowercased()
        return t.contains("fuse")
    }
}

/// Finds NTFS partitions on external disks. Read-only: it never changes anything.
enum DiskScanner {
    private static let diskutil = "/usr/sbin/diskutil"

    /// Partition types that Windows uses for NTFS (and, sadly, also exFAT/FAT,
    /// so the real filesystem is checked with `diskutil info` afterwards).
    private static let windowsContents: Set<String> = [
        "Microsoft Basic Data",
        "Windows_NTFS",
    ]

    /// - Parameter knownMounts: device id -> mount point for mounts MacReader made.
    static func scan(knownMounts: [String: String]) -> [NTFSVolume] {
        let list = Shell.run(diskutil, ["list", "-plist", "external"])
        guard list.ok,
              let root = parsePlist(list.stdout),
              let disks = root["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        let mounts = mountTable()
        // Also learn device -> mount point from running ntfs-3g processes, so
        // writable mounts are recognised even after MacReader restarts.
        let allKnownMounts = knownMounts.merging(ntfs3gMounts()) { ours, _ in ours }
        var result: [NTFSVolume] = []

        for disk in disks {
            guard let whole = disk["DeviceIdentifier"] as? String,
                  NTFSVolume.isValidDeviceName(whole) else { continue }

            var partitions = disk["Partitions"] as? [[String: Any]] ?? []
            if partitions.isEmpty { partitions = [disk] } // disk without partition table

            for part in partitions {
                guard let id = part["DeviceIdentifier"] as? String,
                      NTFSVolume.isValidDeviceName(id) else { continue }
                let content = part["Content"] as? String ?? ""

                let mount = mounts.first { $0.from == "/dev/\(id)" }
                    ?? allKnownMounts[id].flatMap { mp in mounts.first { $0.path == mp } }
                let mountedByUs = mount?.isFUSE ?? false

                guard windowsContents.contains(content) || mountedByUs else { continue }

                let info = parsePlist(Shell.run(diskutil, ["info", "-plist", id]).stdout) ?? [:]
                let fsType = (info["FilesystemType"] as? String ?? "").lowercased()
                let fsName = (info["FilesystemName"] as? String ?? "")
                    + " " + (info["FilesystemUserVisibleName"] as? String ?? "")
                let isNTFS = fsType == "ntfs" || fsName.uppercased().contains("NTFS") || mountedByUs

                let state: VolumeState
                if isNTFS {
                    if let mount, mount.isFUSE, !mount.readOnly {
                        state = .readWrite
                    } else if mount != nil {
                        state = .readOnly
                    } else {
                        state = .notMounted
                    }
                } else if fsType.isEmpty {
                    // Windows partition with no filesystem macOS can identify:
                    // most likely BitLocker. Show it, but never touch it.
                    state = .unsupported
                } else {
                    continue // exFAT / FAT32: macOS already reads and writes these.
                }

                let name = (info["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (part["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "NTFS"
                let size = int64(info["TotalSize"]) ?? int64(info["Size"]) ?? int64(part["Size"]) ?? 0
                let key = (info["VolumeUUID"] as? String)
                    ?? (info["DiskUUID"] as? String)
                    ?? "\(name)|\(size)"

                result.append(NTFSVolume(
                    id: id,
                    wholeDisk: whole,
                    name: name,
                    sizeBytes: size,
                    key: key,
                    mountPoint: mount?.path,
                    state: state
                ))
            }
        }
        return result
    }

    static func mountTable() -> [MountEntry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        return (0..<Int(count)).map { index in
            var fs = buffer[index]
            let from = withUnsafeBytes(of: &fs.f_mntfromname) { cString($0) }
            let path = withUnsafeBytes(of: &fs.f_mntonname) { cString($0) }
            let type = withUnsafeBytes(of: &fs.f_fstypename) { cString($0) }
            let readOnly = (fs.f_flags & UInt32(MNT_RDONLY)) != 0
            return MountEntry(from: from, path: path, type: type, readOnly: readOnly)
        }
    }

    /// "…/ntfs-3g /dev/disk4s1 /Volumes/My Disk -o …" -> ["disk4s1": "/Volumes/My Disk"]
    static func ntfs3gMounts() -> [String: String] {
        let out = Shell.run("/bin/ps", ["-axo", "args="]).stdout
        var map: [String: String] = [:]
        let regex = try? NSRegularExpression(pattern: #"^\S*ntfs-3g /dev/(disk[0-9]+s?[0-9]*) (/Volumes/.+?) -o "#)
        for line in out.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex?.firstMatch(in: text, range: range),
                  let dev = Range(match.range(at: 1), in: text),
                  let mp = Range(match.range(at: 2), in: text) else { continue }
            map[String(text[dev])] = String(text[mp])
        }
        return map
    }

    private static func cString(_ raw: UnsafeRawBufferPointer) -> String {
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parsePlist(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}
