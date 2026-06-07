//
//  GlobalCodeEditorWindow.swift
//  Memor
//
//  Window for editing the app-wide query HTML and CSS globals, plus its close-with-unsaved-changes gate.
//

import AppKit
import SwiftUI

enum GlobalCodeEditorKind {
    case html
    case css

    var title: String {
        switch self {
        case .html:
            return "Edit Global HTML"
        case .css:
            return "Edit Global CSS"
        }
    }

    var variableName: String {
        switch self {
        case .html:
            return "global_query_html"
        case .css:
            return "global_query_css"
        }
    }
}

struct GlobalCodeEditorWindowView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var shortcutSettings: ShortcutSettings

    let appDatabase: AppDatabase
    let kind: GlobalCodeEditorKind

    @State private var text = ""
    @State private var savedText = ""
    @State private var errorMessage: String?
    @State private var isFocused = false
    @State private var isDiscardConfirmationPresented = false
    @State private var allowWindowClose = false

    private var hasUnsavedChanges: Bool {
        text != savedText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind.title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            PlainCodeTextView(
                text: $text,
                highlightedTokens: kind == .html ? ["{{#Content}}"] : [],
                fieldNames: [],
                isFocused: $isFocused
            )
            .frame(height: 500)

            Divider()

            HStack(spacing: 10) {
                if hasUnsavedChanges {
                    Text("You have unsaved changes.")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)

                Button {
                    Task {
                        await save()
                    }
                } label: {
                    Text("Save (\(shortcutSettings.binding(for: .typesSaveCurrent).displayString))")
                        .font(.subheadline)
                        .fontWeight(.regular)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(minWidth: 44)
                        .background(hasUnsavedChanges ? Color.accentColor : Color.gray.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!hasUnsavedChanges)
                .shortcut(.typesSaveCurrent, settings: shortcutSettings)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 700, minHeight: 620)
        .task {
            await load()
        }
        .background(
            WindowCloseConfirmationHandler(
                hasUnsavedChanges: hasUnsavedChanges,
                allowWindowClose: $allowWindowClose,
                onAttemptDiscard: {
                    isDiscardConfirmationPresented = true
                }
            )
        )
        .alert(
            "Discard unsaved changes?",
            isPresented: $isDiscardConfirmationPresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) {
                allowWindowClose = true
                dismiss()
            }
        } message: {
            Text("This will discard your unsaved changes.")
        }
        .onExitCommand {
            if hasUnsavedChanges {
                isDiscardConfirmationPresented = true
            } else {
                dismiss()
            }
        }
    }

    @MainActor
    private func load() async {
        do {
            let loadedText: String
            switch kind {
            case .html:
                loadedText = try appDatabase.fetchGlobalQueryHTML()
            case .css:
                loadedText = try appDatabase.fetchGlobalQueryCSS()
            }
            text = loadedText
            savedText = loadedText
            errorMessage = nil
            allowWindowClose = false
            isFocused = true
        } catch {
            errorMessage = "Failed to load \(kind.variableName)."
        }
    }

    @MainActor
    private func save() async {
        do {
            switch kind {
            case .html:
                try appDatabase.updateGlobalQueryHTML(text)
            case .css:
                try appDatabase.updateGlobalQueryCSS(text)
            }
            savedText = text
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save \(kind.variableName)."
        }
    }
}

private struct WindowCloseConfirmationHandler: NSViewRepresentable {
    let hasUnsavedChanges: Bool
    @Binding var allowWindowClose: Bool
    let onAttemptDiscard: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            hasUnsavedChanges: hasUnsavedChanges,
            allowWindowClose: $allowWindowClose,
            onAttemptDiscard: onAttemptDiscard
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hasUnsavedChanges = hasUnsavedChanges
        context.coordinator.onAttemptDiscard = onAttemptDiscard
        context.coordinator.allowWindowClose = $allowWindowClose
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var hasUnsavedChanges: Bool
        var allowWindowClose: Binding<Bool>
        var onAttemptDiscard: () -> Void
        weak var window: NSWindow?
        weak var previousDelegate: NSWindowDelegate?

        init(
            hasUnsavedChanges: Bool,
            allowWindowClose: Binding<Bool>,
            onAttemptDiscard: @escaping () -> Void
        ) {
            self.hasUnsavedChanges = hasUnsavedChanges
            self.allowWindowClose = allowWindowClose
            self.onAttemptDiscard = onAttemptDiscard
        }

        func attach(to view: NSView) {
            guard let window = view.window, self.window !== window else { return }
            previousDelegate = window.delegate
            window.delegate = self
            self.window = window
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowWindowClose.wrappedValue {
                allowWindowClose.wrappedValue = false
                return true
            }
            if hasUnsavedChanges {
                onAttemptDiscard()
                return false
            }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }
    }
}

