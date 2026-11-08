import Foundation

enum MountError: Error, Equatable {
    case cancelled
    case invalidDevice
    /// The partition's boot sector is not NTFS (e.g. BitLocker). Nothing was changed.
    case notNTFS
    /// The boot sector could not be read at all (usually macOS privacy:
    /// MacReader needs Full Disk Access). Nothing was changed.
    case cantRead(String)
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

/// Everything here runs as root through `Shell.runAsAdmin` (sudo + native password dialog).
///
/// Data-safety rules (enforced by unit tests, do not relax these):
///  * never format, repair (ntfsfix/chkdsk) or remove a hibernation file;
///  * always mount with `norecover` so an unclean volume is refused, not "fixed";
///  * never force an unmount (`umount -f`, `diskutil unmount force`);
///  * verify the NTFS signature in the boot sector before mounting;
///  * wait for the ntfs-3g process to exit (all data flushed) before ejecting.
enum Mounter {

    // MARK: - Actions

    /// Re-mounts an NTFS partition read/write with ntfs-3g. Returns the mount point.
    static func enableWrite(_ volume: NTFSVolume, ntfs3g: String, backend: FUSEBackend) throws -> String {
        guard NTFSVolume.isValidDeviceName(volume.id) else { throw MountError.invalidDevice }
        let script = enableWriteScript(volume: volume, ntfs3g: ntfs3g, uid: getuid(), gid: getgid(), backend: backend)

        switch Shell.runAsAdmin(script) {
        case .success(let output):
            let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            return lines.last.map { String($0) } ?? defaultMountPoint(for: volume)
        case .cancelled:
            throw MountError.cancelled
        case .failure(let message):
            throw parseFailure(message)
        }
    }

    /// Unmounts the ntfs-3g mount and lets macOS mount it read-only again.
    static func disableWrite(_ volume: NTFSVolume) throws {
        guard NTFSVolume.isValidDeviceName(volume.id), let mp = volume.mountPoint else {
            throw MountError.invalidDevice
        }
        try runAdmin(disableWriteScript(device: volume.devicePath, mountPoint: mp))
    }

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

        try runAdmin(ejectScript(wholeDisk: wholeDisk, writable: pairs))
    }

    // MARK: - Scripts (pure: they only build text, so they can be unit-tested)

    static func defaultMountPoint(for volume: NTFSVolume) -> String {
        "/Volumes/" + sanitizedName(volume.name)
    }

    /// Backend-specific ntfs-3g options. Both always include `norecover`.
    /// FUSE-T mounts over local NFS, where macFUSE's `local` / `auto_xattr`
    /// options don't apply (macOS stores extended attributes as ._ files there).
    static func mountOptions(backend: FUSEBackend, uid: uid_t, gid: gid_t) -> String {
        let common = "-o allow_other -o norecover -o uid=\(uid) -o gid=\(gid)"
        switch backend {
        case .fuseT: return common
        case .macFUSE: return "-o local " + common + " -o auto_xattr"
        }
    }

    static func enableWriteScript(volume: NTFSVolume, ntfs3g: String, uid: uid_t, gid: gid_t,
                                  backend: FUSEBackend = .fuseT) -> String {
        """
        DEV=\(Shell.quote(volume.devicePath))
        MP=\(Shell.quote(defaultMountPoint(for: volume)))
        VN=\(Shell.quote(sanitizedName(volume.name)))
        NTFS3G=\(Shell.quote(ntfs3g))

        # 1) Unmount the read-only mount made by macOS (never forced). macOS's own NTFS
        #    driver keeps the device open while mounted ("Resource busy"), so the boot
        #    sector can only be read after this. Read-only unmount/remount writes nothing.
        if /sbin/mount | /usr/bin/grep -q "^$DEV on "; then
          /usr/sbin/diskutil unmount "$DEV" >/dev/null 2>&1 || { echo "MACREADER_BUSY" >&2; exit 66; }
        fi

        # 2) Safety: only ever touch a real NTFS boot sector (BitLocker = "-FVE-FS-").
        #    A failed read must not be reported as "not NTFS". On any refusal, put the
        #    volume back read-only exactly as it was.
        if ! RDERR=$(/bin/dd if="$DEV" of=/dev/null bs=512 count=1 2>&1); then /usr/sbin/diskutil mount readOnly "$DEV" >/dev/null 2>&1; echo "MACREADER_CANT_READ $RDERR" >&2; exit 68; fi
        SIG=$(/bin/dd if="$DEV" bs=512 count=1 2>/dev/null | /bin/dd bs=1 skip=3 count=8 2>/dev/null)
        if [ "$SIG" != "NTFS    " ]; then /usr/sbin/diskutil mount readOnly "$DEV" >/dev/null 2>&1; echo "MACREADER_NOT_NTFS" >&2; exit 64; fi

        # 3) Mount read/write. norecover = refuse unclean volumes instead of resetting the journal.
        if [ -e "$MP" ] && [ -n "$(/bin/ls -A "$MP" 2>/dev/null)" ]; then MP="$MP ($(/usr/bin/basename "$DEV"))"; fi
        /bin/mkdir -p "$MP"
        if ! OUT=$("$NTFS3G" "$DEV" "$MP" \(mountOptions(backend: backend, uid: uid, gid: gid)) -o volname="$VN" 2>&1); then
          /bin/rmdir "$MP" 2>/dev/null
          /usr/sbin/diskutil mount readOnly "$DEV" >/dev/null 2>&1 || /usr/sbin/diskutil mount "$DEV" >/dev/null 2>&1
          echo "MACREADER_MOUNT_FAILED $OUT" >&2
          exit 65
        fi

        # 4) ntfs-3g can exit 0 without any mount appearing (e.g. the macFUSE kernel
        #    extension is blocked). Then $MP is just a plain folder on the Mac's own
        #    disk: never report success, remove it and put the volume back read-only.
        N=0
        while ! /sbin/mount | /usr/bin/grep -qF -- " on $MP (" && [ $N -lt 10 ]; do N=$((N+1)); /bin/sleep 0.5; done
        if ! /sbin/mount | /usr/bin/grep -qF -- " on $MP ("; then
          /bin/rmdir "$MP" 2>/dev/null
          /usr/sbin/diskutil mount readOnly "$DEV" >/dev/null 2>&1 || true
          echo "MACREADER_MOUNT_FAILED fuse: ntfs-3g did not create a mount (is the macFUSE extension allowed?) $OUT" >&2
          exit 65
        fi

        # 5) ntfs-3g does NOT fail on a hibernated/unclean volume: it silently mounts it
        #    read-only and exits 0. Detect that, undo it and report it.
        if /sbin/mount | /usr/bin/grep -F -- " on $MP (" | /usr/bin/grep -q "read-only"; then
          /sbin/umount "$MP" 2>/dev/null
          N=0
          while /usr/bin/pgrep -f "^[^ ]*ntfs-3g $DEV " >/dev/null 2>&1 && [ $N -lt 20 ]; do N=$((N+1)); /bin/sleep 0.5; done
          /bin/rmdir "$MP" 2>/dev/null
          /usr/sbin/diskutil mount readOnly "$DEV" >/dev/null 2>&1 || true
          echo "MACREADER_MOUNT_FAILED unsafe state (read-only fallback) $OUT" >&2
          exit 65
        fi
        echo "$MP"

        """
    }

    static func disableWriteScript(device: String, mountPoint: String) -> String {
        safeUnmountScript(devices: [(device, mountPoint)])
            + "/usr/sbin/diskutil mount readOnly \(Shell.quote(device)) >/dev/null 2>&1 || true\n"
    }

    static func ejectScript(wholeDisk: String, writable: [(String, String)]) -> String {
        safeUnmountScript(devices: writable)
            + "/bin/sync\n"
            + "/usr/sbin/diskutil eject \(Shell.quote(wholeDisk)) >/dev/null 2>&1 || { echo \"MACREADER_BUSY\" >&2; exit 66; }\n"
    }

    /// sync -> umount (no force) -> wait until ntfs-3g has exited (= everything flushed).
    static func safeUnmountScript(devices: [(String, String)]) -> String {
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

    // MARK: - Helpers

    private static func runAdmin(_ script: String) throws {
        switch Shell.runAsAdmin(script) {
        case .success: return
        case .cancelled: throw MountError.cancelled
        case .failure(let message): throw parseFailure(message)
        }
    }

    static func parseFailure(_ message: String) -> MountError {
        if let range = message.range(of: "MACREADER_CANT_READ") {
            return .cantRead(String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
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
            let isUnclean = uncleanHints.contains(where: { lower.contains($0) })
            if isUnclean { return .windowsUnclean(detail) }
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

    /// Safe folder / volume name: no slashes, colons, commas, quotes or control characters.
    static func sanitizedName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:,'\"\\").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "NTFS" : cleaned
    }
}
