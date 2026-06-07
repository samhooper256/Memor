//
//  TypePicker.swift
//  Memor
//
//  Popup shown when the user changes an instance's type from the instance editor.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class TypePickerController: ObservableObject {
    private weak var panel: HyperlinkSearchPanel?
    private var popupState: TypePickerPopupState?

    func present(types: [FlashcardType], currentTypeID: Int64?, from window: NSWindow?, onSelect: @escaping (Int64) -> Void) {
        guard let window else { return }

        close()

        let popupState = TypePickerPopupState(
            types: types,
            currentTypeID: currentTypeID,
            onSelectType: { [weak self] typeID in
                onSelect(typeID)
                self?.close()
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        self.popupState = popupState

        let panel = HyperlinkSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.delegate = popupState
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: TypePickerPopupView(state: popupState))

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
final class TypePickerPopupState: NSObject, ObservableObject, NSWindowDelegate {
    @Published var searchQuery = ""
    @Published var highlightedTypeID: Int64?
    @Published var searchFieldFocusRequest = UUID()

    let types: [FlashcardType]
    let currentTypeID: Int64?
    let onSelectType: (Int64) -> Void
    let onClose: () -> Void

    weak var panel: NSPanel?

    init(
        types: [FlashcardType],
        currentTypeID: Int64?,
        onSelectType: @escaping (Int64) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.types = types
        self.currentTypeID = currentTypeID
        self.onSelectType = onSelectType
        self.onClose = onClose
        super.init()
    }

    var filteredTypes: [FlashcardType] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return types
        }
        return types.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    func select(typeID: Int64) {
        onSelectType(typeID)
    }

    func close() {
        onClose()
    }

    func moveSelectionDown() {
        let filtered = filteredTypes
        guard !filtered.isEmpty else { return }
        if let highlightedTypeID,
           let currentIndex = filtered.firstIndex(where: { $0.id == highlightedTypeID }) {
            let nextIndex = min(currentIndex + 1, filtered.count - 1)
            self.highlightedTypeID = filtered[nextIndex].id
        } else {
            highlightedTypeID = filtered.first?.id
        }
    }

    @discardableResult
    func moveSelectionUp() -> Bool {
        let filtered = filteredTypes
        guard !filtered.isEmpty else { return true }
        guard let highlightedTypeID,
              let currentIndex = filtered.firstIndex(where: { $0.id == highlightedTypeID }) else {
            return true
        }
        if currentIndex == 0 {
            return true
        }
        self.highlightedTypeID = filtered[currentIndex - 1].id
        return false
    }

    func chooseHighlightedResult() {
        guard let highlightedTypeID else { return }
        select(typeID: highlightedTypeID)
    }

    func focusSearchField() {
        searchFieldFocusRequest = UUID()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

struct TypePickerPopupView: View {
    @ObservedObject var state: TypePickerPopupState

    var body: some View {
        VStack(spacing: 0) {
            HyperlinkSearchTextField(
                text: $state.searchQuery,
                focusRequest: state.searchFieldFocusRequest,
                canMoveDownToResults: { !state.filteredTypes.isEmpty },
                onMoveDown: state.moveSelectionDown,
                onMoveUp: state.moveSelectionUp,
                onSubmit: state.chooseHighlightedResult,
                onToggleMode: {},
                onManualFocus: {},
                onFocus: {}
            )
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.filteredTypes) { type in
                            Button {
                                state.select(typeID: type.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(type.name)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if type.id == state.currentTypeID {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    state.highlightedTypeID == type.id
                                        ? Color.accentColor.opacity(0.75)
                                        : Color.clear
                                )
                                .foregroundStyle(
                                    type.id == state.currentTypeID
                                        ? Color.green
                                        : (state.highlightedTypeID == type.id ? Color.white : Color.primary)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(type.id)
                        }
                    }
                }
                .onChange(of: state.highlightedTypeID) { _, newID in
                    if let newID {
                        proxy.scrollTo(newID, anchor: nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background {
            WindowKeyCommandHandler(
                onEscape: state.close,
                onCommandReturn: nil,
                onCommandS: nil,
                onCommandI: nil,
                onCommandO: nil
            )
        }
        .onAppear {
            state.highlightedTypeID = state.currentTypeID ?? state.filteredTypes.first?.id
            state.focusSearchField()
        }
        .onChange(of: state.searchQuery) { _, _ in
            let filtered = state.filteredTypes
            if let highlighted = state.highlightedTypeID,
               filtered.contains(where: { $0.id == highlighted }) {
                // keep current highlight
            } else {
                state.highlightedTypeID = filtered.first?.id
            }
        }
    }
}
