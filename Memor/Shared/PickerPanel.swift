//
//  PickerPanel.swift
//  Memor
//
//  A generic pick-one-item panel: a centered borderless panel (the Add Point
//  popup's presentation, for actions with no anchor view — e.g. context-menu
//  items) whose content mirrors the Person editor's picker popovers — a
//  keyboard-navigable search field over a list of rows, with unselectable rows
//  grayed out. Used by the PointMap move-points picker and the Search window's
//  add/remove-collection pickers.
//

import AppKit
import Combine
import SwiftUI

struct PickerPanelItem: Identifiable, Hashable {
    let id: Int64
    let title: String
    /// Secondary label shown after the title, e.g. "(current)".
    var detail: String? = nil
    /// Unselectable rows render grayed out and are skipped by the arrow keys.
    var isSelectable: Bool = true
}

@MainActor
final class PickerPanelController: ObservableObject {
    private weak var panel: HyperlinkSearchPanel?
    private var popupState: PickerPanelState?

    /// Whether the picker panel is currently on screen.
    var isPresented: Bool { panel != nil }

    func present(
        from window: NSWindow?,
        title: String,
        placeholder: String,
        emptyText: String,
        items: [PickerPanelItem],
        onSelect: @escaping (PickerPanelItem) -> Void
    ) {
        guard let window else { return }
        close()

        let popupState = PickerPanelState(
            title: title,
            placeholder: placeholder,
            emptyText: emptyText,
            items: items,
            onSelect: { [weak self] item in
                onSelect(item)
                self?.close()
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        self.popupState = popupState

        let panel = HyperlinkSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.delegate = popupState
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let hostingView = NSHostingView(rootView: PickerPanelView(state: popupState))
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)

        let windowFrame = window.frame
        let panelSize = panel.frame.size
        let originX = windowFrame.midX - panelSize.width / 2
        let originY = windowFrame.midY - panelSize.height / 2 + windowFrame.height * 0.15
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFront(nil)
        panel.makeKey()

        popupState.panel = panel
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        popupState = nil
    }
}

@MainActor
final class PickerPanelState: NSObject, ObservableObject, NSWindowDelegate {
    @Published var searchText = ""
    @Published var highlightedID: Int64?

    let title: String
    let placeholder: String
    let emptyText: String
    let items: [PickerPanelItem]
    let onSelect: (PickerPanelItem) -> Void
    let onClose: () -> Void

    weak var panel: NSPanel?

    init(
        title: String,
        placeholder: String,
        emptyText: String,
        items: [PickerPanelItem],
        onSelect: @escaping (PickerPanelItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.emptyText = emptyText
        self.items = items
        self.onSelect = onSelect
        self.onClose = onClose
        super.init()
        highlightedID = navigableIDs.first
    }

    var filteredItems: [PickerPanelItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Rows the arrow keys traverse — unselectable rows are skipped.
    var navigableIDs: [Int64] {
        filteredItems.filter(\.isSelectable).map(\.id)
    }

    func searchTextDidChange() {
        let ids = navigableIDs
        if let highlightedID, ids.contains(highlightedID) {
            // Keep the user's position when the row survives the new search.
        } else {
            highlightedID = ids.first
        }
    }

    func moveHighlightDown() {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }
        if let highlightedID, let currentIndex = ids.firstIndex(of: highlightedID) {
            // Wrap to the top when moving down past the last row, mirroring
            // moveHighlightUp's wrap from the top to the bottom.
            let nextIndex = currentIndex + 1
            self.highlightedID = nextIndex < ids.count ? ids[nextIndex] : ids.first
        } else {
            highlightedID = ids.first
        }
    }

    func moveHighlightUp() {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }
        if let highlightedID,
           let currentIndex = ids.firstIndex(of: highlightedID),
           currentIndex > 0 {
            self.highlightedID = ids[currentIndex - 1]
        } else {
            highlightedID = ids.last
        }
    }

    func chooseHighlighted() {
        guard let highlightedID,
              let item = filteredItems.first(where: { $0.id == highlightedID }),
              item.isSelectable else { return }
        onSelect(item)
    }

    func choose(_ item: PickerPanelItem) {
        guard item.isSelectable else { return }
        onSelect(item)
    }

    func close() {
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard NSApp.isActive else { return }
            self?.close()
        }
    }
}

private struct PickerPanelView: View {
    @ObservedObject var state: PickerPanelState

    @State private var isSearchFieldFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.title)
                .font(.headline)
                .foregroundStyle(.primary)

            PickerSearchField(
                placeholder: state.placeholder,
                text: $state.searchText,
                isFocused: $isSearchFieldFocused,
                onMoveDown: state.moveHighlightDown,
                onMoveUp: state.moveHighlightUp,
                onSubmit: state.chooseHighlighted,
                onCancel: state.close
            )
            .solidFocusFieldChrome(isFocused: isSearchFieldFocused)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if state.filteredItems.isEmpty {
                            Text(state.emptyText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(state.filteredItems) { item in
                                itemRow(item)
                            }
                        }
                    }
                }
                .frame(height: 240)
                .onChange(of: state.highlightedID) { _, newID in
                    guard let newID else { return }
                    // Scroll the minimal amount to keep the highlighted row
                    // visible (anchor: nil), matching the Person pickers.
                    proxy.scrollTo(newID, anchor: nil)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onChange(of: state.searchText) { _, _ in state.searchTextDidChange() }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func itemRow(_ item: PickerPanelItem) -> some View {
        let isHighlighted = state.highlightedID == item.id
        Button {
            state.choose(item)
        } label: {
            HStack(spacing: 6) {
                Text(item.title)
                    .lineLimit(1)
                if let detail = item.detail {
                    Text(detail)
                        .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isHighlighted ? Color.accentColor.opacity(0.75) : Color.clear)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!item.isSelectable)
        .opacity(item.isSelectable ? 1 : 0.4)
        .id(item.id)
    }
}
