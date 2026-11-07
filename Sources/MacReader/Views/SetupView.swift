import AppKit
import SwiftUI

/// Shown when macFUSE or ntfs-3g is missing.
struct SetupView: View {
    let deps: Dependencies
    let recheck: () -> Void

    private let fuseCommand = "brew install --cask macfuse"
    private let ntfsCommand = "brew tap gromgit/homebrew-fuse && brew install ntfs-3g-mac"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("محتاجين نسطّب حاجتين الأول")
                .font(.subheadline.weight(.semibold))

            step(done: deps.macFUSE,
                 title: "1. macFUSE",
                 command: fuseCommand,
                 note: "بعد التسطيب: System Settings ← Privacy & Security ← Allow، وبعدين Restart. على أجهزة Apple Silicon ممكن يطلب منك تفعّل Reduced Security من Recovery.")

            step(done: deps.ntfs3gPath != nil,
                 title: "2. ntfs-3g",
                 command: ntfsCommand,
                 note: nil)

            HStack {
                Button("صفحة macFUSE") {
                    NSWorkspace.shared.open(URL(string: "https://osxfuse.github.io")!)
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
