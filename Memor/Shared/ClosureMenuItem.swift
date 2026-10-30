//
//  ClosureMenuItem.swift
//  Memor
//
//  An NSMenuItem that runs a closure — for menus built in Swift where a
//  selector target would be a nuisance (Study mode's Quick Graph submenu).
//

import AppKit

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire(_ sender: Any?) {
        handler()
    }
}
