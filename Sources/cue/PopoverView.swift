import AppKit
import CueCore
import SwiftUI

/// The popover: a header, one tile per session, and a footer.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: String?
    @State private var expanded: String?  // one reply open at a time keeps the popover short

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No agent sessions", systemImage: "terminal")
                } description: {
                    Text(model.monitor.hooksInstalled
                         ? "A Claude Code, Codex or Amp session appears after its next prompt or reply."
                         : "No agent is wired to Cue yet. Run ./install.sh in the cue folder.")
                }
                .padding(.vertical, 12)
            } else if model.rows.count <= 3 {
                rowList
            } else {
                // ponytail: fixed height past 3 rows; a measured height would need a GeometryReader dance.
                ScrollView { rowList }.frame(height: 600)
            }
            if let warning = model.monitor.codexWarning {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .bottom], 8)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        // Each open puts the cursor in the first row you can type in: after sorting, the longest wait.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
            focused = model.rows.first(where: model.canType)?.sessionId
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
            Text("Cue").font(.headline)
            Spacer()
            Text(model.summary).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var rowList: some View {
        VStack(spacing: 6) {
            ForEach(model.rows, id: \.sessionId) { s in
                RowView(session: s, focus: $focused,
                        expanded: Binding(get: { expanded == s.sessionId }, set: { expanded = $0 ? s.sessionId : nil }))
            }
        }
        .padding(8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label(model.monitor.hooksInstalled ? "Hooks installed" : "Hooks missing",
                  systemImage: model.monitor.hooksInstalled ? "checkmark.circle" : "exclamationmark.triangle")
            Spacer()
            Text("⌃⌥Space opens Cue")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
