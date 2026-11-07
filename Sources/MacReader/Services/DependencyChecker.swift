import Foundation

struct Dependencies: Equatable {
    let macFUSE: Bool
    let ntfs3gPath: String?

    var ready: Bool { macFUSE && ntfs3gPath != nil }
}

enum DependencyChecker {
    static let ntfs3gCandidates = [
        "/opt/homebrew/bin/ntfs-3g",
        "/opt/homebrew/sbin/ntfs-3g",
        "/usr/local/bin/ntfs-3g",
        "/usr/local/sbin/ntfs-3g",
    ]

    static func check() -> Dependencies {
        let fm = FileManager.default
        let fuse = fm.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
        let ntfs3g = ntfs3gCandidates.first { fm.isExecutableFile(atPath: $0) }
        return Dependencies(macFUSE: fuse, ntfs3gPath: ntfs3g)
    }
}
