import Foundation

/// Which FUSE implementation the chosen ntfs-3g talks to.
enum FUSEBackend: Equatable {
    /// FUSE-T: no kernel extension, mounts through a local NFS server.
    /// Works on macOS 26/27 without Reduced Security. Preferred.
    case fuseT
    /// macFUSE: needs its kernel extension (Reduced Security on Apple Silicon).
    case macFUSE
}

struct Dependencies: Equatable {
    let backend: FUSEBackend?
    let ntfs3gPath: String?
    /// What is installed, so the setup screen can show the missing piece.
    let fuseTInstalled: Bool
    let macFUSEInstalled: Bool

    var ready: Bool { backend != nil && ntfs3gPath != nil }
}

enum DependencyChecker {
    static let fuseTLibrary = "/usr/local/lib/libfuse-t.dylib"
    static let macFUSEBundle = "/Library/Filesystems/macfuse.fs"

    static let ntfs3gCandidates = [
        "/usr/local/bin/ntfs-3g",   // FUSE-T build (scripts/install_ntfs3g_fuse_t.sh)
        "/opt/homebrew/bin/ntfs-3g",
        "/opt/homebrew/sbin/ntfs-3g",
        "/usr/local/sbin/ntfs-3g",
    ]

    static func check() -> Dependencies {
        let fm = FileManager.default
        return choose(
            fuseTInstalled: fm.fileExists(atPath: fuseTLibrary),
            macFUSEInstalled: fm.fileExists(atPath: macFUSEBundle),
            candidates: ntfs3gCandidates.filter { fm.isExecutableFile(atPath: $0) },
            linksFuseT: linksFuseT
        )
    }

    /// Pure so it can be unit-tested. An ntfs-3g binary only works with the
    /// FUSE library it was linked against, so pair each binary with its backend.
    static func choose(
        fuseTInstalled: Bool,
        macFUSEInstalled: Bool,
        candidates: [String],
        linksFuseT: (String) -> Bool
    ) -> Dependencies {
        if fuseTInstalled, let path = candidates.first(where: linksFuseT) {
            return Dependencies(backend: .fuseT, ntfs3gPath: path,
                                fuseTInstalled: true, macFUSEInstalled: macFUSEInstalled)
        }
        if macFUSEInstalled, let path = candidates.first(where: { !linksFuseT($0) }) {
            return Dependencies(backend: .macFUSE, ntfs3gPath: path,
                                fuseTInstalled: fuseTInstalled, macFUSEInstalled: true)
        }
        return Dependencies(backend: nil, ntfs3gPath: nil,
                            fuseTInstalled: fuseTInstalled, macFUSEInstalled: macFUSEInstalled)
    }

    /// True if the binary is linked against libfuse-t (its load command names it).
    static func linksFuseT(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return data.range(of: Data("libfuse-t".utf8)) != nil
    }
}
