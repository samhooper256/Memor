//
//  FinderRowSelection.swift
//  Memor
//
//  Finder-style (NSTableView-style) click selection for hand-built row
//  lists that can't use List(selection:):
//
//    - click:          select only that row; it becomes the anchor
//    - ⌘-click:        toggle that row, keep the rest; it becomes the anchor
//    - shift-click:    select the contiguous range anchor…row (in the
//                      list's current display order) on top of whatever was
//                      selected when the anchor was set — so successive
//                      shift-clicks grow AND shrink the range around the
//                      anchor, as in Finder
//    - empty space:    deselect everything (`clear()`)
//

import AppKit

struct FinderRowSelection<ID: Hashable> {
    private(set) var selection: Set<ID> = []
    /// The row the next shift-click extends from.
    private var anchor: ID?
    /// The selection a shift range is layered over: what was selected when
    /// the anchor was last set, so a new shift-click REPLACES the previous
    /// shift range instead of accumulating it.
    private var base: Set<ID> = []

    func contains(_ id: ID) -> Bool { selection.contains(id) }

    /// `order` is the rows in their current on-screen order (the range a
    /// shift-click spans).
    mutating func click(_ id: ID, order: [ID], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) {
            guard let anchor,
                  let anchorIndex = order.firstIndex(of: anchor),
                  let clickedIndex = order.firstIndex(of: id) else {
                // No usable anchor (none yet, or filtered out of view): add
                // the row and start a new anchor there.
                base = selection
                selection.insert(id)
                self.anchor = id
                return
            }
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            selection = base.union(order[range])
        } else if modifiers.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            anchor = id
            base = selection
        } else {
            selection = [id]
            anchor = id
            base = []
        }
    }

    mutating func clear() {
        selection = []
        anchor = nil
        base = []
    }
}
