//
//  FlowLayout.swift
//  Memor
//
//  Simple wrapping layout for chips: subviews flow left-to-right and wrap onto
//  new rows when they would exceed the proposed width.
//

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: maxWidth == .infinity ? totalWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        var row: [(subview: LayoutSubview, size: CGSize)] = []
        var rowWidth: CGFloat = 0

        // Rows are gathered before placing so mixed-height content (caption
        // labels next to taller chips) can be vertically centered per row.
        func placeRow() {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for (subview, size) in row {
                subview.place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += rowHeight + spacing
            row = []
            rowWidth = 0
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > bounds.width, !row.isEmpty {
                placeRow()
            }
            row.append((subview, size))
            rowWidth += size.width + spacing
        }
        placeRow()
    }
}
