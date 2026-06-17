//
//  AdvancedSettingsPopup.swift
//  Memor
//
//  The instance editor's "Advanced Settings" popup: a small titled panel (with the
//  standard macOS close button) opened from the bottom button row, replacing the
//  former inline "Advanced" disclosure areas. Closable via its close button or Escape.
//

import AppKit
import Combine
import SwiftUI

/// Which advanced controls to show, per the edited instance's type.
enum AdvancedSettingsKind {
    case standard      // Object / Node — max interval
    case pointMap      // PointMap — explicit viewport
    case boundaryMap   // BoundaryMap — explicit viewport
}

/// A titled, closable panel that can become key so its text fields are editable.
final class AdvancedSettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AdvancedSettingsController: NSObject, ObservableObject, NSWindowDelegate {
    private weak var panel: AdvancedSettingsPanel?
    private var escMonitor: Any?

    func present(
        from window: NSWindow?,
        draft: InstanceEditorDraft,
        kind: AdvancedSettingsKind,
        onApplyPointMapViewport: @escaping () -> Void,
        onApplyBoundaryMapViewport: @escaping () -> Void
    ) {
        guard let window else { return }
        close()

        let panel = AdvancedSettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Advanced Settings"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let hostingView = NSHostingView(
            rootView: AdvancedSettingsPopupView(
                draft: draft,
                kind: kind,
                onApplyPointMapViewport: onApplyPointMapViewport,
                onApplyBoundaryMapViewport: onApplyBoundaryMapViewport
            )
        )
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)

        let windowFrame = window.frame
        let panelSize = panel.frame.size
        let originX = windowFrame.midX - panelSize.width / 2
        let originY = windowFrame.midY - panelSize.height / 2 + windowFrame.height * 0.1
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFront(nil)
        panel.makeKey()

        // Escape closes the panel even while a text field is being edited (where the
        // field editor would otherwise swallow the key).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel else { return event }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            return event
        }

        self.panel = panel
    }

    func close() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        panel = nil
    }
}

private struct AdvancedSettingsPopupView: View {
    @ObservedObject var draft: InstanceEditorDraft
    let kind: AdvancedSettingsKind
    let onApplyPointMapViewport: () -> Void
    let onApplyBoundaryMapViewport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch kind {
            case .standard:
                maxIntervalControls
            case .pointMap:
                viewportControls(
                    lat: $draft.pointMapExplicitLat,
                    lng: $draft.pointMapExplicitLng,
                    zoom: $draft.pointMapExplicitZoom,
                    onApply: onApplyPointMapViewport
                )
            case .boundaryMap:
                viewportControls(
                    lat: $draft.boundaryMapExplicitLat,
                    lng: $draft.boundaryMapExplicitLng,
                    zoom: $draft.boundaryMapExplicitZoom,
                    onApply: onApplyBoundaryMapViewport
                )
            }
        }
        .padding(16)
    }

    private var maxIntervalControls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // fixedSize keeps the label on one line so it is never truncated.
            Text("Max Interval:")
                .font(.subheadline)
                .fixedSize()

            TextField("", text: $draft.maxIntervalText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onChange(of: draft.maxIntervalText) { _, newValue in
                    let digitsOnly = newValue.filter(\.isNumber)
                    if digitsOnly != newValue {
                        draft.maxIntervalText = digitsOnly
                    }
                }

            // Fixed width so the hint wraps to multiple lines instead of being
            // truncated.
            Text("Leave blank for no max interval.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
        }
    }

    private func viewportControls(
        lat: Binding<String>,
        lng: Binding<String>,
        zoom: Binding<String>,
        onApply: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text("Lat:")
            TextField("", text: lat)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 90)
                .onSubmit(onApply)
            Text("Lng:")
            TextField("", text: lng)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 90)
                .onSubmit(onApply)
            Text("Zoom:")
            TextField("", text: zoom)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 60)
                .onSubmit(onApply)
            Button("Apply") {
                onApply()
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }
}
