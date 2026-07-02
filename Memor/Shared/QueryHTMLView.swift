//
//  QueryHTMLView.swift
//  Memor
//
//  Rendering pipeline for query HTML plus the WKWebView wrapper used by study mode and previews.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

func renderQueryHTMLTemplate(
    _ html: String,
    fieldValuesByName: [String: String],
    booleanFieldNames: Set<String> = []
) -> String {
    fieldValuesByName.reduce(into: html) { renderedHTML, entry in
        let (name, value) = entry
        if booleanFieldNames.contains(name) {
            // Boolean fields are stored as "0"/"1". Three placeholder forms, handled
            // most-specific first (their colon counts make them mutually exclusive):
            //   {{Name:value_if_true:value_if_false}}  -> the chosen branch verbatim
            //   {{Name:bit}}                           -> "1"/"0"
            //   {{Name}}                               -> "true"/"false"
            let isTrue = value == "1"
            renderedHTML = replaceBooleanTernaryPlaceholders(in: renderedHTML, fieldName: name, isTrue: isTrue)
            renderedHTML = renderedHTML.replacingOccurrences(of: "{{\(name):bit}}", with: isTrue ? "1" : "0")
            renderedHTML = renderedHTML.replacingOccurrences(of: "{{\(name)}}", with: isTrue ? "true" : "false")
        } else {
            renderedHTML = renderedHTML.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
    }
}

// Replaces every {{fieldName:value_if_true:value_if_false}} placeholder with the
// branch selected by `isTrue`. The first colon (after the field name) and the
// second colon are separators; any later colons are part of value_if_false. Either
// branch may be empty. Consistent with how the editor recognizes placeholders,
// branch values may not contain `{` or `}`, which also keeps a match from spanning
// across adjacent placeholders.
private func replaceBooleanTernaryPlaceholders(in html: String, fieldName: String, isTrue: Bool) -> String {
    let escapedName = NSRegularExpression.escapedPattern(for: fieldName)
    // true branch: no colon, no braces; false branch: braces excluded, colons kept.
    let pattern = "\\{\\{\(escapedName):([^:{}]*):([^{}]*)\\}\\}"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

    let nsHTML = html as NSString
    let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
    guard !matches.isEmpty else { return html }

    var result = html
    // Replace from the end so earlier match ranges stay valid as we mutate.
    for match in matches.reversed() {
        let branchRange = match.range(at: isTrue ? 1 : 2)
        let replacement = branchRange.location == NSNotFound ? "" : nsHTML.substring(with: branchRange)
        if let range = Range(match.range, in: result) {
            result.replaceSubrange(range, with: replacement)
        }
    }
    return result
}

func injectQueryCSS(into html: String, appDatabase: AppDatabase, typeCSS: String) throws -> String {
    let globalQueryCSS = try appDatabase.fetchGlobalQueryCSS()
    let cssSegments = [globalQueryCSS, typeCSS].filter { !$0.isEmpty }
    guard !cssSegments.isEmpty else { return html }

    let styleTag = "<style>\n\(cssSegments.joined(separator: "\n\n"))\n</style>"

    if let headRange = html.range(of: "</head>", options: [.caseInsensitive, .backwards]) {
        var updatedHTML = html
        updatedHTML.insert(contentsOf: "\(styleTag)\n", at: headRange.lowerBound)
        return updatedHTML
    }

    return """
        <html>
        <head>
        \(styleTag)
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
}

func buildRenderedQuestionHTML(appDatabase: AppDatabase, query: StudyQuery) throws -> String {
    let previewHTML = try generatePreviewHTMLForQuestion(
        appDatabase: appDatabase,
        questionHTML: query.questionHTML,
        instanceID: query.instanceID
    )
    let renderedHTML = renderQueryHTMLTemplate(
        previewHTML,
        fieldValuesByName: query.fieldValuesByName,
        booleanFieldNames: query.booleanFieldNames
    )
    return try injectQueryCSS(into: renderedHTML, appDatabase: appDatabase, typeCSS: query.typeCSS)
}

func buildRenderedAnswerHTML(appDatabase: AppDatabase, query: StudyQuery) throws -> String {
    let previewHTML = try generatePreviewHTMLForAnswer(
        appDatabase: appDatabase,
        questionHTML: query.questionHTML,
        answerHTML: query.answerHTML,
        instanceID: query.instanceID
    )
    let renderedHTML = renderQueryHTMLTemplate(
        previewHTML,
        fieldValuesByName: query.fieldValuesByName,
        booleanFieldNames: query.booleanFieldNames
    )
    return try injectQueryCSS(into: renderedHTML, appDatabase: appDatabase, typeCSS: query.typeCSS)
}
let localImageResourceScheme = "flashcards-local-image"
let instanceLinkScheme = "id"

func parseLinkedInstanceID(from url: URL) -> Int64? {
    guard url.scheme?.lowercased() == instanceLinkScheme else { return nil }
    let prefix = "\(instanceLinkScheme):"
    let absoluteString = url.absoluteString
    guard absoluteString.hasPrefix(prefix) else { return nil }
    let identifier = String(absoluteString.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    guard !identifier.contains(":") else { return nil }
    return Int64(identifier)
}

func parseLinkedQueryID(from url: URL) -> (instanceID: Int64, queryTypeID: Int64)? {
    guard url.scheme?.lowercased() == instanceLinkScheme else { return nil }
    let prefix = "\(instanceLinkScheme):"
    let absoluteString = url.absoluteString
    guard absoluteString.hasPrefix(prefix) else { return nil }
    let body = String(absoluteString.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    let parts = body.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let instanceID = Int64(parts[0]),
          let queryTypeID = Int64(parts[1]) else { return nil }
    return (instanceID, queryTypeID)
}

func rewriteLocalFileResourceURLs(in html: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"file://[^"'\\s>]+"#) else {
        return html
    }

    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    let matches = regex.matches(in: html, range: nsRange)
    guard !matches.isEmpty else { return html }

    var rewrittenHTML = html
    for match in matches.reversed() {
        guard let range = Range(match.range, in: rewrittenHTML) else { continue }
        let originalURLString = String(rewrittenHTML[range])
        guard let encodedURLString = originalURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            continue
        }

        let replacement = "\(localImageResourceScheme)://resource?url=\(encodedURLString)"
        rewrittenHTML.replaceSubrange(range, with: replacement)
    }

    return rewrittenHTML
}

final class LocalImageURLSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard
            let requestURL = urlSchemeTask.request.url,
            let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
            let originalURLString = components.queryItems?.first(where: { $0.name == "url" })?.value,
            let fileURL = URL(string: originalURLString),
            fileURL.isFileURL
        else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }

        do {
            // Re-assert the security scope around the read via AppDatabase rather than reading
            // directly: the scopes started at launch can lapse after sleep/idle, which would
            // otherwise break rendering of already-inserted images. Falls back to a direct read
            // when no AppDatabase is available (e.g. draft previews) or the file needs no scope.
            let data: Data
            if let appDatabase = AppDatabase.shared {
                data = try appDatabase.readSecurityScopedFile(at: fileURL)
            } else {
                data = try Data(contentsOf: fileURL)
            }
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

struct QueryHTMLView: NSViewRepresentable {
    let html: String
    var disableUserInteraction: Bool = false
    var onInstanceLinkActivated: ((Int64) -> Void)? = nil
    var onQueryLinkActivated: ((Int64, Int64) -> Void)? = nil

    func makeNSView(context: Context) -> QueryWebContainerView {
        let view = QueryWebContainerView(disableUserInteraction: disableUserInteraction)
        view.onInstanceLinkActivated = onInstanceLinkActivated
        view.onQueryLinkActivated = onQueryLinkActivated
        return view
    }

    func updateNSView(_ containerView: QueryWebContainerView, context: Context) {
        containerView.onInstanceLinkActivated = onInstanceLinkActivated
        containerView.onQueryLinkActivated = onQueryLinkActivated
        containerView.loadHTML(html)
    }
}

private final class NonFirstResponderWKWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
}

final class QueryWebContainerView: NSView {
    private let webView: WKWebView
    private let imageSchemeHandler = LocalImageURLSchemeHandler()
    private let navigationDelegate = QueryWebNavigationDelegate()
    private var lastLoadedHTML: String?
    var onInstanceLinkActivated: ((Int64) -> Void)? {
        didSet {
            navigationDelegate.onInstanceLinkActivated = onInstanceLinkActivated
        }
    }
    var onQueryLinkActivated: ((Int64, Int64) -> Void)? {
        didSet {
            navigationDelegate.onQueryLinkActivated = onQueryLinkActivated
        }
    }

    init(disableUserInteraction: Bool = false) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(imageSchemeHandler, forURLScheme: localImageResourceScheme)
        if disableUserInteraction {
            webView = NonFirstResponderWKWebView(frame: .zero, configuration: configuration)
        } else {
            webView = WKWebView(frame: .zero, configuration: configuration)
        }

        super.init(frame: .zero)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = navigationDelegate
        navigationDelegate.onWebContentProcessTerminated = { [weak self] in
            guard let self, let html = self.lastLoadedHTML else { return }
            self.lastLoadedHTML = nil
            self.loadHTML(html)
        }
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadHTML(_ html: String) {
        // SwiftUI calls updateNSView (and thus loadHTML) on every unrelated state
        // change; reloading the same page would tear it down and re-commit it,
        // flashing its images as they re-fetch through the local-image scheme handler.
        guard html != lastLoadedHTML else { return }
        lastLoadedHTML = html
        webView.loadHTMLString(rewriteLocalFileResourceURLs(in: html), baseURL: nil)
    }
}

private final class QueryWebNavigationDelegate: NSObject, WKNavigationDelegate {
    var onInstanceLinkActivated: ((Int64) -> Void)?
    var onQueryLinkActivated: ((Int64, Int64) -> Void)?
    var onWebContentProcessTerminated: (() -> Void)?

    // If the web content process crashes, the container's dedup cache would
    // otherwise suppress reloading the (now blank) page.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onWebContentProcessTerminated?()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if let queryIDs = parseLinkedQueryID(from: url) {
            onQueryLinkActivated?(queryIDs.instanceID, queryIDs.queryTypeID)
            decisionHandler(.cancel)
            return
        }

        if let instanceID = parseLinkedInstanceID(from: url) {
            onInstanceLinkActivated?(instanceID)
            decisionHandler(.cancel)
            return
        }

        // External web links open in the user's default browser, not in the web view.
        if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }
}
