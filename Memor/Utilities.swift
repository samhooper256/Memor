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
    instanceID: Int64? = nil
) throws -> String {
    let globalQueryHTML = try appDatabase.fetchGlobalQueryHTML()

    let collectionsToken = "{{#CollectionClasses}}"
    var html = globalQueryHTML
    if html.contains(collectionsToken) {
        let classes: String
        if let instanceID,
           let ids = try? appDatabase.fetchCollectionIDs(forInstanceID: instanceID) {
            classes = ids.sorted().map { "_col\($0)" }.joined(separator: " ")
        } else {
            classes = ""
        }
        html = html.replacingOccurrences(of: collectionsToken, with: classes)
    }

    if let contentRange = html.range(of: "{{#Content}}") {
        html = html.replacingCharacters(in: contentRange, with: questionHTML)
    }

    return substituteCollectionIDsToken(in: html, appDatabase: appDatabase, instanceID: instanceID)
}

func generatePreviewHTMLForAnswer(
    appDatabase: AppDatabase,
    questionHTML: String,
    answerHTML: String,
    instanceID: Int64? = nil
) throws -> String {
    let previewHTML = try generatePreviewHTMLForQuestion(
        appDatabase: appDatabase,
        questionHTML: answerHTML,
        instanceID: instanceID
    )

    let withQuestion = previewHTML.replacingOccurrences(of: "{{#QuestionContent}}", with: questionHTML)
    return substituteCollectionIDsToken(in: withQuestion, appDatabase: appDatabase, instanceID: instanceID)
}

private func substituteCollectionIDsToken(
    in html: String,
    appDatabase: AppDatabase,
    instanceID: Int64?
) -> String {
    let token = "{{#CollectionIDs}}"
    guard html.contains(token) else { return html }

    let arrayLiteral: String
    if let instanceID,
       let ids = try? appDatabase.fetchCollectionIDs(forInstanceID: instanceID) {
        arrayLiteral = "[" + ids.sorted().map(String.init).joined(separator: ",") + "]"
    } else {
        arrayLiteral = "[]"
    }
    return html.replacingOccurrences(of: token, with: arrayLiteral)
}
func formatFieldDisplayValue(_ raw: String) -> AttributedString {
    // 1. Replace <br> (with optional surrounding whitespace) with "; "
    let text = raw.replacingOccurrences(
        of: #"\s*<br>\s*"#,
        with: "; ",
        options: .regularExpression
    )

    // 2. Parse bold and italic markers, strip all other HTML tags
    struct StyledRun {
        var text: String
        var bold: Bool
        var italic: Bool
    }

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

    var result = AttributedString()
    for run in runs {
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

