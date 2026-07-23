//
//  PickerPanel.swift
//  Memor
//
//  A generic pick-one-item panel: a centered borderless panel (the Add Point
//  popup's presentation, for actions with no anchor view — e.g. context-menu
//  items) whose content mirrors the Person editor's picker popovers — a
//  keyboard-navigable search field over a list of rows, with unselectable rows
//  grayed out. Used by the PointMap move-points picker and the Search window's
//  add/remove-collection pickers. The interior (PickerListView) is also
//  embeddable on its own in an anchored popover — the Person editor's Offices
//  picker — with an optional trailing accessory row ("Create office …").
//

import AppKit
import Combine
import SwiftUI

/// Tracks the picker popovers currently on screen (the Person editor's
/// relationship/succession pickers and the Offices picker) so the instance
/// editor's Escape handler can close the open popover instead of the whole
/// window. Needed because the editor's local key monitor sees Escape BEFORE
/// the popover's field editor can consume it whenever the key event targets
/// the editor window rather than the popover. Views register onAppear and
/// unregister onDisappear, keyed by a per-presentation token; realistically
/// one popover is open at a time, but the keyed order keeps an overlapping
/// close-A-while-B-opens sequence correct.
final class PickerPopoverEscapeRegistry {
    static let shared = PickerPopoverEscapeRegistry()

    private var cancelsByToken: [UUID: () -> Void] = [:]
    private var order: [UUID] = []

    func register(_ token: UUID, cancel: @escaping () -> Void) {
        if cancelsByToken[token] == nil {
            order.append(token)
        }
        cancelsByToken[token] = cancel
    }

    func unregister(_ token: UUID) {
        cancelsByToken[token] = nil
        order.removeAll { $0 == token }
    }

    /// Closes the most recently opened popover. Returns false when none is open.
    @discardableResult
    func closeTopmost() -> Bool {
        guard let token = order.last, let cancel = cancelsByToken[token] else { return false }
        cancel()
        return true
    }
}

struct PickerPanelItem: Identifiable, Hashable {
    let id: Int64
    let title: String
    /// Secondary label shown after the title, e.g. "(current)".
    var detail: String? = nil
    /// Unselectable rows render grayed out and are skipped by the arrow keys.
    var isSelectable: Bool = true
}

/// The optional trailing action row below the item list (after a divider),
/// e.g. the Offices picker's "Create office …" row. Arrow-key navigable like
/// the item rows; rendered as an accent-colored plus-circle label.
struct PickerPanelAccessoryRow {
    let title: String
    let action: () -> Void
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
    /// Sentinel highlight id for the accessory row (item ids are rowids ≥ 1).
    static let accessoryRowID: Int64 = -1

    @Published var searchText = ""
    @Published var highlightedID: Int64?
    /// Shown in red under the list (e.g. a failed create-office attempt).
    @Published var errorMessage: String?

    let title: String
    let placeholder: String
    let emptyText: String
    let onSelect: (PickerPanelItem) -> Void
    let onClose: () -> Void

    /// Fixed item list, filtered in-memory by the search text…
    private let staticItems: [PickerPanelItem]
    /// …or a live provider re-queried on each search change (the Offices
    /// picker's DB search, whose LIMIT then applies to the matches rather
    /// than to the whole list).
    private let itemsProvider: ((String) -> [PickerPanelItem])?
    @Published private var providedItems: [PickerPanelItem] = []

    /// Builds the trailing accessory row for the current trimmed search text
    /// (nil = no row). Settable after init so the closure can reference the
    /// state (e.g. to surface an errorMessage).
    var accessoryRowProvider: ((String) -> PickerPanelAccessoryRow?)?

    weak var panel: NSPanel?

    init(
        title: String,
        placeholder: String,
        emptyText: String,
        items: [PickerPanelItem] = [],
        itemsProvider: ((String) -> [PickerPanelItem])? = nil,
        onSelect: @escaping (PickerPanelItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.emptyText = emptyText
        self.staticItems = items
        self.itemsProvider = itemsProvider
        self.onSelect = onSelect
        self.onClose = onClose
        super.init()
        if let itemsProvider {
            providedItems = itemsProvider("")
        }
        highlightedID = navigableIDs.first
    }

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var filteredItems: [PickerPanelItem] {
        if itemsProvider != nil { return providedItems }
        guard !trimmedSearchText.isEmpty else { return staticItems }
        return staticItems.filter { $0.title.localizedCaseInsensitiveContains(trimmedSearchText) }
    }

    var accessoryRow: PickerPanelAccessoryRow? {
        accessoryRowProvider?(trimmedSearchText)
    }

    /// Rows the arrow keys traverse — unselectable rows are skipped.
    var navigableIDs: [Int64] {
        var ids = filteredItems.filter(\.isSelectable).map(\.id)
        if accessoryRow != nil {
            ids.append(Self.accessoryRowID)
        }
        return ids
    }

    func searchTextDidChange() {
        if let itemsProvider {
            providedItems = itemsProvider(trimmedSearchText)
        }
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
        guard let highlightedID else { return }
        if highlightedID == Self.accessoryRowID {
            accessoryRow?.action()
            return
        }
        guard let item = filteredItems.first(where: { $0.id == highlightedID }),
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

/// Per-instance identity (the AnyObject default ObjectIdentifier id) so a
/// fresh state can drive item-based popover presentation. Required explicitly:
/// NSObject subclasses don't satisfy Identifiable generic requirements on
/// their own.
extension PickerPanelState: Identifiable {}

/// The picker interior — search field, navigable list, optional accessory row
/// and error line. Embeddable in an anchored popover (the Offices picker) as
/// well as the centered panel chrome below.
struct PickerListView: View {
    @ObservedObject var state: PickerPanelState

    @State private var isSearchFieldFocused = false
    @State private var escapeToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

                        if let accessory = state.accessoryRow {
                            Divider()
                                .padding(.vertical, 4)
                            accessoryRowView(accessory)
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

            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: state.searchText) { _, _ in state.searchTextDidChange() }
        .onAppear {
            PickerPopoverEscapeRegistry.shared.register(escapeToken, cancel: state.close)
        }
        .onDisappear {
            PickerPopoverEscapeRegistry.shared.unregister(escapeToken)
        }
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

    @ViewBuilder
    private func accessoryRowView(_ accessory: PickerPanelAccessoryRow) -> some View {
        let isHighlighted = state.highlightedID == PickerPanelState.accessoryRowID
        Button(action: accessory.action) {
            Label(accessory.title, systemImage: "plus.circle")
                .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(isHighlighted ? Color.accentColor.opacity(0.75) : Color.clear)
        }
        .buttonStyle(.plain)
        .id(PickerPanelState.accessoryRowID)
    }
}

private struct PickerPanelView: View {
    @ObservedObject var state: PickerPanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.title)
                .font(.headline)
                .foregroundStyle(.primary)

            PickerListView(state: state)
        }
        .padding(12)
        .frame(width: 300)
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
}
