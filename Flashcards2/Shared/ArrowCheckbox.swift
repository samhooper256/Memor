//
//  ArrowCheckbox.swift
//  Memor
//
//  A small square checkbox that always shows a glyph inside the box (e.g. a
//  forward/back arrow). Checked = accent fill with a white glyph; unchecked =
//  outlined with a secondary glyph. Used in the PointMap/BoundaryMap instance
//  editors to toggle a point/boundary's forward (→) and reverse (←) queries.
//

import SwiftUI

struct ArrowCheckbox: View {
    @Binding var isOn: Bool
    let glyph: String
    var help: String? = nil

    private let size: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        Button {
            isOn.toggle()
        } label: {
            Text(glyph)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(width: size, height: size)
                .background {
                    shape.fill(isOn ? Color.accentColor : Color.clear)
                }
                .overlay {
                    shape.stroke(isOn ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help ?? "")
    }
}
