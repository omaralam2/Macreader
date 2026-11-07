import AppKit
import SwiftUI

@main
struct MacReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("MacReader", systemImage: "externaldrive.fill") {
            MenuContentView(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var store = VolumeStore()
    private var poweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poweringOff = true }
        }
    }

    /// Quitting MacReader does not unmount anything (ntfs-3g keeps running), but
    /// the user should not forget a writable disk, so offer a safe eject first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if poweringOff {
            // macOS unmounts all filesystems cleanly on shutdown; just flush now.
            _ = Shell.run("/bin/sync", [])
            return .terminateNow
        }
        guard store.hasWritableVolumes else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "فيه هارد لسه مفتوح للكتابة"
        alert.informativeText = "الأحسن تعمل Eject دلوقتي. لو قفلت من غير Eject، الهارد هيفضل شغّال، بس لازم تعمله Eject من Finder قبل ما تشيله."
        alert.addButton(withTitle: "Eject وبعدين اقفل")
        alert.addButton(withTitle: "اقفل من غير Eject")
        alert.addButton(withTitle: "إلغاء")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.ejectAllWritable { ok in
                // If something was busy, stay open so the user sees why.
                NSApp.reply(toApplicationShouldTerminate: ok)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
