//
//  Utilities.swift
//  Memor
//
//  Created by Codex on 4/1/26.
//

import AppKit
import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

func uniteQuestionAndAnswerWithDefaultSeparator(questionHTML: String, answerHTML: String) -> String {
    return "\(questionHTML)\n\n<hr>\n\n\(answerHTML)"
}

func generatePreviewHTMLForQuestion(
    appDatabase: AppDatabase,
    questionHTML: String,
    instanceID: Int64? = nil,
    collectionIDsOverride: Set<Int64>? = nil
) throws -> String {
    let globalQueryHTML = try appDatabase.fetchGlobalQueryHTML()

    let collectionsToken = "{{#CollectionClasses}}"
    var html = globalQueryHTML
    if html.contains(collectionsToken) {
        let classes = resolveCollectionIDs(
            appDatabase: appDatabase,
            instanceID: instanceID,
            override: collectionIDsOverride
        ).map { "_col\($0)" }.joined(separator: " ")
        html = html.replacingOccurrences(of: collectionsToken, with: classes)
    }

    if let contentRange = html.range(of: "{{#Content}}") {
        html = html.replacingCharacters(in: contentRange, with: questionHTML)
    }

    let withCollectionIDs = substituteCollectionIDsToken(
        in: html, appDatabase: appDatabase, instanceID: instanceID, override: collectionIDsOverride
    )
    return substituteInstanceIDToken(in: withCollectionIDs, instanceID: instanceID)
}

func generatePreviewHTMLForAnswer(
    appDatabase: AppDatabase,
    questionHTML: String,
    answerHTML: String,
    instanceID: Int64? = nil,
    collectionIDsOverride: Set<Int64>? = nil
) throws -> String {
    let previewHTML = try generatePreviewHTMLForQuestion(
        appDatabase: appDatabase,
        questionHTML: answerHTML,
        instanceID: instanceID,
        collectionIDsOverride: collectionIDsOverride
    )

    let withQuestion = previewHTML.replacingOccurrences(of: "{{#QuestionContent}}", with: questionHTML)
    // Re-run the instance-scoped tokens: {{#QuestionContent}} may have spliced the
    // raw question HTML (with its own tokens) in after the first pass.
    let withCollectionIDs = substituteCollectionIDsToken(
        in: withQuestion, appDatabase: appDatabase, instanceID: instanceID, override: collectionIDsOverride
    )
    return substituteInstanceIDToken(in: withCollectionIDs, instanceID: instanceID)
}

/// Collection membership for the {{#CollectionClasses}}/{{#CollectionIDs}}
/// tokens, sorted ascending. The instance editor's Query Preview passes its
/// draft's checked collections as the override so the tokens reflect unsaved
/// checkbox state (and resolve at all for Add-mode drafts, which have no
/// instance row); everything else falls back to the persisted membership.
private func resolveCollectionIDs(
    appDatabase: AppDatabase,
    instanceID: Int64?,
    override: Set<Int64>?
) -> [Int64] {
    if let override { return override.sorted() }
    guard let instanceID,
          let ids = try? appDatabase.fetchCollectionIDs(forInstanceID: instanceID) else { return [] }
    return ids.sorted()
}

private func substituteCollectionIDsToken(
    in html: String,
    appDatabase: AppDatabase,
    instanceID: Int64?,
    override: Set<Int64>?
) -> String {
    let token = "{{#CollectionIDs}}"
    guard html.contains(token) else { return html }

    let ids = resolveCollectionIDs(appDatabase: appDatabase, instanceID: instanceID, override: override)
    let arrayLiteral = "[" + ids.map(String.init).joined(separator: ",") + "]"
    return html.replacingOccurrences(of: token, with: arrayLiteral)
}

/// Replaces every `{{#InstanceID}}` token with the instance's numeric id (a
/// string of digits). During template previews there is no concrete instance,
/// so the token resolves to an empty string.
private func substituteInstanceIDToken(in html: String, instanceID: Int64?) -> String {
    let token = "{{#InstanceID}}"
    guard html.contains(token) else { return html }
    return html.replacingOccurrences(of: token, with: instanceID.map(String.init) ?? "")
}

/// One run of a field's partially rendered display value: text plus the
/// bold/italic state it sits in.
struct FieldDisplayRun {
    var text: String
    var bold: Bool
    var italic: Bool
}

/// The partial-rendering rules behind every instance/query row label — the
/// Instances table, the Search window, query rows and, as HTML/plain text,
/// the Graph tab's tooltips: `<br>` becomes "; "; `<b>`/`<i>` (nesting
/// counted, attributes allowed, case-insensitive) style their text and are
/// dropped; every other tag is dropped but its inner text kept; self-closing
/// tags vanish entirely; everything else — entities included — is literal.
func fieldDisplayRuns(_ raw: String) -> [FieldDisplayRun] {
    // 1. Replace <br> (with optional surrounding whitespace) with "; "
    let text = raw.replacingOccurrences(
        of: #"\s*<br>\s*"#,
        with: "; ",
        options: .regularExpression
    )

    // 2. Parse bold and italic markers, strip all other HTML tags
    typealias StyledRun = FieldDisplayRun

    var runs: [StyledRun] = []
    var boldDepth = 0
    var italicDepth = 0
    var current = ""
    let scanner = text[text.startIndex...]
    var i = scanner.startIndex

    while i < scanner.endIndex {
        if scanner[i] == "<" {
            // Try to match a tag
            if let tagEnd = scanner[i...].firstIndex(of: ">") {
                // Half-open range so an empty "<>" yields "" instead of an
                // inverted (index(after:)…index(before:)) range, which crashes
                // with "Range requires lowerBound <= upperBound".
                let tagContent = String(scanner[scanner.index(after: i)..<tagEnd])
                    .trimmingCharacters(in: .whitespaces)
                let tagLower = tagContent.lowercased()

                // Check for self-closing tags (e.g. <img ... />) — delete entirely
                if tagContent.hasSuffix("/") {
                    if !current.isEmpty {
                        runs.append(StyledRun(text: current, bold: boldDepth > 0, italic: italicDepth > 0))
                        current = ""
                    }
                    i = scanner.index(after: tagEnd)
                    continue
                }

                if tagLower == "b" || tagLower.hasPrefix("b ") {
                    if !current.isEmpty {
                        runs.append(StyledRun(text: current, bold: boldDepth > 0, italic: italicDepth > 0))
                        current = ""
                    }
                    boldDepth += 1
                    i = scanner.index(after: tagEnd)
                    continue
                } else if tagLower == "/b" {
                    if !current.isEmpty {
                        runs.append(StyledRun(text: current, bold: boldDepth > 0, italic: italicDepth > 0))
                        current = ""
                    }
                    boldDepth = max(0, boldDepth - 1)
                    i = scanner.index(after: tagEnd)
                    continue
                } else if tagLower == "i" || tagLower.hasPrefix("i ") {
                    if !current.isEmpty {
                        runs.append(StyledRun(text: current, bold: boldDepth > 0, italic: italicDepth > 0))
                        current = ""
                    }
                    italicDepth += 1
                    i = scanner.index(after: tagEnd)
                    continue
                } else if tagLower == "/i" {
                    if !current.isEmpty {
                        runs.append(StyledRun(text: current, bold: boldDepth > 0, italic: italicDepth > 0))
                        current = ""
                    }
                    italicDepth = max(0, italicDepth - 1)
                    i = scanner.index(after: tagEnd)
                    continue
                } else if tagLower.hasPrefix("/") || tagLower.first?.isLetter == true {
                    // Other HTML tag — strip it but keep inner text
                    if !current.isEmpty {
                        runs.append(StyledRun(text: current, bold: boldDepth > 0, italic: italicDepth > 0))
                        current = ""
                    }
                    i = scanner.index(after: tagEnd)
                    continue
                }
            }
        }

        current.append(scanner[i])
        i = scanner.index(after: i)
    }

    if !current.isEmpty {
        runs.append(StyledRun(text: current, bold: boldDepth > 0, italic: italicDepth > 0))
    }

    return runs
}

func formatFieldDisplayValue(_ raw: String) -> AttributedString {
    var result = AttributedString()
    for run in fieldDisplayRuns(raw) {
        var attr = AttributedString(run.text)
        if run.bold && run.italic {
            attr.font = .system(.body).bold().italic()
        } else if run.bold {
            attr.font = .system(.body).bold()
        } else if run.italic {
            attr.font = .system(.body).italic()
        }
        result.append(attr)
    }

    return result
}

/// The same rendering as safe HTML for a web view: text escaped, bold and
/// italic as `<b>`/`<i>` (the Graph tab's hover tooltips).
func fieldDisplayHTML(_ raw: String) -> String {
    fieldDisplayRuns(raw).map { run in
        var html = run.text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if run.italic { html = "<i>\(html)</i>" }
        if run.bold { html = "<b>\(html)</b>" }
        return html
    }.joined()
}

/// The same rendering as plain text — what a row shows, styling dropped
/// (the Graph tab's ⌘F find matches against this).
func fieldDisplayPlainText(_ raw: String) -> String {
    fieldDisplayRuns(raw).map(\.text).joined()
}


/// Delete-confirmation body shared by the instance-delete alerts. Appends the
/// Person consequences line when any pending instance is a Person linked to
/// others (relationship and office succession references convert to plain
/// names).
func personDeletionConsequencesMessage(appDatabase: AppDatabase, pendingInstanceIDs: [Int64]) -> String {
    var message = "This action is irreversible."
    let connected = (try? appDatabase.connectedPersonCount(instanceIDs: pendingInstanceIDs)) ?? 0
    if connected > 0 {
        let subject: String
        if pendingInstanceIDs.count == 1 {
            subject = "This person is"
        } else if connected == 1 {
            subject = "One of these is a person"
        } else {
            subject = "\(connected) of these are people"
        }
        message += " \(subject) linked to others: relationship and office succession references become plain names."
    }
    return message
}
