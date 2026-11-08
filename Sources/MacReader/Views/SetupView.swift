import AppKit
import SwiftUI

/// Shown when FUSE-T (or macFUSE) or a matching ntfs-3g is missing.
struct SetupView: View {
    let deps: Dependencies
    let recheck: () -> Void

    private let fuseTCommand = "brew trust --cask macos-fuse-t/cask/fuse-t && brew install --cask macos-fuse-t/cask/fuse-t"
    private let ntfsCommand = "~/Macreader/scripts/install_ntfs3g_fuse_t.sh"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("محتاجين نسطّب حاجتين الأول")
                .font(.subheadline.weight(.semibold))

            step(done: deps.fuseTInstalled,
                 title: "1. FUSE-T",
                 command: fuseTCommand,
                 note: "مش محتاج kernel extension ولا Reduced Security. مجاني للاستخدام الشخصي.")

            step(done: deps.ready,
                 title: "2. ntfs-3g لـ FUSE-T",
                 command: ntfsCommand,
                 note: "السكربت جوه المشروع: بيبني ntfs-3g على FUSE-T ويسطّبه في /usr/local/bin.")

            HStack {
                Button("صفحة FUSE-T") {
                    NSWorkspace.shared.open(URL(string: "https://www.fuse-t.org")!)
                }
                Spacer()
                Button("اتأكد تاني", action: recheck)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
    }

    @ViewBuilder
    private func step(done: Bool, title: String, command: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? .green : .secondary)
                Text(title).font(.callout.weight(.medium))
            }
            if !done {
                HStack {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                    Spacer()
                    Button("انسخ") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
