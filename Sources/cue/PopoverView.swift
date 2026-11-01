import AppKit
import CueCore
import ServiceManagement
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
                ScrollViewReader { list in
                    ScrollView { rowList }
                        .frame(height: 600)
                        .onChange(of: scrollTarget) { _, id in
                            if let id { list.scrollTo(id, anchor: .top) }
                        }
                }
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
            shown = true
            if !openRequested() { focused = model.rows.first(where: model.canType)?.sessionId }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in shown = false }
        .onChange(of: model.focusRequest) { if shown { _ = openRequested() } }
    }

    @State private var shown = false
    @State private var scrollTarget: String?
    @State private var openAtLogin = LoginItem.wanted

    /// Opens the reply of the session a notification named and puts the cursor in its prompt box.
    private func openRequested() -> Bool {
        guard let id = model.focusRequest else { return false }
        model.focusRequest = nil
        expanded = id
        scrollTarget = id
        focused = model.rows.first { $0.sessionId == id && model.canType($0) }?.sessionId
        return true
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
                    .id(s.sessionId)
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
            Menu {
                Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { LoginItem.wanted = $0; openAtLogin = $0 }))
                if openAtLogin && LoginItem.needsApproval {
                    Button("Allow Cue in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Divider()
                Button("Quit Cue") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
