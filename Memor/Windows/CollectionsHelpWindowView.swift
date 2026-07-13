//
//  CollectionsHelpWindowView.swift
//  Memor
//
//  Lightweight reference window describing what Collections are, opened from
//  the help button next to the collection count on the Collections page.
//

import SwiftUI

struct CollectionsHelpWindowView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Collections")
                    .font(.headline)

                Text("A collection is a named group of instances. One instance can be in multiple collections simultaneously, and one collection can hold instances of different types.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Collections exist to be searched: search components can target a collection by name or ID, so a stack can be built from exactly the queries of a collection's members.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("This page lists your collections. Click one to open it—there you can rename it, give it a description, add instances, or remove instances.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("While studying, press Shift to overlay the collections that the current query's instance belongs to. Each collection's \"Visible before answer is revealed\" toggle controls whether it appears in that overlay before the answer is shown—turn it off when a collection's name would give the answer away.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Deleting a collection never deletes its instances.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 440)
        .onExitCommand { dismiss() }
        .background(
            // Reliable Escape-to-close even when no control holds focus.
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }
}
