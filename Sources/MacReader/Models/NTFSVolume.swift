import Foundation

enum VolumeState: Equatable {
    /// NTFS partition that is connected but not mounted.
    case notMounted
    /// Mounted by macOS' built-in NTFS driver (read only).
    case readOnly
    /// Mounted read/write through ntfs-3g + macFUSE.
    case readWrite
    /// Looks like a Windows partition but is not recognised as NTFS
    /// (for example BitLocker-encrypted). MacReader never touches these.
    case unsupported
}

struct NTFSVolume: Identifiable, Equatable {
    /// BSD name of the partition, e.g. "disk4s1".
    let id: String
    /// BSD name of the whole disk, e.g. "disk4".
    let wholeDisk: String
    let name: String
    let sizeBytes: Int64
    /// Identity that survives unplug/replug (volume UUID when available).
    let key: String
    var mountPoint: String?
    var state: VolumeState

    var devicePath: String { "/dev/\(id)" }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// Only plain BSD names are ever passed to shell commands.
    static func isValidDeviceName(_ name: String) -> Bool {
        name.range(of: #"^disk[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil
    }
}
