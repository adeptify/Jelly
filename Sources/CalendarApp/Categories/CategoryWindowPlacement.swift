import AppKit
import SwiftUI

/// Positions the category-manager window on the same screen as the main calendar.
/// Separate `Window` scenes otherwise restore to the last screen (often a second display).
@MainActor
enum CategoryWindowPlacement {
    static let categoryWindowTitle = "分类管理"
    static let mainWindowTitle = "Jelly"

    static func alignToMainCalendar(window: NSWindow) {
        align(window, relativeTo: mainCalendarWindow())
    }

    private static func mainCalendarWindow() -> NSWindow? {
        if let exact = NSApp.windows.first(where: {
            $0.isVisible && $0.title == mainWindowTitle
        }) {
            return exact
        }
        // Prefer the key/main window if it isn't the category manager itself.
        if let key = NSApp.keyWindow, key.title != categoryWindowTitle {
            return key
        }
        return NSApp.windows.first(where: {
            $0.isVisible
                && $0.title != categoryWindowTitle
                && $0.contentView != nil
                && $0.frame.width >= 800
        })
    }

    private static func align(_ window: NSWindow, relativeTo anchor: NSWindow?) {
        let screen = anchor?.screen ?? NSScreen.main
        guard let screen else { return }

        var frame = window.frame
        if let anchor {
            // Center over the main calendar window (same display).
            frame.origin.x = anchor.frame.midX - frame.width / 2
            frame.origin.y = anchor.frame.midY - frame.height / 2
        } else {
            let visible = screen.visibleFrame
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.midY - frame.height / 2
        }

        frame = clamped(frame, to: screen.visibleFrame)
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var result = frame
        if result.width > visible.width {
            result.size.width = visible.width
        }
        if result.height > visible.height {
            result.size.height = visible.height
        }
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }
}

/// Reads the hosting `NSWindow` once it attaches, then repositions it.
struct AlignCategoryWindowOnAppear: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                CategoryWindowPlacement.alignToMainCalendar(window: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only re-align when first attached; avoid fighting user drag every update.
    }
}
