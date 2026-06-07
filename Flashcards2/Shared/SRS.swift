//
//  SRS.swift
//  Memor
//
//  Spaced-repetition state machine and rating-to-interval math shared by study mode and the database layer.
//

import Foundation

let QUERY_STARTER_DELAY_AGAIN = 60
let QUERY_STARTER_DELAY_HARD = 360
let QUERY_STARTER_DELAY_GOOD = 600

enum QueryState: Int, Sendable, Hashable {
    case zero = 0
    case one = 1
    case two = 2

    static let initial: QueryState = .zero
}

struct StudyResponseOutcome: Hashable {
    let newState: QueryState
    let newInterval: Int64
}

func studyResponseOutcome(
    currentState: QueryState,
    currentInterval: Int64,
    rating: StudyResponseRating
) -> StudyResponseOutcome {
    func randomThreeOrFourDays() -> Int64 {
        Int64(Int.random(in: 3...4) * 86_400)
    }
    func multiplied(_ factor: Double) -> Int64 {
        max(1, Int64((Double(currentInterval) * factor).rounded()))
    }
    func addWobble(_ interval: Int64) -> Int64 {
        let oneDay: Int64 = 86_400
        guard interval >= 11 * oneDay else { return interval }
        let days = Double(interval) / Double(oneDay)
        let lower = Int((days * 0.9).rounded())
        let upper = Int((days * 1.1).rounded())
        return Int64(Int.random(in: lower...upper)) * oneDay
    }

    switch (currentState, rating) {
    case (.zero, .again):
        return StudyResponseOutcome(newState: .zero, newInterval: Int64(QUERY_STARTER_DELAY_AGAIN))
    case (.zero, .hard):
        return StudyResponseOutcome(newState: .zero, newInterval: Int64(QUERY_STARTER_DELAY_HARD))
    case (.zero, .good):
        return StudyResponseOutcome(newState: .one, newInterval: Int64(QUERY_STARTER_DELAY_GOOD))
    case (.zero, .easy):
        return StudyResponseOutcome(newState: .two, newInterval: randomThreeOrFourDays())

    case (.one, .again):
        return StudyResponseOutcome(newState: .zero, newInterval: Int64(QUERY_STARTER_DELAY_AGAIN))
    case (.one, .hard):
        return StudyResponseOutcome(newState: .one, newInterval: Int64(QUERY_STARTER_DELAY_GOOD))
    case (.one, .good):
        return StudyResponseOutcome(newState: .two, newInterval: 86_400)
    case (.one, .easy):
        return StudyResponseOutcome(newState: .two, newInterval: randomThreeOrFourDays())

    case (.two, .again):
        return StudyResponseOutcome(newState: .one, newInterval: Int64(QUERY_STARTER_DELAY_GOOD))
    case (.two, .hard):
        return StudyResponseOutcome(newState: .two, newInterval: addWobble(multiplied(1.2)))
    case (.two, .good):
        return StudyResponseOutcome(newState: .two, newInterval: addWobble(multiplied(2.5)))
    case (.two, .easy):
        return StudyResponseOutcome(newState: .two, newInterval: addWobble(multiplied(3.25)))
    }
}

func formatStudyInterval(_ interval: Int64) -> String {
    if interval < 86_400 {
        return "\(max(1, Int((Double(interval) / 60).rounded())))m"
    } else {
        return "\(max(1, Int((Double(interval) / 86_400).rounded())))d"
    }
}
