import AppKit
import Foundation

struct AppMessage: Equatable {
    let text: String
    let isError: Bool
}

enum SettingsKeys {
    static let autoEnable = "autoEnableWrite"
    static let rwActive = "rwActiveVolumeKeys"
    static let needsCheck = "needsCheckVolumeKeys"
}

@MainActor
final class VolumeStore: ObservableObject {
    @Published private(set) var volumes: [NTFSVolume] = []
    @Published private(set) var deps = DependencyChecker.check()
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var needsCheck: Set<String>
    @Published var message: AppMessage?

    /// Volumes MacReader mounted read/write and that have not been cleanly unmounted yet.
    private var rwActive: Set<String>
    /// Keys currently being ejected / switched back by MacReader itself.
    private var transitioning: Set<String> = []
    private var knownMounts: [String: String] = [:]
    private var presentKeys: Set<String> = []
    private var hasScanned = false
    private var isScanning = false
    private var rescanPending = false
    private var refreshScheduled = false
    private var watcher: DiskWatcher?
    private let defaults = UserDefaults.standard

    init() {
        needsCheck = Set(defaults.stringArray(forKey: SettingsKeys.needsCheck) ?? [])
        rwActive = Set(defaults.stringArray(forKey: SettingsKeys.rwActive) ?? [])
        watcher = DiskWatcher { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        refresh()
    }

    var hasWritableVolumes: Bool { volumes.contains { $0.state == .readWrite } }

    // MARK: - Scanning

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            refreshScheduled = false
            refresh()
        }
    }

    func refresh() {
        if isScanning { rescanPending = true; return }
        isScanning = true
        let known = knownMounts
        Task { @MainActor in
            let (vols, newDeps) = await Task.detached(priority: .userInitiated) {
                (DiskScanner.scan(knownMounts: known), DependencyChecker.check())
            }.value
            apply(vols, newDeps)
            isScanning = false
            if rescanPending {
                rescanPending = false
                refresh()
            }
        }
    }

    private func apply(_ vols: [NTFSVolume], _ newDeps: Dependencies) {
        deps = newDeps

        let ledger = SafetyLedger.reconcile(
            SafetyLedger(rwActive: rwActive, needsCheck: needsCheck),
            volumes: vols,
            transitioning: transitioning,
            isFirstScan: !hasScanned
        )
        rwActive = ledger.rwActive
        needsCheck = ledger.needsCheck
        persist()

        for v in vols where v.state == .readWrite {
            if let mp = v.mountPoint { knownMounts[v.id] = mp }
        }

        let newcomers = vols.filter { !presentKeys.contains($0.key) }
        presentKeys = Set(vols.map(\.key))
        volumes = vols
        hasScanned = true

        if defaults.bool(forKey: SettingsKeys.autoEnable), deps.ready {
            for v in newcomers where (v.state == .readOnly || v.state == .notMounted)
                && !needsCheck.contains(v.key) {
                enableWrite(v)
            }
        }
    }

    private func persist() {
        defaults.set(Array(rwActive), forKey: SettingsKeys.rwActive)
        defaults.set(Array(needsCheck), forKey: SettingsKeys.needsCheck)
    }

    // MARK: - Actions

    func enableWrite(_ volume: NTFSVolume) {
        guard deps.ready, let ntfs3g = deps.ntfs3gPath else {
            message = AppMessage(text: "لازم تسطّب macFUSE و ntfs-3g الأول (الخطوات فوق).", isError: true)
            return
        }
        guard !needsCheck.contains(volume.key) else {
            message = AppMessage(text: "الهارد ده محتاج chkdsk على ويندوز الأول قبل الكتابة عليه.", isError: true)
            return
        }
        guard volume.state != .unsupported, !busy.contains(volume.id) else { return }

        busy.insert(volume.id)
        message = nil
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Mounter.enableWrite(volume, ntfs3g: ntfs3g) }
            }.value
            busy.remove(volume.id)
            switch result {
            case .success(let mountPoint):
                knownMounts[volume.id] = mountPoint
                rwActive.insert(volume.key)
                persist()
                message = AppMessage(
                    text: "«\(volume.name)» بقى قراءة وكتابة ✅\nمتشيلش الهارد غير بعد ما تعمل Eject.",
                    isError: false)
                NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
            case .failure(let error):
                message = Self.describe(error, volumeName: volume.name, duringMount: true)
            }
            refresh()
        }
    }

    func disableWrite(_ volume: NTFSVolume) {
        guard volume.state == .readWrite, !busy.contains(volume.id) else { return }
        busy.insert(volume.id)
        transitioning.insert(volume.key)
        message = nil
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Mounter.disableWrite(volume) }
            }.value
            busy.remove(volume.id)
            transitioning.remove(volume.key)
            switch result {
            case .success:
                rwActive.remove(volume.key)
                knownMounts[volume.id] = nil
                persist()
                message = AppMessage(text: "«\(volume.name)» رجع قراءة فقط، وكل الداتا اتحفظت.", isError: false)
            case .failure(let error):
                message = Self.describe(error, volumeName: volume.name, duringMount: false)
            }
            refresh()
        }
    }

    /// Ejects the whole physical disk this volume lives on.
    func eject(_ volume: NTFSVolume, completion: ((Bool) -> Void)? = nil) {
        let siblings = volumes.filter { $0.wholeDisk == volume.wholeDisk }
        let ids = Set(siblings.map(\.id))
        guard busy.isDisjoint(with: ids) else { completion?(false); return }

        let writable = siblings.filter { $0.state == .readWrite }
        let readOnlyMPs = siblings.filter { $0.state == .readOnly }.compactMap(\.mountPoint)
        let keys = Set(siblings.map(\.key))
        busy.formUnion(ids)
        transitioning.formUnion(keys)
        message = nil

        Task { @MainActor in
            let whole = volume.wholeDisk
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Mounter.eject(wholeDisk: whole, writable: writable, readOnlyMountPoints: readOnlyMPs) }
            }.value
            busy.subtract(ids)
            transitioning.subtract(keys)
            switch result {
            case .success:
                rwActive.subtract(keys)
                for id in ids { knownMounts[id] = nil }
                persist()
                message = AppMessage(text: "تمام ✅ تقدر تشيل الهارد دلوقتي بأمان.", isError: false)
                completion?(true)
            case .failure(let error):
                message = Self.describe(error, volumeName: volume.name, duringMount: false)
                completion?(false)
            }
            refresh()
        }
    }

    /// Ejects every disk that has a writable volume. Used before quitting.
    func ejectAllWritable(completion: @escaping (Bool) -> Void) {
        let disks = Array(Set(volumes.filter { $0.state == .readWrite }.map(\.wholeDisk)))
        guard !disks.isEmpty else { completion(true); return }
        var remaining = disks.count
        var allOK = true
        for disk in disks {
            guard let v = volumes.first(where: { $0.wholeDisk == disk }) else { continue }
            eject(v) { ok in
                allOK = allOK && ok
                remaining -= 1
                if remaining == 0 { completion(allOK) }
            }
        }
    }

    func open(_ volume: NTFSVolume) {
        guard let mp = volume.mountPoint else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: mp))
    }

    func isFlagged(_ volume: NTFSVolume) -> Bool { needsCheck.contains(volume.key) }

    /// The user confirms they ran chkdsk on Windows.
    func confirmChecked(_ volume: NTFSVolume) {
        let alert = NSAlert()
        alert.messageText = "عملت chkdsk على ويندوز؟"
        alert.informativeText = "اتأكد إنك وصّلت «\(volume.name)» على ويندوز وعملت chkdsk ومفيش أخطاء، قبل ما تكتب عليه من الماك."
        alert.addButton(withTitle: "أيوه، عملت chkdsk")
        alert.addButton(withTitle: "لأ لسه")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            needsCheck.remove(volume.key)
            persist()
        }
    }

    // MARK: - Messages

    private static func describe(_ error: Error, volumeName: String, duringMount: Bool) -> AppMessage? {
        let safe = duringMount ? "\nالهارد فضل قراءة فقط ومتغيّرش فيه أي حاجة." : ""
        guard let error = error as? MountError else {
            return AppMessage(text: error.localizedDescription + safe, isError: true)
        }
        switch error {
        case .cancelled:
            return nil
        case .invalidDevice:
            return AppMessage(text: "مش قادر أتعرّف على الهارد. جرّب تحدّث القائمة.", isError: true)
        case .notNTFS:
            return AppMessage(text: "«\(volumeName)» مش NTFS عادي (ممكن يكون متشفّر بـ BitLocker)، فـ MacReader مش هيلمسه." + safe, isError: true)
        case .busy(let apps):
            let list = apps.isEmpty
                ? "اقفل أي ملف أو برنامج فاتح حاجة من الهارد وجرّب تاني."
                : "اقفل البرامج دي وجرّب تاني: " + apps.joined(separator: "، ")
            return AppMessage(text: "فيه ملفات مفتوحة على «\(volumeName)»، فمفصلناش الهارد علشان منبوّظش حاجة.\n" + list, isError: true)
        case .windowsUnclean:
            return AppMessage(text: """
                ويندوز مقفلش «\(volumeName)» صح (Fast Startup أو Hibernate أو اتشال من غير Eject).
                علشان نحافظ على الداتا مفتحناهوش للكتابة. وصّله على ويندوز واعمل chkdsk، أو اعمل Shut down كامل (دوس Shift وانت بتختار Shut down)، وبعدين جرّب تاني.
                """ + safe, isError: true)
        case .fuseProblem(let detail):
            return AppMessage(text: "macFUSE مش شغّال. افتح System Settings ← Privacy & Security واسمح بالـ extension بتاع macFUSE واعمل Restart.\n\(detail)" + safe, isError: true)
        case .stillWriting:
            return AppMessage(text: "ntfs-3g لسه بيخلّص كتابة على الهارد. متشيلوش! استنى شوية واعمل Eject تاني.", isError: true)
        case .failed(let detail):
            return AppMessage(text: "حصلت مشكلة: \(detail)" + safe, isError: true)
        }
    }
}
