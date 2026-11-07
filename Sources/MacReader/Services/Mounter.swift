import Foundation

enum MountError: Error {
    case cancelled
    case invalidDevice
    /// The partition's boot sector is not NTFS (e.g. BitLocker). Nothing was changed.
    case notNTFS
    /// Files are still open on the volume. Nothing was unmounted.
    case busy([String])
    /// Windows left the volume hibernated / with unflushed metadata.
    /// ntfs-3g refused to mount it read/write; it was put back read-only.
    case windowsUnclean(String)
    /// macFUSE is installed but not loaded/allowed.
    case fuseProblem(String)
    /// ntfs-3g did not finish flushing in time; the disk was NOT ejected.
    case stillWriting
    case failed(String)
}

/// Everything here runs as root through `Shell.runAsAdmin`.
///
/// Data-safety rules (do not relax these):
///  * never format, repair (ntfsfix/chkdsk) or remove a hibernation file;
///  * always mount with `norecover` so an unclean volume is refused, not "fixed";
///  * never force an unmount (`umount -f`, `diskutil unmount force`);
///  * verify the NTFS signature in the boot sector before mounting;
///  * wait for the ntfs-3g process to exit (all data flushed) before ejecting.
enum Mounter {

    // MARK: - Enable write

    /// Re-mounts an NTFS partition read/write with ntfs-3g. Returns the mount point.
    static func enableWrite(_ volume: NTFSVolume, ntfs3g: String) throws -> String {
        guard NTFSVolume.isValidDeviceName(volume.id) else { throw MountError.invalidDevice }

        let mountPoint = "/Volumes/" + sanitizedName(volume.name)
        let volName = sanitizedName(volume.name)

        let script = """
        DEV=\(Shell.quote(volume.devicePath))
        MP=\(Shell.quote(mountPoint))
        VN=\(Shell.quote(volName))
        NTFS3G=\(Shell.quote(ntfs3g))

        # 1) Safety: only ever touch a real NTFS boot sector (BitLocker = "-FVE-FS-").
        SIG=$(/bin/dd if="$DEV" bs=512 count=1 2>/dev/null | /bin/dd bs=1 skip=3 count=8 2>/dev/null)
        if [ "$SIG" != "NTFS    " ]; then echo "MACREADER_NOT_NTFS" >&2; exit 64; fi

        # 2) Unmount the read-only mount made by macOS (never forced).
        if /sbin/mount | /usr/bin/grep -q "^$DEV on "; then
          /usr/sbin/diskutil unmount "$DEV" >/dev/null 2>&1 || { echo "MACREADER_BUSY" >&2; exit 66; }
        fi

        # 3) Mount read/write. norecover = refuse unclean volumes instead of resetting the journal.
        if [ -e "$MP" ] && [ -n "$(/bin/ls -A "$MP" 2>/dev/null)" ]; then MP="$MP ($(/usr/bin/basename "$DEV"))"; fi
        /bin/mkdir -p "$MP"
        if ! OUT=$("$NTFS3G" "$DEV" "$MP" -o local -o allow_other -o auto_xattr -o norecover -o uid=\(getuid()) -o gid=\(getgid()) -o volname="$VN" 2>&1); then
          /bin/rmdir "$MP" 2>/dev/null
          /usr/sbin/diskutil mount readOnly "$DEV" >/dev/null 2>&1 || /usr/sbin/diskutil mount "$DEV" >/dev/null 2>&1
          echo "MACREADER_MOUNT_FAILED $OUT" >&2
          exit 65
        fi
        echo "$MP"
        """

        switch Shell.runAsAdmin(script) {
        case .success(let output):
            let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            return lines.last.map(String.init) ?? mountPoint
        case .cancelled:
            throw MountError.cancelled
        case .failure(let message):
            throw parseFailure(message)
        }
    }

    // MARK: - Back to read-only

    static func disableWrite(_ volume: NTFSVolume) throws {
        guard NTFSVolume.isValidDeviceName(volume.id), let mp = volume.mountPoint else {
            throw MountError.invalidDevice
        }
        let pair: (String, String) = (volume.devicePath, mp)
        let script = safeUnmountScript(devices: [pair]) + """

        /usr/sbin/diskutil mount readOnly \(Shell.quote(volume.devicePath)) >/dev/null 2>&1 || true
        """
        try runAdmin(script)
    }

    // MARK: - Eject

    /// Safely ejects a whole disk. Writable partitions are flushed and unmounted
    /// first (without force); if anything is busy, nothing is ejected.
    static func eject(wholeDisk: String, writable: [NTFSVolume], readOnlyMountPoints: [String]) throws {
        guard NTFSVolume.isValidDeviceName(wholeDisk) else { throw MountError.invalidDevice }

        let pairs = writable.compactMap { v -> (String, String)? in
            guard NTFSVolume.isValidDeviceName(v.id), let mp = v.mountPoint else { return nil }
            return (v.devicePath, mp)
        }

        if pairs.isEmpty {
            // Only read-only mounts: no password needed.
            _ = Shell.run("/bin/sync", [])
            let result = Shell.run("/usr/sbin/diskutil", ["eject", wholeDisk])
            if !result.ok {
                throw MountError.busy(openProcesses(on: readOnlyMountPoints))
            }
            return
        }

        let script = safeUnmountScript(devices: pairs) + """

        /bin/sync
        /usr/sbin/diskutil eject \(Shell.quote(wholeDisk)) >/dev/null 2>&1 || { echo "MACREADER_BUSY" >&2; exit 66; }
        """
        try runAdmin(script)
    }

    // MARK: - Helpers

    /// sync -> umount (no force) -> wait until ntfs-3g has exited (= everything flushed).
    private static func safeUnmountScript(devices: [(String, String)]) -> String {
        var script = "/bin/sync\n"
        for (dev, mp) in devices {
            script += """
            DEV=\(Shell.quote(dev))
            MP=\(Shell.quote(mp))
            if /sbin/mount | /usr/bin/grep -qF -- " on $MP ("; then
              if ! /sbin/umount "$MP" 2>/dev/null; then
                echo "MACREADER_BUSY" >&2
                /usr/sbin/lsof -Fc "$MP" 2>/dev/null | /usr/bin/sed -n 's/^c//p' | /usr/bin/sort -u >&2
                exit 66
              fi
            fi
            N=0
            while /usr/bin/pgrep -f "^[^ ]*ntfs-3g $DEV " >/dev/null 2>&1; do
              N=$((N+1)); if [ $N -gt 60 ]; then echo "MACREADER_STILL_WRITING" >&2; exit 67; fi
              /bin/sleep 0.5
            done

            """
        }
        return script
    }

    private static func runAdmin(_ script: String) throws {
        switch Shell.runAsAdmin(script) {
        case .success: return
        case .cancelled: throw MountError.cancelled
        case .failure(let message): throw parseFailure(message)
        }
    }

    static func parseFailure(_ message: String) -> MountError {
        if message.contains("MACREADER_NOT_NTFS") { return .notNTFS }
        if message.contains("MACREADER_STILL_WRITING") { return .stillWriting }
        if let range = message.range(of: "MACREADER_BUSY") {
            let names = message[range.upperBound...]
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .busy(names)
        }
        if let range = message.range(of: "MACREADER_MOUNT_FAILED") {
            let detail = String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = detail.lowercased()
            let uncleanHints = ["hibernat", "unsafe state", "fast restart", "unclean", "metadata kept", "windows cache"]
            if uncleanHints.contains(where: lower.contains) { return .windowsUnclean(detail) }
            if lower.contains("fuse") { return .fuseProblem(detail) }
            return .failed(detail)
        }
        return .failed(message)
    }

    /// Names of processes that have files open on the given mount points (current user only).
    static func openProcesses(on mountPoints: [String]) -> [String] {
        var names = Set<String>()
        for mp in mountPoints {
            let out = Shell.run("/usr/sbin/lsof", ["-Fc", mp]).stdout
            for line in out.split(separator: "\n") where line.hasPrefix("c") {
                names.insert(String(line.dropFirst()))
            }
        }
        return names.sorted()
    }

    /// Safe folder / volume name: no slashes, colons, commas or quotes.
    static func sanitizedName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:,'\"\\\n\r\t")
        let cleaned = name.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "NTFS" : cleaned
    }
}
