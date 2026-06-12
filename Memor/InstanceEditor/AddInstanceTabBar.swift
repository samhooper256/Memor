//
//  AddInstanceTabBar.swift
//  Memor
//
//  Thin tab strip at the top of the Add Instance window: one chip per
//  in-progress draft, an X to close each, and a "+" to open a blank tab.
//

import AppKit
import SwiftUI

struct AddInstanceTabBar: View {
    @ObservedObject var windowState: AddInstanceWindowState
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNewTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(windowState.drafts) { draft in
                            AddInstanceTabChip(
                                draft: draft,
                                isSelected: draft.id == windowState.selectedDraftID,
                                onSelect: { onSelect(draft.id) },
                                onClose: { onClose(draft.id) }
                            )
                            .id(draft.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .onChange(of: windowState.selectedDraftID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newValue)
                    }
                }
            }

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isNewTabHovered ? Color.primary.opacity(0.1) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { isNewTabHovered = $0 }
            .padding(.trailing, 8)
            .help("New Tab")
        }
        .frame(height: 30)
        .background(.bar)
    }

    @State private var isNewTabHovered = false
}

/// Window-scoped monitor for the Add Instance window's fixed tab shortcuts:
/// ⌘1–⌘9 select a tab, ⌘W closes the current one. Intentionally non-customizable
/// (like Escape/arrows). ⌘digits are consumed even when out of range so the
/// app-level Navigate menu's ⌘1–⌘5 can't fire while this window is key; ⌘W is
/// consumed so the default File ▸ Close can't bypass the tab-close flow.
/// Mounted in AddInstanceWindowView, outside the per-tab editor subtree, so the
/// monitor survives tab switches; the Edit Instance window is unaffected.
struct AddInstanceTabKeyHandler: NSViewRepresentable {
    let onSelectTabIndex: (Int) -> Void
    let onCloseCurrentTab: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onSelectTabIndex = onSelectTabIndex
        view.onCloseCurrentTab = onCloseCurrentTab
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let monitorView = nsView as? MonitorView else { return }
        monitorView.onSelectTabIndex = onSelectTabIndex
        monitorView.onCloseCurrentTab = onCloseCurrentTab
    }

    final class MonitorView: NSView {
        var onSelectTabIndex: ((Int) -> Void)?
        var onCloseCurrentTab: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil, window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else { return event }
                    let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    guard modifierFlags == [.command],
                          let characters = event.charactersIgnoringModifiers else {
                        return event
                    }
                    if characters.lowercased() == "w" {
                        self.onCloseCurrentTab?()
                        return nil
                    }
                    if let digit = Int(characters), (1...9).contains(digit) {
                        self.onSelectTabIndex?(digit - 1)
                        return nil
                    }
                    return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private struct AddInstanceTabChip: View {
    // Observed directly so the title updates live while the user types in the
    // draft's first field (the window state's objectWillChange doesn't fire for
    // mutations inside a draft).
    @ObservedObject var draft: InstanceEditorDraft
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseButtonHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Text(draft.tabTitle)
                .font(.caption)
                .bold()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(isSelected ? Color.white : Color.primary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .padding(3)
                    .background(
                        Circle()
                            .fill(isCloseButtonHovered ? Color.primary.opacity(0.2) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isCloseButtonHovered = $0 }
            .help("Close Tab (⌘W)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
        )
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
