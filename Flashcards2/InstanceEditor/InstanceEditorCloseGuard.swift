//
//  InstanceEditorCloseGuard.swift
//  Memor
//
//  Intercepts NSWindow close attempts on the Add Instance window so the
//  user can confirm before discarding in-progress data.
//

import AppKit
import SwiftUI

@MainActor
final class InstanceEditorCloseInterceptor: NSObject, NSWindowDelegate {
    weak var previousDelegate: NSWindowDelegate?
    var shouldConfirm: () -> Bool = { false }
    var presentConfirmation: (NSWindow) -> Void = { _ in }
    var bypassNextClose: Bool = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if bypassNextClose {
            bypassNextClose = false
            return true
        }
        if shouldConfirm() {
            presentConfirmation(sender)
            return false
        }
        return true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return previousDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let prev = previousDelegate, prev.responds(to: aSelector) {
            return prev
        }
        return super.forwardingTarget(for: aSelector)
    }
}

struct InstanceEditorCloseGuard: NSViewRepresentable {
    let interceptor: InstanceEditorCloseInterceptor
    let shouldConfirm: () -> Bool
    let presentConfirmation: (NSWindow) -> Void

    func makeNSView(context: Context) -> AttachingView {
        let view = AttachingView()
        view.onAttach = { window in
            install(on: window)
        }
        return view
    }

    func updateNSView(_ nsView: AttachingView, context: Context) {
        interceptor.shouldConfirm = shouldConfirm
        interceptor.presentConfirmation = presentConfirmation
        if let window = nsView.window, window.delegate !== interceptor {
            install(on: window)
        }
    }

    private func install(on window: NSWindow) {
        interceptor.shouldConfirm = shouldConfirm
        interceptor.presentConfirmation = presentConfirmation
        if window.delegate !== interceptor {
            interceptor.previousDelegate = window.delegate
            window.delegate = interceptor
        }
    }

    final class AttachingView: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onAttach?(window)
            }
        }
    }
}
