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
            } else {
                // The list grows with its rows, and with an opened reply, up to the screen's room, then scrolls.
                ScrollViewReader { list in
                    ScrollView {
                        rowList.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    .frame(height: min(listHeight, maxListHeight))
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
            openAtLogin = LoginItem.isOn  // you may have changed it in System Settings
            if !openRequested() { focused = model.rows.first(where: model.canType)?.sessionId }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in shown = false }
        .onChange(of: model.focusRequest) { if shown { _ = openRequested() } }
    }

    @State private var shown = false
    @State private var scrollTarget: String?
    @State private var listHeight: CGFloat = 0

    /// The shortest screen's height less the menu bar, the header, the footer and a warning: the popover may
    /// open on any of them, and NSScreen.main follows the key window, which isn't the popover yet.
    private var maxListHeight: CGFloat { (NSScreen.screens.map(\.visibleFrame.height).min() ?? 800) - 180 }
    @State private var openAtLogin = LoginItem.isOn
    @AppStorage(Notifier.soundsKey) private var playSounds = true

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
                Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { LoginItem.set($0); openAtLogin = LoginItem.isOn }))
                if LoginItem.wanted && LoginItem.needsApproval {
                    Button("Allow Cue in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("Play Sounds", isOn: $playSounds)
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
