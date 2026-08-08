//
//  SettingsWindowView.swift
//  Memor
//
//  Settings window for customizing keyboard shortcuts.
//

import AppKit
import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject var shortcuts: ShortcutSettings
    @ObservedObject var editorSettings: EditorSettings = EditorSettings.shared
    @ObservedObject var soundSettings: SoundSettings = SoundSettings.shared
    @ObservedObject var timeZoneSettings: TimeZoneSettings = TimeZoneSettings.shared
    @ObservedObject var developerState: DeveloperState = DeveloperState.shared
    let appDatabase: AppDatabase
    @State private var recordingAction: ShortcutAction? = nil
    @State private var conflictAlert: ConflictAlertInfo? = nil
    @State private var showResetAllAlert = false
    @State private var grantedFolders: [ImageFolderAccess] = []
    @State private var folderError: String? = nil
    @State private var selectedTab: SettingsTab = .general
    @Environment(\.dismiss) private var dismiss

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case keyboardShortcuts = "Keyboard Shortcuts"

        var id: String { rawValue }
        var title: String { rawValue }
    }

    private static let timeZoneGroups: [(region: String, options: [TimeZoneOption])] = [
        (region: "United States", options: TimeZoneSettings.usTimeZoneOptions),
        (region: "GMT Offsets", options: TimeZoneSettings.gmtTimeZoneOptions)
    ]

    private func formattedCurrentTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a z"
        formatter.timeZone = timeZoneSettings.timeZone
        return formatter.string(from: date)
    }

    private struct ConflictAlertInfo: Identifiable {
        let id = UUID()
        let action: ShortcutAction
        let otherAction: ShortcutAction
        let binding: KeyBinding
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    generalTab
                case .keyboardShortcuts:
                    keyboardShortcutsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 520)
        .navigationTitle("Settings")
        .background {
            WindowKeyCommandHandler(
                onEscape: {
                    if recordingAction != nil {
                        recordingAction = nil
                    } else {
                        dismiss()
                    }
                },
                onCommandReturn: nil,
                onCommandS: nil,
                onCommandI: nil,
                onCommandO: nil
            )
        }
        .alert("Reset all shortcuts?", isPresented: $showResetAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset All", role: .destructive) { shortcuts.resetAll() }
        } message: {
            Text("Every keyboard shortcut will be restored to its default.")
        }
        .alert(item: $conflictAlert) { info in
            Alert(
                title: Text("Shortcut Already Used"),
                message: Text("\(info.binding.displayString) is assigned to \"\(info.otherAction.title)\". Reassign it to \"\(info.action.title)\"?"),
                primaryButton: .destructive(Text("Reassign")) {
                    shortcuts.reset(info.otherAction)
                    shortcuts.set(info.binding, for: info.action)
                },
                secondaryButton: .cancel()
            )
        }
        .task {
            reloadGrantedFolders()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                sidebarRow(tab)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Text(tab.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color.clear)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var generalTab: some View {
        List {
            Section(header: Text("Data Storage").font(.headline)) {
                dataStorageSection
            }

            Section(header: Text("Image Folder Access").font(.headline)) {
                imageFolderAccessSection
            }

            Section(header: Text("Audio & Sounds").font(.headline)) {
                Toggle(isOn: $soundSettings.soundEffectsEnabled) {
                    Text("Sound Effects")
                }
            }

            Section(header: Text("Editor Behavior").font(.headline)) {
                Toggle(isOn: $editorSettings.autoReplaceHTMLEntities) {
                    Text("Auto-replace `<<` with `&lt;` and `>>` with `&gt;`")
                }
            }

            Section(header: Text("Time Zone").font(.headline)) {
                timeZoneSection
            }

            Section(header: Text("Developer").font(.headline)) {
                Toggle(isOn: $developerState.allowDeveloperModeAccess) {
                    Text("Allow Developer Mode access")
                }
            }
        }
        .listStyle(.inset)
    }

    private var keyboardShortcutsTab: some View {
        VStack(spacing: 0) {
            List {
                ForEach(ShortcutCategory.allCases) { category in
                    Section(header: Text(category.title).font(.headline)) {
                        ForEach(ShortcutAction.allCases.filter {
                            $0.category == category
                                && ($0 != .toggleDeveloperMode || developerState.allowDeveloperModeAccess)
                        }) { action in
                            ShortcutRowView(
                                action: action,
                                shortcuts: shortcuts,
                                recordingAction: $recordingAction,
                                onCaptured: { binding in handleCapture(binding, for: action) }
                            )
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button("Reset All to Defaults") {
                    showResetAllAlert = true
                }
                .disabled(shortcuts.bindings.isEmpty)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var dataStorageSection: some View {
        Text("This is the SQLite database file where all your Memor data is stored.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            Text(appDatabase.databaseFilePath)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Open in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: appDatabase.databaseFilePath)]
                )
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var timeZoneSection: some View {
        Text("Determines the date Memor uses for due-date calculations on the Stacks page and in Study mode.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Picker("Time Zone", selection: $timeZoneSettings.timeZoneIdentifier) {
            ForEach(Self.timeZoneGroups, id: \.region) { group in
                Section(header: Text(group.region)) {
                    ForEach(group.options) { option in
                        Text(option.displayName).tag(option.identifier)
                    }
                }
            }
        }

        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("Current time: \(formattedCurrentTime(context.date))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var imageFolderAccessSection: some View {
        Text("Folders you grant access to here let Memor read any image file inside them — required for agents that add images via MCP, and for images in your flashcards to keep working after you relaunch.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if grantedFolders.isEmpty {
            Text("No folders granted yet.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(grantedFolders) { folder in
                HStack {
                    Text(folder.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Revoke") {
                        revoke(folder)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            }
        }

        HStack {
            Button("Grant Folder Access…") {
                grantFolderAccess()
            }
            .buttonStyle(.bordered)
            Spacer()
        }

        if let folderError {
            Text(folderError)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func reloadGrantedFolders() {
        do {
            grantedFolders = try appDatabase.fetchImageFolderAccesses()
        } catch {
            folderError = "Failed to load granted folders: \(error.localizedDescription)"
        }
    }

    private func grantFolderAccess() {
        let panel = NSOpenPanel()
        panel.title = "Grant Folder Access"
        panel.message = "Choose a folder Memor should be allowed to read images from."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        do {
            _ = try appDatabase.grantImageFolderAccess(folderURL: folderURL)
            folderError = nil
            reloadGrantedFolders()
        } catch {
            folderError = "Failed to grant access: \(error.localizedDescription)"
        }
    }

    private func revoke(_ folder: ImageFolderAccess) {
        do {
            try appDatabase.revokeImageFolderAccess(id: folder.id)
            folderError = nil
            reloadGrantedFolders()
        } catch {
            folderError = "Failed to revoke access: \(error.localizedDescription)"
        }
    }

    private func handleCapture(_ binding: KeyBinding, for action: ShortcutAction) {
        recordingAction = nil
        if let conflict = shortcuts.conflictingAction(for: binding, excluding: action) {
            conflictAlert = ConflictAlertInfo(action: action, otherAction: conflict, binding: binding)
        } else {
            shortcuts.set(binding, for: action)
        }
    }
}

private struct ShortcutRowView: View {
    let action: ShortcutAction
    @ObservedObject var shortcuts: ShortcutSettings
    @Binding var recordingAction: ShortcutAction?
    let onCaptured: (KeyBinding) -> Void

    private var isRecording: Bool { recordingAction == action }
    private var binding: KeyBinding { shortcuts.binding(for: action) }
    private var isDefault: Bool { shortcuts.isDefault(action) }

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()

            if isRecording {
                ShortcutKeyRecorder(onCaptured: onCaptured, onCancel: { recordingAction = nil })
                    .frame(width: 140, height: 22)
            } else {
                Text(binding.displayString)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    .cornerRadius(4)
            }

            Button(isRecording ? "Cancel" : "Record…") {
                recordingAction = isRecording ? nil : action
            }
            .buttonStyle(.bordered)

            Button("Reset") {
                shortcuts.reset(action)
            }
            .buttonStyle(.bordered)
            .disabled(isDefault)
        }
        .padding(.vertical, 2)
    }
}

/// An NSViewRepresentable that captures the next keyDown event as a KeyBinding.
private struct ShortcutKeyRecorder: NSViewRepresentable {
    let onCaptured: (KeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCaptured = onCaptured
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onCaptured = onCaptured
        nsView.onCancel = onCancel
    }

    final class RecorderView: NSView {
        var onCaptured: ((KeyBinding) -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    // Escape cancels without capturing.
                    if event.keyCode == 53 {
                        self.onCancel?()
                        return nil
                    }
                    if let binding = KeyBinding.fromEvent(event) {
                        self.onCaptured?(binding)
                        return nil
                    }
                    return event
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            dirtyRect.fill()
            let text = "Press keys…"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ]
            let attributed = NSAttributedString(string: text, attributes: attrs)
            let size = attributed.size()
            let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
            attributed.draw(at: point)
        }
    }
}
