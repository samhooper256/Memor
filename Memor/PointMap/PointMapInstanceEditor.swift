//
//  PointMapInstanceEditor.swift
//  Memor
//
//  PointMap-specific models, editor popup, move-points picker, map right-click
//  menu, and entry row used by the instance editor.
//

import AppKit
import Combine
import CoreLocation
import MapKit
import SwiftUI

struct PointMapPointDraftEntry: Identifiable, Hashable {
    let localID: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var forwardEnabled: Bool = true
    var reverseEnabled: Bool = false
    var hint: String = ""

    var id: UUID { localID }
}

enum PointMapSortMode: Hashable, CaseIterable {
    case creation
    case alphabetical

    var displayName: String {
        switch self {
        case .creation: return "Creation order"
        case .alphabetical: return "A–Z"
        }
    }
}

enum PointMapEntryRef: Hashable, Identifiable {
    case existing(Int64)
    case new(UUID)

    var id: String {
        switch self {
        case .existing(let id): return "e:\(id)"
        case .new(let localID): return "n:\(localID.uuidString)"
        }
    }
}

@MainActor
final class AddPointPopupController: ObservableObject {
    private weak var panel: HyperlinkSearchPanel?
    private var popupState: AddPointPopupState?

    /// Whether the "Add Point" popup panel is currently on screen.
    var isPresented: Bool { panel != nil }

    func present(
        from window: NSWindow?,
        initialName: String = "",
        initialHint: String = "",
        initialLatitude: String = "",
        initialLongitude: String = "",
        initialForwardEnabled: Bool = true,
        initialReverseEnabled: Bool = false,
        forwardInterval: Int64? = nil,
        reverseInterval: Int64? = nil,
        isEdit: Bool = false,
        onResetForward: (() -> Void)? = nil,
        onResetReverse: (() -> Void)? = nil,
        onSubmit: @escaping (String, Double, Double, Bool, Bool, String) -> Void
    ) {
        guard let window else { return }
        close()

        let popupState = AddPointPopupState(
            initialName: initialName,
            initialHint: initialHint,
            initialLatitude: initialLatitude,
            initialLongitude: initialLongitude,
            initialForwardEnabled: initialForwardEnabled,
            initialReverseEnabled: initialReverseEnabled,
            forwardInterval: forwardInterval,
            reverseInterval: reverseInterval,
            isEdit: isEdit,
            onSubmit: { [weak self] name, lat, lng, forward, reverse, hint in
                onSubmit(name, lat, lng, forward, reverse, hint)
                self?.close()
            },
            onResetForward: onResetForward,
            onResetReverse: onResetReverse,
            onClose: { [weak self] in
                self?.close()
            }
        )
        self.popupState = popupState

        let panel = HyperlinkSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.delegate = popupState
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let hostingView = NSHostingView(rootView: AddPointPopupView(state: popupState))
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

        // Focus the Name editor once the hosting view has settled in the panel.
        DispatchQueue.main.async { [weak popupState] in
            popupState?.nameFocusController.focusField(AddPointPopupState.nameFieldID)
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        popupState = nil
    }
}

@MainActor
final class AddPointPopupState: NSObject, ObservableObject, NSWindowDelegate {
    // The Name field is a shared InstanceTextView, which routes focus and ⌘B/⌘I
    // selection-wrapping through an AddInstanceFieldFocusController; the popup
    // owns a private one with a single synthetic field id.
    static let nameFieldID: Int64 = 1
    let nameFocusController = AddInstanceFieldFocusController()

    @Published var name: String
    @Published var hint: String
    @Published var latitude: String
    @Published var longitude: String
    @Published var forwardEnabled: Bool
    @Published var reverseEnabled: Bool
    // nil means "no stored interval" (a brand-new, unsaved point) — the interval
    // and reset button are hidden in that case.
    @Published var forwardInterval: Int64?
    @Published var reverseInterval: Int64?
    @Published var errorMessage: String?

    let isEdit: Bool
    let onSubmit: (String, Double, Double, Bool, Bool, String) -> Void
    let onResetForward: (() -> Void)?
    let onResetReverse: (() -> Void)?
    let onClose: () -> Void

    weak var panel: NSPanel?

    init(
        initialName: String,
        initialHint: String,
        initialLatitude: String,
        initialLongitude: String,
        initialForwardEnabled: Bool,
        initialReverseEnabled: Bool,
        forwardInterval: Int64?,
        reverseInterval: Int64?,
        isEdit: Bool,
        onSubmit: @escaping (String, Double, Double, Bool, Bool, String) -> Void,
        onResetForward: (() -> Void)?,
        onResetReverse: (() -> Void)?,
        onClose: @escaping () -> Void
    ) {
        self.name = initialName
        self.hint = initialHint
        self.latitude = initialLatitude
        self.longitude = initialLongitude
        self.forwardEnabled = initialForwardEnabled
        self.reverseEnabled = initialReverseEnabled
        self.forwardInterval = forwardInterval
        self.reverseInterval = reverseInterval
        self.isEdit = isEdit
        self.onSubmit = onSubmit
        self.onResetForward = onResetForward
        self.onResetReverse = onResetReverse
        self.onClose = onClose
        super.init()
    }

    func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Name is required."
            return
        }
        let trimmedLat = latitude.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLng = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lat = Double(trimmedLat), lat >= -90, lat <= 90 else {
            errorMessage = "Invalid latitude."
            return
        }
        guard let lng = Double(trimmedLng), lng >= -180, lng <= 180 else {
            errorMessage = "Invalid longitude."
            return
        }
        onSubmit(trimmedName, lat, lng, forwardEnabled, reverseEnabled, hint)
    }

    func resetForward() {
        onResetForward?()
        forwardInterval = 0
    }

    func resetReverse() {
        onResetReverse?()
        reverseInterval = 0
    }

    func close() {
        onClose()
    }

    func wrapNameSelection(openTag: String, closeTag: String) {
        _ = nameFocusController.wrapFocusedSelection(openTag: openTag, closeTag: closeTag)
    }

    /// Re-fits the borderless panel to the SwiftUI content after its height
    /// changes (the Name editor growing/shrinking, the error label appearing),
    /// keeping the top edge pinned. Async because height changes are reported
    /// during SwiftUI view updates.
    func panelContentDidResize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let contentView = panel.contentView else { return }
            let fittingSize = contentView.fittingSize
            guard fittingSize.height > 0, abs(fittingSize.height - panel.frame.height) > 0.5 else { return }
            var frame = panel.frame
            frame.origin.y -= fittingSize.height - frame.size.height
            frame.size.height = fittingSize.height
            panel.setFrame(frame, display: true)
        }
    }

    func applyPastedCoordinatePair(_ pasted: String) -> Bool {
        let trimmed = normalizeMinusSigns(pasted).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ",")
        if parts.count == 2 {
            let latPart = parts[0].trimmingCharacters(in: .whitespaces)
            let lngPart = parts[1].trimmingCharacters(in: .whitespaces)
            if Double(latPart) != nil, Double(lngPart) != nil {
                latitude = latPart
                longitude = lngPart
                return true
            }
        }
        if let (lat, lng) = parseDMSCoordinatePair(trimmed) {
            latitude = formatPastedDecimal(lat)
            longitude = formatPastedDecimal(lng)
            return true
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard NSApp.isActive else { return }
            self?.close()
        }
    }
}

private func normalizeMinusSigns(_ input: String) -> String {
    input
        .replacingOccurrences(of: "\u{2212}", with: "-") // MINUS SIGN
        .replacingOccurrences(of: "\u{2010}", with: "-") // HYPHEN
        .replacingOccurrences(of: "\u{2011}", with: "-") // NON-BREAKING HYPHEN
        .replacingOccurrences(of: "\u{2013}", with: "-") // EN DASH
        .replacingOccurrences(of: "\u{2014}", with: "-") // EM DASH
}

private func parseDMSCoordinatePair(_ input: String) -> (lat: Double, lng: Double)? {
    let normalized = input
        .replacingOccurrences(of: "′", with: "'")
        .replacingOccurrences(of: "″", with: "\"")
        .replacingOccurrences(of: "’", with: "'")
        .replacingOccurrences(of: "”", with: "\"")

    let pattern = #"(-?\d+(?:\.\d+)?)\s*°(?:\s*(\d+(?:\.\d+)?)\s*'(?:\s*(\d+(?:\.\d+)?)\s*"?)?)?\s*([NSEWnsew])?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsString = normalized as NSString
    let matches = regex.matches(in: normalized, range: NSRange(location: 0, length: nsString.length))
    guard matches.count == 2 else { return nil }

    var values: [Double] = []
    var directions: [Character?] = []

    for match in matches {
        let degRange = match.range(at: 1)
        guard degRange.location != NSNotFound,
              let deg = Double(nsString.substring(with: degRange)) else { return nil }

        var minutes = 0.0
        let minRange = match.range(at: 2)
        if minRange.location != NSNotFound,
           let m = Double(nsString.substring(with: minRange)) {
            minutes = m
        }

        var seconds = 0.0
        let secRange = match.range(at: 3)
        if secRange.location != NSNotFound,
           let s = Double(nsString.substring(with: secRange)) {
            seconds = s
        }

        var direction: Character? = nil
        let dirRange = match.range(at: 4)
        if dirRange.location != NSNotFound {
            direction = nsString.substring(with: dirRange).uppercased().first
        }

        let magnitude = abs(deg) + minutes / 60 + seconds / 3600
        var value = deg < 0 ? -magnitude : magnitude
        if let direction {
            switch direction {
            case "S", "W": value = -magnitude
            case "N", "E": value = magnitude
            default: break
            }
        }

        values.append(value)
        directions.append(direction)
    }

    var lat = values[0]
    var lng = values[1]

    let firstIsLng = directions[0].map { $0 == "E" || $0 == "W" } ?? false
    let secondIsLat = directions[1].map { $0 == "N" || $0 == "S" } ?? false
    if firstIsLng || secondIsLat {
        lat = values[1]
        lng = values[0]
    }

    guard lat >= -90, lat <= 90, lng >= -180, lng <= 180 else { return nil }
    return (lat, lng)
}

private func formatPastedDecimal(_ value: Double) -> String {
    var formatted = String(format: "%.6f", value)
    while formatted.hasSuffix("0") { formatted.removeLast() }
    if formatted.hasSuffix(".") { formatted.removeLast() }
    return formatted
}

struct MapMenuAction {
    let title: String
    let handler: () -> Void
}

struct MapRightClickContextMenu: NSViewRepresentable {
    let makeMenuActions: (CGPoint) -> [MapMenuAction]

    func makeNSView(context: Context) -> RightClickCatcherView {
        let view = RightClickCatcherView()
        view.makeMenuActions = makeMenuActions
        return view
    }

    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {
        nsView.makeMenuActions = makeMenuActions
    }

    final class RightClickCatcherView: NSView {
        var makeMenuActions: ((CGPoint) -> [MapMenuAction])?
        private var monitor: Any?
        private var pendingActions: [MapMenuAction] = []

        override var isFlipped: Bool { true }

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
                guard let maker = self.makeMenuActions else { return event }
                let actions = maker(locationInView)
                guard !actions.isEmpty else { return event }
                self.presentContextMenu(at: event, actions: actions)
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func presentContextMenu(at event: NSEvent, actions: [MapMenuAction]) {
            pendingActions = actions
            let menu = NSMenu()
            for (index, action) in actions.enumerated() {
                let item = NSMenuItem(
                    title: action.title,
                    action: #selector(handleMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.tag = index
                item.target = self
                menu.addItem(item)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func handleMenuItem(_ sender: NSMenuItem) {
            guard pendingActions.indices.contains(sender.tag) else { return }
            pendingActions[sender.tag].handler()
        }
    }
}

// Catches left double-clicks over the map and forwards the location to a handler.
// Like MapRightClickContextMenu it uses a transparent (hit-test-passthrough) view
// plus a local event monitor, so it never interferes with the map's own pan/zoom
// gestures. The handler returns true when it consumed the double-click (e.g. it
// hit a point), in which case the event is swallowed to suppress double-click zoom.
struct MapDoubleClickCatcher: NSViewRepresentable {
    let onDoubleClick: (CGPoint) -> Bool

    func makeNSView(context: Context) -> DoubleClickCatcherView {
        let view = DoubleClickCatcherView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DoubleClickCatcherView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    final class DoubleClickCatcherView: NSView {
        var onDoubleClick: ((CGPoint) -> Bool)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

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
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window, event.clickCount == 2 else { return event }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(locationInView) else { return event }
                guard let handler = self.onDoubleClick else { return event }
                return handler(locationInView) ? nil : event
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

struct PointMapEntryRow: View {
    let name: String
    @Binding var forwardEnabled: Bool
    @Binding var reverseEnabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(name.isEmpty ? AttributedString("(unnamed)") : attributedPointName(name, lineBreakReplacement: " "))
                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            ArrowCheckbox(isOn: $forwardEnabled, glyph: "\u{2192}", help: "Forward query (guess the name)")
            ArrowCheckbox(isOn: $reverseEnabled, glyph: "\u{2190}", help: "Reverse query (click the location)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// AddPointTextField wrapped in the app-standard flat chrome, blue when focused.
private struct FlatAddPointField: View {
    @Binding var text: String
    var onPasteCoordinatePair: ((String) -> Bool)? = nil

    @State private var isFocused = false

    var body: some View {
        AddPointTextField(
            text: $text,
            placeholder: "",
            onPasteCoordinatePair: onPasteCoordinatePair,
            onFocusChange: { isFocused = $0 }
        )
        .solidFocusFieldChrome(isFocused: isFocused)
    }
}

/// The multi-line HTML Name editor: the shared instance-field text view (HTML
/// syntax highlighting, Enter → "<br>" + newline, Shift+Enter → plain newline,
/// undo, entity auto-replace) in the popup's flat chrome, auto-growing with its
/// content while the panel re-fits around it.
private struct AddPointNameField: View {
    static let singleLineHeight: CGFloat = 24

    @ObservedObject var state: AddPointPopupState
    @State private var isFocused = false
    @State private var editorHeight: CGFloat = singleLineHeight

    var body: some View {
        InstanceTextView(
            text: $state.name,
            focusController: state.nameFocusController,
            fieldID: AddPointPopupState.nameFieldID,
            onSubmit: {},
            onRequestHyperlink: nil,
            onContentHeightChange: { contentHeight in
                editorHeight = max(Self.singleLineHeight, contentHeight)
            },
            onMoveToNextField: { state.panel?.selectNextKeyView(nil) },
            onMoveToPreviousField: { state.panel?.selectPreviousKeyView(nil) },
            dedupesTrailingLineBreak: true,
            onFocusChange: { isFocused = $0 }
        )
        .frame(height: editorHeight)
        .solidFocusFieldChrome(isFocused: isFocused)
        .onChange(of: editorHeight) { _, _ in
            state.panelContentDidResize()
        }
    }
}

private struct AddPointPopupView: View {
    @ObservedObject var state: AddPointPopupState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.isEdit ? "Edit Point" : "Add Point")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack(alignment: .top, spacing: 6) {
                Text("Name:")
                    .frame(width: 48, alignment: .trailing)
                    .padding(.top, 3)
                AddPointNameField(state: state)
            }

            HStack(spacing: 6) {
                Text("Hint:")
                    .frame(width: 48, alignment: .trailing)
                FlatAddPointField(text: $state.hint)
                    .frame(height: 22)
            }

            HStack(spacing: 6) {
                Text("Lat:")
                    .frame(width: 48, alignment: .trailing)
                FlatAddPointField(
                    text: $state.latitude,
                    onPasteCoordinatePair: { pasted in
                        state.applyPastedCoordinatePair(pasted)
                    }
                )
                .frame(height: 22)
                Text("Lng:")
                FlatAddPointField(text: $state.longitude)
                    .frame(height: 22)
            }

            queryRow(
                label: "Forward",
                isOn: $state.forwardEnabled,
                interval: state.forwardInterval,
                onReset: state.resetForward
            )
            queryRow(
                label: "Reverse",
                isOn: $state.reverseEnabled,
                interval: state.reverseInterval,
                onReset: state.resetReverse
            )

            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                // Submitting is ⌘Return only (WindowKeyCommandHandler below) —
                // plain Return must never submit; in the Name field it inserts
                // a "<br>" line break instead.
                Button(state.isEdit ? "Save (⌘↩)" : "Submit (⌘↩)") {
                    state.submit()
                }
            }
        }
        .frame(width: 400)
        .padding(12)
        .onChange(of: state.errorMessage) { _, _ in
            state.panelContentDidResize()
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background {
            WindowKeyCommandHandler(
                onEscape: state.close,
                onCommandReturn: state.submit,
                onCommandS: nil,
                onCommandB: { state.wrapNameSelection(openTag: "<b>", closeTag: "</b>") },
                onCommandI: { state.wrapNameSelection(openTag: "<i>", closeTag: "</i>") },
                onCommandO: nil
            )
        }
    }

    // One row: a Forward/Reverse checkbox, plus (when checked and the point has
    // stored study state) its current interval and a reset button — mirroring the
    // Object-type instance editor's per-query display.
    @ViewBuilder
    private func queryRow(
        label: String,
        isOn: Binding<Bool>,
        interval: Int64?,
        onReset: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Toggle(label, isOn: isOn)
                .toggleStyle(.checkbox)

            if isOn.wrappedValue, let interval {
                if interval == 0 {
                    Text("New")
                        .font(.subheadline)
                        .foregroundStyle(Color.blue)
                } else {
                    Text(formatStudyInterval(interval))
                        .font(.subheadline)
                        .foregroundStyle(interval < 86_400 ? Color.red : Color.green)

                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                    .help("Reset Due Date")
                }
            }

            Spacer()
        }
    }
}

private struct AddPointTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onPasteCoordinatePair: ((String) -> Bool)?
    var onFocusChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onPasteCoordinatePair: onPasteCoordinatePair)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = PastableTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        // The SwiftUI wrapper (solidFocusFieldChrome) paints the fill and the
        // focused border, so the field itself is chromeless.
        textField.focusRingType = .none
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.stringValue = text
        textField.onPaste = { pasted in
            guard let onPasteCoordinatePair = context.coordinator.onPasteCoordinatePair else { return false }
            return onPasteCoordinatePair(pasted)
        }
        // Focus gain via becomeFirstResponder (fires for clicks AND programmatic
        // makeFirstResponder) — same pattern as CollectionSelector's
        // FocusReportingTextField. Loss comes from controlTextDidEndEditing.
        textField.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.onFocusChange?(true)
        }
        context.coordinator.onFocusChange = onFocusChange
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onPasteCoordinatePair = onPasteCoordinatePair
        context.coordinator.onFocusChange = onFocusChange
        if let pastable = nsView as? PastableTextField {
            pastable.onPaste = { pasted in
                guard let onPasteCoordinatePair = context.coordinator.onPasteCoordinatePair else { return false }
                return onPasteCoordinatePair(pasted)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onPasteCoordinatePair: ((String) -> Bool)?
        var onFocusChange: ((Bool) -> Void)?

        init(
            text: Binding<String>,
            onPasteCoordinatePair: ((String) -> Bool)?
        ) {
            _text = text
            self.onPasteCoordinatePair = onPasteCoordinatePair
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            text = textField.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            onFocusChange?(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Swallow Enter: submitting the point is ⌘Return only.
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertLineBreak(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                return true
            }
            return false
        }
    }

    final class PastableTextField: NSTextField {
        var onPaste: ((String) -> Bool)?
        var onBecomeFirstResponder: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let didBecome = super.becomeFirstResponder()
            if didBecome { onBecomeFirstResponder?() }
            return didBecome
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "v" {
                if let pasted = NSPasteboard.general.string(forType: .string),
                   let handled = onPaste?(pasted), handled {
                    return true
                }
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
