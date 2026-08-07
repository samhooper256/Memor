//
//  LinkShortcuts.swift
//  Memor
//
//  Keyboard shortcuts for `id:` instance links carried in text-field HTML via a
//  `data-shortcut` attribute. Pressing the shortcut is equivalent to clicking the link.
//  Works in Study mode (after reveal) and in Query Preview windows. When no
//  data-shortcut link claims a pressed arrow key, eligible Person queries fall
//  back to office succession navigation (resolveOfficeSuccessionShortcut).
//  See CLAUDE.md.
//

import AppKit
import Foundation

/// The closed set of accepted `data-shortcut` values, mapped to arrow keys.
enum LinkShortcutKey: CaseIterable {
    case left, right

    /// Matches the key codes used elsewhere (see KeyBinding.swift).
    var keyCode: UInt16 { self == .left ? 123 : 124 }

    var displayName: String { self == .left ? "left" : "right" }

    static func fromKeyCode(_ keyCode: UInt16) -> LinkShortcutKey? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        default:  return nil
        }
    }

    init?(dataShortcutValue raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left":  self = .left
        case "right": self = .right
        default:      return nil          // closed set; ignore anything else
        }
    }
}

/// Where an `id:` link points.
enum LinkShortcutDestination: Equatable {
    case instance(Int64)                                  // href "id:123"
    case query(instanceID: Int64, queryTypeID: Int64)     // href "id:123:456"
}

/// Result of resolving a pressed key against an instance's links.
enum LinkShortcutResolution {
    case none                                 // no link bound to this key on the instance
    case navigate(LinkShortcutDestination)
    case collision                            // 2+ links share this key -> caller alerts
}

private let anchorTagRegex = try! NSRegularExpression(
    pattern: "<a\\b[^>]*>",
    options: [.caseInsensitive]
)

/// Matches `attr="value"` or `attr='value'`; group 2 = double-quoted, group 3 = single-quoted.
private func attributeRegex(_ name: String) -> NSRegularExpression {
    try! NSRegularExpression(
        pattern: "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')",
        options: [.caseInsensitive]
    )
}

private let hrefRegex = attributeRegex("href")
private let dataShortcutRegex = attributeRegex("data-shortcut")

private func attributeValue(_ regex: NSRegularExpression, in tag: String) -> String? {
    let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
    for group in [2, 3] {
        let groupRange = match.range(at: group)
        if groupRange.location != NSNotFound, let r = Range(groupRange, in: tag) {
            return String(tag[r])
        }
    }
    return nil
}

private func destination(forHref href: String) -> LinkShortcutDestination? {
    // HTML attributes may carry an escaped ampersand; `id:` links never need other entities.
    let decoded = href.replacingOccurrences(of: "&amp;", with: "&")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: decoded) else { return nil }
    if let q = parseLinkedQueryID(from: url) {
        return .query(instanceID: q.instanceID, queryTypeID: q.queryTypeID)
    }
    if let instanceID = parseLinkedInstanceID(from: url) {
        return .instance(instanceID)
    }
    return nil
}

/// Scans the raw HTML of every field value for `<a>` tags that (a) have an `id:` href and
/// (b) carry a recognized `data-shortcut`, returning key -> [destinations]. All of the
/// instance's fields are scanned, regardless of what is visible in the current query.
func parseLinkShortcuts(fieldValues: [String: String]) -> [LinkShortcutKey: [LinkShortcutDestination]] {
    var result: [LinkShortcutKey: [LinkShortcutDestination]] = [:]
    for value in fieldValues.values {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        anchorTagRegex.enumerateMatches(in: value, range: range) { match, _, _ in
            guard let match, let tagRange = Range(match.range, in: value) else { return }
            let tag = String(value[tagRange])
            guard let shortcutRaw = attributeValue(dataShortcutRegex, in: tag),
                  let key = LinkShortcutKey(dataShortcutValue: shortcutRaw),
                  let href = attributeValue(hrefRegex, in: tag),
                  let destination = destination(forHref: href) else { return }
            result[key, default: []].append(destination)
        }
    }
    return result
}

/// Convenience used by the key handlers in Study mode and Query Preview.
func resolveLinkShortcut(_ key: LinkShortcutKey, fieldValues: [String: String]) -> LinkShortcutResolution {
    let targets = parseLinkShortcuts(fieldValues: fieldValues)[key] ?? []
    switch targets.count {
    case 0:  return .none
    case 1:  return .navigate(targets[0])
    default: return .collision
    }
}

/// Fallback when no `data-shortcut` link claims a pressed arrow key: office
/// succession navigation on Person queries. Eligible queries are the Person
/// type's user-defined queries and the built-in office queries — per-office
/// (scoped to exactly that query's office) and All Offices / user-defined
/// (the person's first listed office). Relationship built-ins are excluded.
/// ← = predecessor, → = successor. Returns the instance to open in the Query
/// Preview window, or nil when the key isn't mapped.
func resolveOfficeSuccessionShortcut(
    _ key: LinkShortcutKey,
    query: StudyQuery,
    appDatabase: AppDatabase
) -> Int64? {
    guard query.typeName == PERSON_TYPE_NAME, query.instanceID != 0 else { return nil }
    let officeID: Int64?
    switch query.personQueryKind {
    case nil, .allOffices:
        officeID = nil
    case .office:
        guard let queryOfficeID = query.personOfficeID else { return nil }
        officeID = queryOfficeID
    default:
        return nil
    }
    guard let neighbors = try? appDatabase.fetchOfficeSuccessionNeighborIDs(
        instanceID: query.instanceID,
        officeID: officeID
    ) else { return nil }
    return key == .left ? neighbors.predecessorID : neighbors.successorID
}

@MainActor
func presentLinkShortcutCollisionAlert(_ key: LinkShortcutKey) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Multiple links use the \(key.displayName) arrow shortcut"
    alert.informativeText = "This instance has more than one link assigned to that key, so it can't be opened by keyboard. Open it by clicking instead."
    alert.addButton(withTitle: "OK")
    if let window = NSApp.keyWindow {
        alert.beginSheetModal(for: window) { _ in }
    } else {
        alert.runModal()
    }
}
