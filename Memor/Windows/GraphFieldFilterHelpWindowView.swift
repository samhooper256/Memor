//
//  GraphFieldFilterHelpWindowView.swift
//  Memor
//
//  Lightweight reference window describing the Graph tab's field filter,
//  opened from the help button beside the filter box.
//

import SwiftUI

struct GraphFieldFilterHelpWindowView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Field Filter")
                    .font(.headline)

                Text("Think of it as choosing which pages of a book count as citations—only links found in the listed fields draw arrows.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("By default the graph draws an arrow from one instance to another whenever any text field of the first contains a link to the second. With the field filter on, only the listed fields are scanned; links anywhere else are ignored.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Each entry is typename:fieldname, separated by spaces—for example Vocab:Definition Person:Description. Names match regardless of case. Quote an entry whose type or field name contains a space: \"Written Work:Notes\".")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("The filter changes arrows only. The nodes are still exactly the instances the search matches, so an instance whose type isn't listed still appears—with no outgoing arrows, though it can still receive them.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Autocomplete offers your types as you type and, after the colon, that type's text fields (only text fields can hold links). Return in the box runs the search. Turning the checkbox on or off re-runs the last search at once; edits to the text apply on the next Search.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("An entry naming an unknown type or field is an error—the graph isn't drawn until it's fixed. The filter is off and empty whenever you open the tab.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 500)
        .onExitCommand { dismiss() }
        .background(
            // Reliable Escape-to-close even when no control holds focus.
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }
}
