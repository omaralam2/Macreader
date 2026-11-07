import DiskArbitration
import Foundation

/// Calls `onChange` (on the main thread) whenever a disk is connected,
/// disconnected, mounted or unmounted.
final class DiskWatcher {
    private let session: DASession
    private let onChange: () -> Void

    init?(onChange: @escaping () -> Void) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
        self.onChange = onChange

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, ctx in
            DiskWatcher.fire(ctx)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, ctx in
            DiskWatcher.fire(ctx)
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, ctx in
            DiskWatcher.fire(ctx)
        }, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    private static func fire(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue().onChange()
    }
}
