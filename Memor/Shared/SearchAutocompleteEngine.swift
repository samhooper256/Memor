//
//  SearchAutocompleteEngine.swift
//  Memor
//
//  The pure half of search-language autocomplete (no AppKit, no database):
//  finds the completable argument at the caret, filters and ranks candidates,
//  and builds the replacement text for a chosen candidate. Kept Foundation-only
//  so a scratch `swiftc` harness can exercise it — see SearchAutocomplete.swift
//  for the popup that drives it.
//

import Foundation

/// Which argument of which component the caret is in.
nonisolated enum SearchAutocompleteKind: Equatable {
    case collection      // collection: / col:
    case type            // type:
    case office          // office:
    case queryTypeType   // qt:<here>:…  — the type argument
    case queryTypeName   // qt:Type:<here> — the query-type argument

    /// Plural noun for the popup's count header.
    var noun: String {
        switch self {
        case .collection: return "collections"
        case .type, .queryTypeType: return "types"
        case .office: return "offices"
        case .queryTypeName: return "query types"
        }
    }
}

nonisolated struct SearchAutocompleteContext: Equatable {
    let kind: SearchAutocompleteKind
    /// The component keyword exactly as typed ("col", "Collection", "qt"…);
    /// a rewrite keeps it.
    let keyword: String
    /// UTF-16 range of the whole component in the source text, quote
    /// characters included — what a chosen candidate replaces.
    let componentRange: NSRange
    /// UTF-16 source offset just after the colon that introduced this
    /// argument. The popup anchors here and stays put while the argument is
    /// typed.
    let anchorLocation: Int
    /// Quote-stripped text between the anchor and the caret — the filter text.
    let typedText: String
    /// qt: only — the type argument as typed (quote-stripped); "" otherwise.
    let queryTypeTypeArgument: String
    /// qt: only — the text after the second colon (quote-stripped), whether or
    /// not the caret is in it; "" when there is no second colon.
    let queryTypeNameArgument: String
}

nonisolated struct SearchAutocompleteCandidate: Equatable {
    let name: String
    /// Collections and types have ids (`col:67` is valid); offices and query
    /// type names are name-only.
    let id: Int64?
}

nonisolated struct SearchAutocompleteMatch: Equatable {
    let candidate: SearchAutocompleteCandidate
    /// UTF-16 range of the typed text within `candidate.name`, for emphasis;
    /// nil when the match was on the id or nothing was typed.
    let nameMatchRange: NSRange?
    /// Number of leading id digits the typed text matched (0 = none).
    let idMatchLength: Int

    /// What choosing this inserts: the id when it was found by id, else the name.
    var insertionText: String {
        if idMatchLength > 0, let id = candidate.id { return String(id) }
        return candidate.name
    }
}

nonisolated enum SearchAutocompleteEngine {
    /// One whitespace-delimited component of the source text, mirroring
    /// `tokenizeSearchQueryComponents`: quotes toggle grouping and are dropped
    /// from `content`, parentheses stand alone.
    private struct Token {
        var sourceStart: Int
        var sourceEnd: Int                    // exclusive
        var content: [UInt16] = []            // quote-stripped, UTF-16
        var contentSourceOffsets: [Int] = []  // source offset of each content unit
    }

    private static let keywordKinds: [String: SearchAutocompleteKind] = [
        "col": .collection,
        "collection": .collection,
        "type": .type,
        "office": .office,
    ]

    private static let colon: UInt16 = 0x3A

    /// The completable argument at `caretLocation` (a UTF-16 offset), or nil
    /// when the caret is not after the colon of a `col:`/`collection:`/
    /// `type:`/`office:`/`qt:` component.
    static func context(in text: String, caretLocation: Int) -> SearchAutocompleteContext? {
        guard let token = tokens(in: text).first(where: {
            $0.sourceStart <= caretLocation && caretLocation <= $0.sourceEnd
        }) else { return nil }

        let content = token.content
        guard let colonIndex = content.firstIndex(of: colon), colonIndex > 0 else { return nil }
        func substring(_ range: Range<Int>) -> String {
            String(decoding: content[range], as: UTF16.self)
        }
        let keyword = substring(0..<colonIndex)
        // Content units at or past the caret's source offset are after the caret.
        let contentCaret = token.contentSourceOffsets.firstIndex { $0 >= caretLocation } ?? content.count
        let argumentStart = colonIndex + 1
        guard contentCaret >= argumentStart else { return nil }
        let componentRange = NSRange(location: token.sourceStart, length: token.sourceEnd - token.sourceStart)
        // The source position right after a content colon.
        func anchor(afterColonAt index: Int) -> Int { token.contentSourceOffsets[index] + 1 }

        if keyword.lowercased() == "qt" {
            // The parser splits qt: at the FIRST colon after the keyword: the
            // type may not contain a colon, the query-type name may.
            let secondColonIndex = content[argumentStart...].firstIndex(of: colon)
            if let secondColonIndex, contentCaret > secondColonIndex {
                let nameStart = secondColonIndex + 1
                return SearchAutocompleteContext(
                    kind: .queryTypeName,
                    keyword: keyword,
                    componentRange: componentRange,
                    anchorLocation: anchor(afterColonAt: secondColonIndex),
                    typedText: substring(nameStart..<contentCaret),
                    queryTypeTypeArgument: substring(argumentStart..<secondColonIndex),
                    queryTypeNameArgument: substring(nameStart..<content.count)
                )
            }
            return SearchAutocompleteContext(
                kind: .queryTypeType,
                keyword: keyword,
                componentRange: componentRange,
                anchorLocation: anchor(afterColonAt: colonIndex),
                typedText: substring(argumentStart..<contentCaret),
                queryTypeTypeArgument: substring(argumentStart..<(secondColonIndex ?? content.count)),
                queryTypeNameArgument: secondColonIndex.map { substring(($0 + 1)..<content.count) } ?? ""
            )
        }

        guard let kind = keywordKinds[keyword.lowercased()] else { return nil }
        return SearchAutocompleteContext(
            kind: kind,
            keyword: keyword,
            componentRange: componentRange,
            anchorLocation: anchor(afterColonAt: colonIndex),
            typedText: substring(argumentStart..<contentCaret),
            queryTypeTypeArgument: "",
            queryTypeNameArgument: ""
        )
    }

    private static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var current: Token?
        var isInsideQuotes = false
        var offset = 0

        func flush() {
            if let token = current, !token.content.isEmpty {
                tokens.append(token)
            }
            current = nil
        }

        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            defer { offset += width }

            if scalar == "\"" {
                // Part of the component's source range, never of its content.
                isInsideQuotes.toggle()
                if current == nil {
                    current = Token(sourceStart: offset, sourceEnd: offset + 1)
                } else {
                    current?.sourceEnd = offset + 1
                }
                continue
            }

            if !isInsideQuotes && (scalar == "(" || scalar == ")") {
                flush()
                // Recorded (never completable) so caret containment stays honest.
                var paren = Token(sourceStart: offset, sourceEnd: offset + 1)
                paren.content = Array(scalar.utf16)
                paren.contentSourceOffsets = [offset]
                tokens.append(paren)
                continue
            }

            if !isInsideQuotes && scalar.properties.isWhitespace {
                flush()
                continue
            }

            if current == nil {
                current = Token(sourceStart: offset, sourceEnd: offset + width)
            }
            current?.content.append(contentsOf: scalar.utf16)
            for unit in 0..<width {
                current?.contentSourceOffsets.append(offset + unit)
            }
            current?.sourceEnd = offset + width
        }

        flush()
        return tokens
    }

    // MARK: - Replacement

    /// What replaces the component when `value` is chosen, and where the caret
    /// lands (a UTF-16 offset from the replacement's start). A component
    /// containing whitespace or parentheses is wrapped WHOLE in double quotes
    /// — the form the help windows document. A qt: type choice keeps the
    /// existing query-type argument (empty when there is none yet) and lands
    /// the caret right after its colon — inside the closing quote, if any, so
    /// the quotes stay balanced while the query-type argument is typed.
    static func replacement(for context: SearchAutocompleteContext, value: String) -> (text: String, caretOffset: Int) {
        let body: String
        let caretOffset: Int
        let caretStaysInsideQuotes: Bool
        switch context.kind {
        case .collection, .type, .office:
            body = "\(context.keyword):\(value)"
            caretOffset = body.utf16.count
            caretStaysInsideQuotes = false
        case .queryTypeType:
            let head = "\(context.keyword):\(value):"
            body = head + context.queryTypeNameArgument
            caretOffset = head.utf16.count
            caretStaysInsideQuotes = true
        case .queryTypeName:
            body = "\(context.keyword):\(context.queryTypeTypeArgument):\(value)"
            caretOffset = body.utf16.count
            caretStaysInsideQuotes = false
        }

        guard needsQuoting(body) else { return (body, caretOffset) }
        let quoted = "\"\(body)\""
        return (quoted, caretStaysInsideQuotes ? caretOffset + 1 : quoted.utf16.count)
    }

    /// Whitespace or parentheses would split the component when tokenized.
    static func needsQuoting(_ component: String) -> Bool {
        component.contains { $0.isWhitespace || $0 == "(" || $0 == ")" }
    }

    // MARK: - Matching

    /// Filters `candidates` by `typedText`. Nothing typed lists everything.
    /// Text starting with a digit matches ids by PREFIX ("22" matches 225, not
    /// 1228 — collection/type names can't start with a digit, so digits mean
    /// an id), falling back to the name for id-less candidates (office names
    /// may start with a digit). Anything else matches names by
    /// case-insensitive SUBSTRING, prefix matches ranked first. Within a rank
    /// the candidates' own order is kept.
    static func matches(in candidates: [SearchAutocompleteCandidate], typedText: String) -> [SearchAutocompleteMatch] {
        guard !typedText.isEmpty else {
            return candidates.map { SearchAutocompleteMatch(candidate: $0, nameMatchRange: nil, idMatchLength: 0) }
        }

        var prefixMatches: [SearchAutocompleteMatch] = []
        var substringMatches: [SearchAutocompleteMatch] = []
        func matchName(_ candidate: SearchAutocompleteCandidate) {
            guard let range = candidate.name.range(of: typedText, options: [.caseInsensitive]) else { return }
            let match = SearchAutocompleteMatch(
                candidate: candidate,
                nameMatchRange: NSRange(range, in: candidate.name),
                idMatchLength: 0
            )
            if range.lowerBound == candidate.name.startIndex {
                prefixMatches.append(match)
            } else {
                substringMatches.append(match)
            }
        }

        if typedText.first?.isNumber == true {
            var idMatches: [SearchAutocompleteMatch] = []
            for candidate in candidates {
                if let id = candidate.id {
                    if String(id).hasPrefix(typedText) {
                        idMatches.append(SearchAutocompleteMatch(
                            candidate: candidate,
                            nameMatchRange: nil,
                            idMatchLength: typedText.utf16.count
                        ))
                    }
                } else {
                    matchName(candidate)
                }
            }
            return idMatches + prefixMatches + substringMatches
        }

        for candidate in candidates {
            matchName(candidate)
        }
        return prefixMatches + substringMatches
    }
}
