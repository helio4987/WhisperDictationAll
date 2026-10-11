import SwiftUI
import AppKit

/// A transient, cursor-anchored popup listing every Custom Operation — the
/// "right-click menu" for operations that don't have (or don't need) their
/// own dedicated hotkey. Backed by an `NSPanel` rather than a SwiftUI
/// `Window` scene: `Window` scenes are for persistent, user-visible app
/// windows (Settings, Onboarding); a borderless, non-activating panel that
/// appears at the mouse location and disappears on click-away or Escape is
/// standard AppKit menu-popup territory, which SwiftUI's scene system has no
/// equivalent for.
@MainActor
final class OperationsMenuWindowController: NSObject {
    private var panel: NSPanel?
    /// Closes the panel on Escape, or a click inside this app but outside
    /// the panel. Local monitors only see events sent to THIS app's windows
    /// — a click in a different (frontmost) app is invisible to it, which
    /// is why `globalDismissMonitor` below also exists.
    private var localDismissMonitor: Any?
    /// Closes the panel on a click in a DIFFERENT app while the panel is
    /// open. The panel is a `.nonactivatingPanel` deliberately (see `show`),
    /// so the frontmost app never loses focus when the menu appears — which
    /// means a click back in that still-frontmost app is a global event
    /// from this app's point of view, not a local one.
    private var globalDismissMonitor: Any?

    /// Shows the menu at the given screen point (typically the current mouse
    /// location) listing `operations`. `onSelect` fires with the chosen
    /// operation; `onDismiss` fires if the menu is closed without a
    /// selection (Escape, or a click elsewhere) — the caller needs this to
    /// know a selection it already captured is now going unused. The panel
    /// always closes after either outcome.
    func show(
        operations: [TextOperation],
        at point: NSPoint,
        onSelect: @escaping (TextOperation) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        close()

        var didSelect = false
        let content = OperationsMenuView(operations: operations) { [weak self] operation in
            didSelect = true
            self?.close()
            onSelect(operation)
        }
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            // .nonactivatingPanel: the panel can become key (so it receives
            // the Escape keyDown and mouse clicks below) WITHOUT activating
            // this app or stealing focus from whatever app the user was just
            // typing in — the whole point of a cursor-anchored quick menu is
            // that it doesn't disrupt where the user already was.
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // Position so the menu opens below-and-right of the cursor, like a
        // standard context menu, but kept fully on-screen if the cursor is
        // near an edge.
        let size = hostingView.frame.size
        var origin = NSPoint(x: point.x, y: point.y - size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(origin.x, visible.maxX - size.width)
            origin.y = max(origin.y, visible.minY)
        }
        panel.setFrameOrigin(origin)

        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()

        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Escape
                    self.close()
                    if !didSelect { onDismiss() }
                    return nil
                }
                return event
            }
            // A click inside the panel's own window is handled by its SwiftUI
            // buttons; only a click OUTSIDE the panel should dismiss it.
            if event.window !== panel {
                self.close()
                if !didSelect { onDismiss() }
            }
            return event
        }
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            self.close()
            if !didSelect { onDismiss() }
        }
    }

    func close() {
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }
}

/// SwiftUI content for the popup: one row per operation, showing its name
/// and (if set) its own dedicated hotkey as a reminder that direct access
/// still works alongside this menu. Sized to its content — the hosting
/// panel reads `intrinsicContentSize` before showing.
private struct OperationsMenuView: View {
    let operations: [TextOperation]
    let onSelect: (TextOperation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if operations.isEmpty {
                Text("No operations configured")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(operations) { operation in
                    OperationsMenuRow(operation: operation) {
                        onSelect(operation)
                    }
                    if operation.id != operations.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct OperationsMenuRow: View {
    let operation: TextOperation
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(operation.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
                if operation.hasHotkey {
                    Text(KeyCodeNames.shortLabel(for: operation.hotkeyKeyCode))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovering ? Color.accentColor.opacity(0.15) : Color.clear)
        .onHover { isHovering = $0 }
    }
}
