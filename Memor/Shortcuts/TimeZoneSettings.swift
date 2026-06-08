//
//  TimeZoneSettings.swift
//  Memor
//
//  Persisted, app-wide time zone preference used by every due-date calculation.
//

import Combine
import Foundation

/// A selectable time zone option shown in Settings.
struct TimeZoneOption: Identifiable {
    /// The IANA / `Etc` identifier persisted and passed to `TimeZone(identifier:)`.
    let identifier: String
    /// The label shown to the user (e.g. "Central Time", "GMT+5").
    let displayName: String
    var id: String { identifier }
}

@MainActor
final class TimeZoneSettings: ObservableObject {
    static let shared = TimeZoneSettings()
    private static let userDefaultsKey = "com.sam.Memor.timeZoneSettings"
    private static let identifierField = "timeZoneIdentifier"

    /// Central Time is the default. Uses the IANA identifier so it auto-adjusts for U.S. DST.
    static let defaultIdentifier = "America/Chicago"

    /// U.S. time zones, identified by IANA names so they automatically follow U.S. daylight
    /// saving time without the user changing this setting.
    static let usTimeZoneOptions: [TimeZoneOption] = [
        TimeZoneOption(identifier: "America/New_York", displayName: "Eastern Time"),
        TimeZoneOption(identifier: "America/Chicago", displayName: "Central Time"),
        TimeZoneOption(identifier: "America/Denver", displayName: "Mountain Time"),
        TimeZoneOption(identifier: "America/Phoenix", displayName: "Mountain Time (Arizona, no DST)"),
        TimeZoneOption(identifier: "America/Los_Angeles", displayName: "Pacific Time"),
        TimeZoneOption(identifier: "America/Anchorage", displayName: "Alaska Time"),
        TimeZoneOption(identifier: "Pacific/Honolulu", displayName: "Hawaii Time")
    ]

    /// Fixed-offset GMT zones from GMT-12 through GMT+14. These intentionally do not observe DST.
    /// Note the `Etc/GMT` sign convention is inverted from the displayed offset, so GMT+5 (UTC+5)
    /// maps to the identifier `Etc/GMT-5`.
    static let gmtTimeZoneOptions: [TimeZoneOption] = (-12...14).map { offset in
        let identifier: String
        if offset == 0 {
            identifier = "Etc/GMT"
        } else if offset > 0 {
            identifier = "Etc/GMT-\(offset)"
        } else {
            identifier = "Etc/GMT+\(-offset)"
        }
        let displayName = offset >= 0 ? "GMT+\(offset)" : "GMT\(offset)"
        return TimeZoneOption(identifier: identifier, displayName: displayName)
    }

    /// Every identifier the user is allowed to select.
    static let allowedIdentifiers: Set<String> = Set(
        (usTimeZoneOptions + gmtTimeZoneOptions).map(\.identifier)
    )

    @Published var timeZoneIdentifier: String {
        didSet { persist() }
    }

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.userDefaultsKey) ?? [:]
        let stored = raw[Self.identifierField] as? String
        if let stored, Self.allowedIdentifiers.contains(stored) {
            timeZoneIdentifier = stored
        } else {
            timeZoneIdentifier = Self.defaultIdentifier
        }
    }

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(identifier: Self.defaultIdentifier)
            ?? TimeZone(identifier: "UTC")!
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func startOfTomorrowTimestamp(now: Date = Date()) -> Int64 {
        let cal = calendar
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        return Int64(startOfTomorrow.timeIntervalSince1970)
    }

    private func persist() {
        UserDefaults.standard.set(
            [Self.identifierField: timeZoneIdentifier],
            forKey: Self.userDefaultsKey
        )
    }
}
