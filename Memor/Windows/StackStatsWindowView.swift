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

    @State private var counts: [DueDayCount] = []
    @State private var errorMessage: String?

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
        }
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
