import AppKit
import Carbon.HIToolbox
import NudgeCore
import SwiftUI

/// The ⌘⇧J switcher: a Spotlight-style panel listing every session, filtered as you
/// type. Enter jumps to the selected session's tab, Escape or clicking away closes it.
@MainActor
final class SwitcherController: NSObject, NSWindowDelegate {
    private let monitor: SessionMonitor
    private let model: SwitcherModel
    private let panel: SwitcherPanel
    private var keyMonitor: Any?

    init(monitor: SessionMonitor) {
        self.monitor = monitor
        model = SwitcherModel(monitor: monitor)
        panel = SwitcherPanel()
        super.init()
        model.onChoose = { [weak self] session in self?.choose(session) }
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SwitcherView(model: model))
    }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        model.reset()
        position()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        // Titles cost ~170ms of AppleScript; fetch once the panel is on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.monitor.refreshTitles()
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
    }

    private func choose(_ session: Session) {
        close()
        monitor.focus(session)
    }

    /// Upper third of the screen with the mouse, like Spotlight.
    private func position() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.2))
    }

    /// Arrows, ⇧J/⇧K (vim-style), Enter and Escape are taken before the search field
    /// sees them, so the field keeps focus the whole time. Search ignores case, so
    /// losing capital J and K costs nothing.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel else { return event }
            let shiftOnly = event.modifierFlags.intersection([.shift, .control, .option, .command]) == .shift
            switch Int(event.keyCode) {
            case kVK_DownArrow: model.move(1)
            case kVK_UpArrow: model.move(-1)
            case kVK_ANSI_J where shiftOnly: model.move(1)
            case kVK_ANSI_K where shiftOnly: model.move(-1)
            case kVK_Return, kVK_ANSI_KeypadEnter: model.chooseSelected()
            case kVK_Escape: close()
            default: return event
            }
            return nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// Borderless, floats over every Space and full-screen apps, and takes keyboard focus
/// without activating Nudge (so the previous app stays active until a session is chosen).
private final class SwitcherPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
@Observable
final class SwitcherModel {
    var query = "" {
        didSet { selection = 0 }
    }
    var selection = 0
    /// Bumped on every open so the view can refocus the search field.
    private(set) var openCount = 0
    var onChoose: ((Session) -> Void)?

    let monitor: SessionMonitor

    init(monitor: SessionMonitor) {
        self.monitor = monitor
    }

    var results: [Session] { monitor.switcherResults(query: query) }

    func reset() {
        query = ""
        selection = 0
        openCount += 1
    }

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    func chooseSelected() {
        let results = results
        guard results.indices.contains(selection) else { return }
        onChoose?(results[selection])
    }

    func choose(_ session: Session) {
        onChoose?(session)
    }
}

struct SwitcherView: View {
    let model: SwitcherModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        let results = model.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("Find a Claude session", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            if results.isEmpty {
                Text(model.query.isEmpty ? "No Claude sessions" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, session in
                                SwitcherRow(
                                    session: session, title: model.monitor.title(for: session),
                                    now: model.monitor.now, seen: model.monitor.isSeen(session),
                                    selected: index == model.selection
                                )
                                .id(session.id)
                                .onTapGesture { model.choose(session) }
                                .onHover { if $0 { model.selection = index } }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selection) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                hint("↑↓ ⇧J⇧K", "select")
                hint("↩", "jump to tab")
                hint("esc", "close")
                Spacer()
                Text("\(results.count) session\(results.count == 1 ? "" : "s")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 620, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onChange(of: model.openCount, initial: true) { searchFocused = true }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
            Text(label)
        }
    }
}

struct SwitcherRow: View {
    let session: Session
    let title: String?
    let now: Date
    let seen: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.statusColor(seen: seen))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? session.project)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(title == nil ? session.statusText(seen: seen) : "\(session.project) · \(session.statusText(seen: seen))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(Session.age(from: session.lastEventAt, to: now))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
