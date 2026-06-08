//
//  NodeLinkFieldEditor.swift
//  Memor
//
//  Left-pane editor for a Node instance's link fields: shows each link field's
//  selected target nodes as removable chips and a search popover for adding more.
//

import AppKit
import SwiftUI

struct NodeLinkFieldEditor: View {
    let appDatabase: AppDatabase
    let typeID: Int64
    let excludingInstanceID: Int64?
    let linkFields: [LinkField]
    @Binding var linkTargetsByLinkFieldID: [Int64: [Int64]]
    @Binding var nodeSummariesByID: [Int64: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Links")
                .font(.headline)

            if linkFields.isEmpty {
                Text("This type has no link fields.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(linkFields) { linkField in
                    NodeLinkFieldRow(
                        appDatabase: appDatabase,
                        typeID: typeID,
                        excludingInstanceID: excludingInstanceID,
                        linkField: linkField,
                        targets: targetsBinding(for: linkField.id),
                        nodeSummariesByID: $nodeSummariesByID
                    )
                }
            }
        }
    }

    private func targetsBinding(for linkFieldID: Int64) -> Binding<[Int64]> {
        Binding(
            get: { linkTargetsByLinkFieldID[linkFieldID] ?? [] },
            set: { linkTargetsByLinkFieldID[linkFieldID] = $0 }
        )
    }
}

private struct NodeLinkFieldRow: View {
    let appDatabase: AppDatabase
    let typeID: Int64
    let excludingInstanceID: Int64?
    let linkField: LinkField
    @Binding var targets: [Int64]
    @Binding var nodeSummariesByID: [Int64: String]

    @State private var isPickerPresented = false

    private var countText: String {
        let maxText = linkField.maxCount.map(String.init) ?? "∞"
        return "\(targets.count) selected (min \(linkField.minCount), max \(maxText))"
    }

    private var isWithinBounds: Bool {
        if targets.count < linkField.minCount { return false }
        if let maxCount = linkField.maxCount, targets.count > maxCount { return false }
        return true
    }

    private var canAddMore: Bool {
        guard let maxCount = linkField.maxCount else { return true }
        return targets.count < maxCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(linkField.name)
                    .fontWeight(.medium)
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(isWithinBounds ? Color.secondary : Color.red)
                Spacer(minLength: 0)
                Button("Add") {
                    isPickerPresented = true
                }
                .controlSize(.small)
                .disabled(!canAddMore)
                .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
                    NodeLinkPickerPopover(
                        appDatabase: appDatabase,
                        typeID: typeID,
                        excludingInstanceID: excludingInstanceID,
                        alreadySelected: Set(targets),
                        onSelect: { summary in
                            if !targets.contains(summary.id) {
                                targets.append(summary.id)
                                nodeSummariesByID[summary.id] = summary.displayValue
                            }
                            isPickerPresented = false
                        }
                    )
                }
            }

            if targets.isEmpty {
                Text("No links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(targets, id: \.self) { targetID in
                        NodeLinkChip(
                            label: nodeSummariesByID[targetID] ?? "#\(targetID)",
                            onRemove: {
                                targets.removeAll { $0 == targetID }
                            }
                        )
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }
}

private struct NodeLinkChip: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(formatFieldDisplayValue(label))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.15))
        .clipShape(Capsule())
    }
}

private struct NodeLinkPickerPopover: View {
    let appDatabase: AppDatabase
    let typeID: Int64
    let excludingInstanceID: Int64?
    let alreadySelected: Set<Int64>
    let onSelect: (NodeSummary) -> Void

    @State private var searchText = ""
    @State private var results: [NodeSummary] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search nodes…", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if results.isEmpty {
                        Text("No matching nodes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(results) { summary in
                            Button {
                                onSelect(summary)
                            } label: {
                                Text(formatFieldDisplayValue(summary.displayValue))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(alreadySelected.contains(summary.id))
                            .opacity(alreadySelected.contains(summary.id) ? 0.4 : 1)
                        }
                    }
                }
            }
            .frame(height: 240)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { performSearch() }
        .onChange(of: searchText) { _, _ in performSearch() }
    }

    private func performSearch() {
        results = (try? appDatabase.fetchNodeCandidates(
            forTypeID: typeID,
            matching: searchText,
            excludingInstanceID: excludingInstanceID
        )) ?? []
    }
}

// Simple wrapping layout for chips.
private struct FlowLayout: Layout {
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
        let maxX = bounds.maxX
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
