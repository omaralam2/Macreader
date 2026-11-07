import AppKit
import SwiftUI

@MainActor
struct MenuContentView: View {
    @ObservedObject var store: VolumeStore
    @AppStorage(SettingsKeys.autoEnable) private var autoEnable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("MacReader", systemImage: "externaldrive.fill")
                    .font(.headline)
                Spacer()
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("تحديث")
            }

            if !store.deps.ready {
                SetupView(deps: store.deps) { store.refresh() }
            }

            if store.volumes.isEmpty {
                Text("مفيش هارد NTFS متوصل دلوقتي.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.volumes) { volume in
                    VolumeRow(volume: volume, store: store)
                }
            }

            if let message = store.message {
                MessageBanner(message: message) { store.message = nil }
            }

            Divider()

            Toggle("افتح الهارد للكتابة تلقائياً أول ما يتوصل", isOn: $autoEnable)
                .toggleStyle(.checkbox)
                .font(.callout)

            Text("خلّي عندك نسخة احتياطية من الحاجات المهمة، ومتشيلش الهارد غير بعد Eject.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("اقفل MacReader") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { store.refresh() }
    }
}

@MainActor
struct VolumeRow: View {
    let volume: NTFSVolume
    @ObservedObject var store: VolumeStore

    private var isBusy: Bool { store.busy.contains(volume.id) }
    private var flagged: Bool { store.isFlagged(volume) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name).font(.body.weight(.semibold))
                    Text("\(volume.sizeText) · \(volume.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    StateBadge(state: volume.state)
                }
            }

            if flagged {
                Text("⚠️ الهارد ده اتشال وهو مفتوح للكتابة. علشان الداتا، وصّله على ويندوز واعمل chkdsk قبل ما تكتب عليه تاني.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if volume.state == .unsupported {
                Text("مش متعرّف كـ NTFS (ممكن يكون متشفّر بـ BitLocker). MacReader مش هيلمسه.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                buttons
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            switch volume.state {
            case .notMounted, .readOnly:
                if flagged {
                    Button("عملت chkdsk خلاص") { store.confirmChecked(volume) }
                } else {
                    Button("افتح للكتابة") { store.enableWrite(volume) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.deps.ready)
                }
            case .readWrite:
                Button("رجّعه قراءة فقط") { store.disableWrite(volume) }
            case .unsupported:
                EmptyView()
            }
            Spacer()
            if volume.mountPoint != nil {
                Button("افتح") { store.open(volume) }
            }
            Button("Eject") { store.eject(volume) }
        }
        .disabled(isBusy)
    }
}

struct StateBadge: View {
    let state: VolumeState

    private var text: String {
        switch state {
        case .readWrite: return "قراءة وكتابة"
        case .readOnly: return "قراءة فقط"
        case .notMounted: return "مش متركّب"
        case .unsupported: return "غير مدعوم"
        }
    }

    private var color: Color {
        switch state {
        case .readWrite: return .green
        case .readOnly: return .orange
        case .notMounted: return .gray
        case .unsupported: return .red
        }
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }
}

struct MessageBanner: View {
    let message: AppMessage
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Text(message.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((message.isError ? Color.red : Color.green).opacity(0.12))
        )
    }
}
