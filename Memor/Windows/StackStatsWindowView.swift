//
//  StackStatsWindowView.swift
//  Memor
//
//  Per-stack "Stats" window. For now it shows a 10-day due-date forecast: how
//  many of the stack's queries fall due on each of the next 10 days, as a green
//  bar chart. Opened from the Stats button on a stack card.
//

import Charts
import Combine
import SwiftUI

@MainActor
final class StackStatsWindowState: ObservableObject {
    @Published private(set) var stackName = ""
    @Published private(set) var stackSearch = ""
    @Published private(set) var requestNonce = UUID()

    func requestOpen(stackName: String, stackSearch: String) {
        self.stackName = stackName
        self.stackSearch = stackSearch
        requestNonce = UUID()
    }
}

struct StackStatsWindowView: View {
    let appDatabase: AppDatabase
    @EnvironmentObject private var windowState: StackStatsWindowState
    @Environment(\.dismiss) private var dismiss

    @State private var counts: [DueDayCount] = []
    @State private var errorMessage: String?
    // The bar the pointer is currently hovering, if any (drives the count label).
    @State private var hoveredDate: Date?

    private static let forecastDays = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Stats For \(windowState.stackName)")
                .font(.title2)
                .bold()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            Group {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    forecastChart
                }
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { reload() }
        .onChange(of: windowState.requestNonce) { _, _ in reload() }
        .onExitCommand { dismiss() }
        .background(
            // Reliable Escape-to-close even when no control holds focus.
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }

    private var forecastChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Queries due over the next \(Self.forecastDays) days")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Chart(counts) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Queries due", day.count)
                )
                .foregroundStyle(.green)
                .annotation(position: .top, alignment: .center) {
                    if hoveredDate == day.date {
                        Text("\(day.count)")
                            .font(.caption)
                            .bold()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .windowBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.secondary.opacity(0.4))
                            )
                    }
                }
            }
            .chartXAxisLabel("Day")
            .chartYAxisLabel("Queries due")
            .chartXAxis {
                AxisMarks(values: counts.map(\.date)) { value in
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(.defaultDigits))
                }
            }
            .chartYAxis {
                // Integer-only ticks — fractional query counts are meaningless.
                AxisMarks(values: .automatic(desiredCount: min(6, (counts.map(\.count).max() ?? 0) + 1))) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoveredDate = barDate(at: location, proxy: proxy, geo: geo)
                            case .ended:
                                hoveredDate = nil
                            }
                        }
                }
            }
        }
    }

    // Maps a pointer location over the plot to the date of the bar it's nearest
    // to, so hovering anywhere on/around a bar surfaces that bar's count.
    private func barDate(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let plotRect = geo[plotFrame]
        guard plotRect.contains(location) else { return nil }
        guard let date: Date = proxy.value(atX: location.x - plotRect.minX) else { return nil }
        // Snap to the nearest day bucket by absolute time distance.
        return counts.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })?.date
    }

    private func reload() {
        let search = windowState.stackSearch
        Task {
            do {
                let result = try appDatabase.fetchStackDueDayCounts(stackSearch: search, days: Self.forecastDays)
                counts = result
                errorMessage = nil
            } catch {
                counts = []
                errorMessage = "Couldn't load stats: \(error.localizedDescription)"
            }
        }
    }
}
