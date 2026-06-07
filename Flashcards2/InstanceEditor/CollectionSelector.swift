//
//  CollectionSelector.swift
//  Memor
//
//  Search field and checklist row used by the instance editor's
//  Collections panel.
//

import AppKit
import SwiftUI

struct CollectionSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let focusController: AddInstanceFieldFocusController
    let onTab: () -> Void
    let onBackTab: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTab: onTab, onBackTab: onBackTab)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = "Search collections"
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.focusRingType = .none
        textField.bezelStyle = .roundedBezel
        textField.stringValue = text
        context.coordinator.textField = textField
        focusController.collectionSearchField = textField
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onTab = onTab
        context.coordinator.onBackTab = onBackTab
        focusController.collectionSearchField = nsView
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        var onTab: () -> Void
        var onBackTab: () -> Void
        weak var textField: NSTextField?

        init(text: Binding<String>, onTab: @escaping () -> Void, onBackTab: @escaping () -> Void) {
            _text = text
            self.onTab = onTab
            self.onBackTab = onBackTab
        }

        func controlTextDidChange(_ obj: Notification) {
            text = textField?.stringValue ?? ""
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                onTab()
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                onBackTab()
                return true
            }
            return false
        }
    }
}

struct ScrollBubbleBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ScrollBubbleBlockerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ScrollBubbleBlockerView: NSView {
    private weak var trackedScrollView: NSScrollView?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            uninstallMonitor()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.installMonitor()
        }
    }

    deinit {
        uninstallMonitor()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        guard let scrollView = enclosingScrollView else { return }
        trackedScrollView = scrollView
        let weakBox = WeakScrollViewBox()
        weakBox.value = scrollView
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let sv = weakBox.value else { return event }
            guard let win = sv.window, event.window === win else { return event }
            let locationInWindow = event.locationInWindow
            let frameInWindow = sv.convert(sv.bounds, to: nil)
            guard NSPointInRect(locationInWindow, frameInWindow) else { return event }

            let clipView = sv.contentView
            let lineHeight: CGFloat = 16
            let dy: CGFloat = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * lineHeight
            let dx: CGFloat = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaX
                : event.scrollingDeltaX * lineHeight

            var origin = clipView.bounds.origin
            origin.y -= dy * (clipView.isFlipped ? 1 : -1)
            origin.x -= dx

            let docFrame = sv.documentView?.frame ?? .zero
            let visSize = clipView.bounds.size
            let maxY = max(0, docFrame.height - visSize.height)
            let maxX = max(0, docFrame.width - visSize.width)
            origin.y = max(0, min(maxY, origin.y))
            origin.x = max(0, min(maxX, origin.x))

            clipView.scroll(to: origin)
            sv.reflectScrolledClipView(clipView)
            return nil
        }
    }

    private func uninstallMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        trackedScrollView = nil
    }
}

private final class WeakScrollViewBox {
    weak var value: NSScrollView?
}

struct CollectionChecklistRow: View {
    let item: CollectionChecklistItem
    let isChecked: Bool
    let onToggleCheck: (Bool) -> Void
    let onTogglePin: () -> Void

    @State private var isPinHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTogglePin) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(item.isPinned ? .white : Color.secondary.opacity(0.5))
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isPinHovered ? Color.secondary.opacity(0.15) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isPinHovered = hovering
            }

            Toggle(
                item.name,
                isOn: Binding(
                    get: { isChecked },
                    set: { onToggleCheck($0) }
                )
            )
            .toggleStyle(.checkbox)
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}
