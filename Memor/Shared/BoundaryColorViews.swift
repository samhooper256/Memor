//
//  BoundaryColorViews.swift
//  Memor
//
//  Shared UI for the per-boundary border color: the SwiftUI/AppKit color
//  mappings, the small indicator circle shown beside boundary names in the
//  instance editors, and the "Color:" picker popover used by both the
//  PointMap chip strip (right-click) and the BoundaryMap list rows
//  (left-click on the circle).
//

import AppKit
import SwiftUI

extension BoundaryColor {
    var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .blue: return .blue
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: return .red
        case .blue: return .blue
        }
    }
}

/// The small filled circle shown to the left of a boundary's name.
struct BoundaryColorCircle: View {
    let color: BoundaryColor
    var diameter: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color.swiftUIColor)
            .frame(width: diameter, height: diameter)
    }
}

/// Popover content: "Color:" followed by one clickable circle per color.
/// The current color is marked with a subtle ring.
struct BoundaryColorPickerPopoverView: View {
    let currentColor: BoundaryColor
    let onSelect: (BoundaryColor) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            Text("Color:")
                .font(.subheadline)
            ForEach(BoundaryColor.allCases, id: \.self) { color in
                Button {
                    onSelect(color)
                    dismiss()
                } label: {
                    Circle()
                        .fill(color.swiftUIColor)
                        .frame(width: 16, height: 16)
                        .overlay {
                            if color == currentColor {
                                Circle()
                                    .stroke(Color.primary.opacity(0.6), lineWidth: 1.5)
                                    .padding(-2.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(color.displayName)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Transparent hit-test-passthrough overlay that reports right-clicks landing
/// inside its bounds (and swallows them). Same local-monitor pattern as
/// MapRightClickContextMenu, but the caller presents its own UI (a popover)
/// instead of an NSMenu.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        deinit {
            removeMonitor()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(locationInView) else { return event }
                guard let onRightClick = self.onRightClick else { return event }
                onRightClick()
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
