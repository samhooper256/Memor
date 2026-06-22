//
//  TableSizePicker.swift
//  Memor
//
//  Lightweight centered popup (modeled on the Change Type popup) for choosing the
//  size of a table to insert into a field editor. Rows/Cols numeric fields plus a
//  10x10 hover/click grid; Enter inserts the size in the text boxes.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class TableSizePickerController: ObservableObject {
    private weak var panel: HyperlinkSearchPanel?
    private var pickerState: TableSizePickerState?

    func present(
        initialRows: Int,
        initialCols: Int,
        from window: NSWindow?,
        onInsert: @escaping (Int, Int) -> Void
    ) {
        guard let window else { return }

        close()

        let state = TableSizePickerState(
            initialRows: initialRows,
            initialCols: initialCols,
            onInsert: { [weak self] rows, cols in
                onInsert(rows, cols)
                self?.close()
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        self.pickerState = state

        let panel = HyperlinkSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.delegate = state
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: TableSizePickerView(state: state))

        let windowFrame = window.frame
        let panelSize = panel.frame.size
        let originX = windowFrame.midX - panelSize.width / 2
        let originY = windowFrame.midY - panelSize.height / 2 + windowFrame.height * 0.15
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFront(nil)
        panel.makeKey()

        state.panel = panel
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        pickerState = nil
    }
}

@MainActor
final class TableSizePickerState: NSObject, ObservableObject, NSWindowDelegate {
    static let gridSize = 10
    static let maxSize = 50

    @Published var rowsText: String
    @Published var colsText: String
    @Published var hoveredRow: Int?
    @Published var hoveredCol: Int?

    let onInsert: (Int, Int) -> Void
    let onClose: () -> Void

    weak var panel: NSPanel?

    init(
        initialRows: Int,
        initialCols: Int,
        onInsert: @escaping (Int, Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.rowsText = String(initialRows)
        self.colsText = String(initialCols)
        self.onInsert = onInsert
        self.onClose = onClose
        super.init()
    }

    /// Parses a field's text into a clamped count (1...maxSize); empty/invalid -> 1.
    private func parse(_ text: String) -> Int {
        let value = Int(text.filter(\.isNumber)) ?? 1
        return min(max(value, 1), Self.maxSize)
    }

    var parsedRows: Int { parse(rowsText) }
    var parsedCols: Int { parse(colsText) }

    func insertFromTextFields() {
        onInsert(parsedRows, parsedCols)
    }

    func insert(row: Int, col: Int) {
        onInsert(min(max(row, 1), Self.maxSize), min(max(col, 1), Self.maxSize))
    }

    func close() {
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

struct TableSizePickerView: View {
    @ObservedObject var state: TableSizePickerState
    @FocusState private var focusedField: Field?

    private enum Field {
        case rows
        case cols
    }

    private let cellSize: CGFloat = 22
    private let cellSpacing: CGFloat = 3

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Rows:")
                numericField(text: $state.rowsText, field: .rows)
                Text("Cols:")
                numericField(text: $state.colsText, field: .cols)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.top, 12)

            VStack(spacing: 6) {
                grid

                // Show the hovered table size (e.g. "3x4") centered under the grid.
                // An empty string reserves the row height so the grid doesn't shift.
                Text(hoverSizeText)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .frame(height: 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
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
            TableSizePickerReturnHandler(onReturn: state.insertFromTextFields)
        }
        .onAppear {
            focusedField = .rows
        }
    }

    private func numericField(text: Binding<String>, field: Field) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 44)
            .multilineTextAlignment(.center)
            .focused($focusedField, equals: field)
            .onChange(of: text.wrappedValue) { _, newValue in
                let digitsOnly = newValue.filter(\.isNumber)
                if digitsOnly != newValue {
                    text.wrappedValue = digitsOnly
                }
            }
            .onSubmit { state.insertFromTextFields() }
    }

    private var hoverSizeText: String {
        guard let row = state.hoveredRow, let col = state.hoveredCol else { return "" }
        return "\(row)x\(col)"
    }

    private var grid: some View {
        let fillRows = min(state.parsedRows, TableSizePickerState.gridSize)
        let fillCols = min(state.parsedCols, TableSizePickerState.gridSize)
        return VStack(spacing: cellSpacing) {
            ForEach(1...TableSizePickerState.gridSize, id: \.self) { row in
                HStack(spacing: cellSpacing) {
                    ForEach(1...TableSizePickerState.gridSize, id: \.self) { col in
                        cell(row: row, col: col, fillRows: fillRows, fillCols: fillCols)
                    }
                }
            }
        }
    }

    private func cell(row: Int, col: Int, fillRows: Int, fillCols: Int) -> some View {
        let isFilled = row <= fillRows && col <= fillCols
        let inHoverRect: Bool = {
            guard let hr = state.hoveredRow, let hc = state.hoveredCol else { return false }
            return row <= hr && col <= hc
        }()
        let outlineColor: Color = isFilled
            ? .clear
            : (inHoverRect ? .blue : Color.gray.opacity(0.6))

        return RoundedRectangle(cornerRadius: 2)
            .fill(isFilled ? Color.blue : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(outlineColor, lineWidth: 1)
            }
            .frame(width: cellSize, height: cellSize)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    state.hoveredRow = row
                    state.hoveredCol = col
                } else if state.hoveredRow == row && state.hoveredCol == col {
                    state.hoveredRow = nil
                    state.hoveredCol = nil
                }
            }
            .onTapGesture {
                state.insert(row: row, col: col)
            }
    }
}

/// Installs a local key monitor (scoped to the popup's window) so plain Return/Enter
/// inserts a table even when focus isn't in a text field.
private struct TableSizePickerReturnHandler: NSViewRepresentable {
    let onReturn: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onReturn = onReturn
    }

    final class KeyView: NSView {
        var onReturn: (() -> Void)?
        private var monitor: Any?

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
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 else {
                    return event
                }
                self.onReturn?()
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
