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

func buildRenderedQuestionHTML(
    appDatabase: AppDatabase,
    query: StudyQuery,
    collectionIDsOverride: Set<Int64>? = nil
) throws -> String {
    let previewHTML = try generatePreviewHTMLForQuestion(
        appDatabase: appDatabase,
        questionHTML: query.questionHTML,
        instanceID: query.instanceID,
        collectionIDsOverride: collectionIDsOverride
    )
    let (substitutedHTML, typeCSS) = try substitutingPersonOffices(
        appDatabase: appDatabase, query: query, html: previewHTML
    )
    let renderedHTML = renderQueryHTMLTemplate(
        substitutedHTML,
        fieldValuesByName: query.fieldValuesByName,
        booleanFieldNames: query.booleanFieldNames
    )
    return try injectQueryCSS(into: renderedHTML, appDatabase: appDatabase, typeCSS: typeCSS)
}

func buildRenderedAnswerHTML(
    appDatabase: AppDatabase,
    query: StudyQuery,
    collectionIDsOverride: Set<Int64>? = nil
) throws -> String {
    let previewHTML = try generatePreviewHTMLForAnswer(
        appDatabase: appDatabase,
        questionHTML: query.questionHTML,
        answerHTML: query.answerHTML,
        instanceID: query.instanceID,
        collectionIDsOverride: collectionIDsOverride
    )
    let (substitutedHTML, typeCSS) = try substitutingPersonOffices(
        appDatabase: appDatabase, query: query, html: previewHTML
    )
    let renderedHTML = renderQueryHTMLTemplate(
        substitutedHTML,
        fieldValuesByName: query.fieldValuesByName,
        booleanFieldNames: query.booleanFieldNames
    )
    return try injectQueryCSS(into: renderedHTML, appDatabase: appDatabase, typeCSS: typeCSS)
}

/// `_offices` support for Person queries: the FIRST element with id "_offices"
/// in the authored HTML gets its contents replaced with per-office succession
/// rows (see AppDatabase.renderPersonOfficesElements). Returns the html and the
/// typeCSS to inject — a standard Person query's typeCSS lacks the built-in
/// default CSS that styles the generated .office-succession/.person-* markup,
/// so it is prepended here (built-in Person queries already carry it).
private func substitutingPersonOffices(
    appDatabase: AppDatabase,
    query: StudyQuery,
    html: String
) throws -> (html: String, typeCSS: String) {
    guard query.typeName == PERSON_TYPE_NAME, html.contains("_offices") else {
        return (html, query.typeCSS)
    }
    let substituted = try appDatabase.renderPersonOfficesElements(in: html, instanceID: query.instanceID)
    let typeCSS = query.personQueryKind == nil
        ? AppDatabase.personBuiltinQueryDefaultCSS + "\n\n" + query.typeCSS
        : query.typeCSS
    return (substituted, typeCSS)
}
let localImageResourceScheme = "flashcards-local-image"
let instanceLinkScheme = "id"

/// Stable base URL for every query `loadHTMLString`. With `baseURL: nil` each
/// query is an about:blank document with an EMPTY registrable domain, and
/// WebKit's WebProcessCache refuses to cache such processes — so every query
/// load spawned a fresh WebContent helper and tore down the old one (64
/// helpers in one 67-minute study session; one spawn hit a RunningBoard
/// registration flake and left a permanently blank query, 2026-07-18). A
/// stable non-empty host makes consecutive loads same-site so one WebContent
/// process is reused.
///
/// - This scheme must NEVER be registered via setURLSchemeHandler: WebKit
///   forces a process swap when navigating to a registered scheme.
/// - Same-origin side effect: all queries/previews share one (in-memory,
///   ephemeral) storage bucket. No app-generated HTML uses storage.
/// - If custom schemes turn out not to be process-cached (undocumented),
///   flip this single line to `URL(string: "https://memor-query.invalid/")!`
///   — decidePolicyFor matches this constant's scheme+host, nothing else
///   changes. Verify local images still render before adopting the fallback.
let queryHTMLBaseURL = URL(string: "memor-query://query/")!

/// The single ephemeral data store shared by every WKWebView in the app (still
/// non-persistent — nothing touches disk). Each `WKWebsiteDataStore.nonPersistent()`
/// call mints a distinct store with its own networking session and defeats WebKit's
/// web-content-process reuse, so per-view stores made every query/preview spawn fresh
/// helper processes — each spawn logging a burst of sandbox XPC-denial noise.
let sharedEphemeralWebsiteDataStore = WKWebsiteDataStore.nonPersistent()

/// Configuration shared by all of Memor's WKWebViews, which only ever render
/// locally generated HTML: the shared ephemeral data store, and no Safari
/// safe-browsing lookups (external links open in the default browser anyway;
/// the lookups just fail against the sandbox and log SafariSafeBrowsing errors).
func makeLocalContentWebViewConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = sharedEphemeralWebsiteDataStore
    configuration.preferences.isFraudulentWebsiteWarningEnabled = false
    return configuration
}

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
    // Raw string: `\s` reaches ICU as the whitespace class. (It was `\\s` — a
    // literal backslash plus the letter s — which truncated every match at the
    // first "s" in the path; the rewrite only worked because the un-encoded
    // tail happened to reassemble after the substitution.)
    guard let regex = try? NSRegularExpression(pattern: #"file://[^"'\s>]+"#) else {
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
    var onContentCommitted: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> QueryWebContainerView {
        let view = QueryWebContainerView(disableUserInteraction: disableUserInteraction)
        view.onInstanceLinkActivated = onInstanceLinkActivated
        view.onQueryLinkActivated = onQueryLinkActivated
        view.onContentCommitted = onContentCommitted
        return view
    }

    func updateNSView(_ containerView: QueryWebContainerView, context: Context) {
        containerView.onInstanceLinkActivated = onInstanceLinkActivated
        containerView.onQueryLinkActivated = onQueryLinkActivated
        containerView.onContentCommitted = onContentCommitted
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

    // Recovery state. Every startLoad bumps loadGeneration (staleness token for
    // the timers) and records the WKNavigation returned by loadHTMLString (the
    // identity token for delegate callbacks — failures of cancelled link-click
    // navigations must not trigger recovery of the page load).
    private var currentNavigation: WKNavigation?
    private var loadGeneration = 0
    private var hasCommittedCurrentLoad = false
    private var currentLoadStartedAt: Date?
    private var retryCount = 0
    private var commitWatchdog: DispatchWorkItem?
    private var pendingRetry: DispatchWorkItem?
    private var didBecomeActiveObserver: NSObjectProtocol?

    private static let maxAutomaticRetries = 3
    private static let commitTimeout: TimeInterval = 5
    private static let retryDelays: [TimeInterval] = [0.25, 1.0, 4.0]

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
    /// Fired on didCommit of each page load with the HTML that committed
    /// (empty string for blank loads). Hosts use it to keep a progress
    /// indicator up until real content is actually painting, and the launch
    /// pre-warm uses it to release its webview once the process is warm.
    var onContentCommitted: ((String) -> Void)?

    init(disableUserInteraction: Bool = false) {
        let configuration = makeLocalContentWebViewConfiguration()
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

        navigationDelegate.onNavigationCommitted = { [weak self] navigation in
            guard let self, navigation === self.currentNavigation else { return }
            self.hasCommittedCurrentLoad = true
            // A committed load restores the full recovery budget — this is what
            // lets WebKit's occasional memory-budget kill of the (long-lived,
            // shared) WebContent process act as a self-recovering recycle.
            self.retryCount = 0
            self.commitWatchdog?.cancel()
            self.onContentCommitted?(self.lastLoadedHTML ?? "")
        }
        navigationDelegate.onNavigationFailed = { [weak self] navigation, error in
            guard let self, navigation === self.currentNavigation else { return }
            let nsError = error as NSError
            // Superseded loads (NSURLErrorCancelled) and policy-cancelled
            // navigations (WebKit 102, "frame load interrupted") are not
            // failures; retrying on them would reload the query under the user.
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
            self.scheduleRetry()
        }
        navigationDelegate.onWebContentProcessTerminated = { [weak self] in
            self?.scheduleRetry()
        }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.retryIfLoadNeverCommitted()
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

    deinit {
        commitWatchdog?.cancel()
        pendingRetry?.cancel()
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    func loadHTML(_ html: String) {
        // SwiftUI calls updateNSView (and thus loadHTML) on every unrelated state
        // change; reloading the same page would tear it down and re-commit it,
        // flashing its images as they re-fetch through the local-image scheme handler.
        guard html != lastLoadedHTML else { return }
        lastLoadedHTML = html
        retryCount = 0
        startLoad(html)
    }

    // One load attempt — new content or a recovery retry. Recovery calls this
    // directly, bypassing loadHTML's dedup guard: the guard exists to swallow
    // SwiftUI update spam, not to block reloading a blank page.
    private func startLoad(_ html: String) {
        loadGeneration += 1
        hasCommittedCurrentLoad = false
        currentLoadStartedAt = Date()
        pendingRetry?.cancel()
        armCommitWatchdog(forGeneration: loadGeneration)
        currentNavigation = webView.loadHTMLString(
            rewriteLocalFileResourceURLs(in: html),
            baseURL: queryHTMLBaseURL
        )
    }

    // A load that never commits fires no delegate callback at all (observed
    // 2026-07-18: a WebContent process RunningBoard never registered — alive
    // but suspended, never painting). This timeout is the only recovery for
    // that case. Staleness is handled by capturing the generation by value; a
    // timer that outlives its load is a no-op.
    private func armCommitWatchdog(forGeneration generation: Int) {
        commitWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.loadGeneration == generation,
                  !self.hasCommittedCurrentLoad else { return }
            self.scheduleRetry()
        }
        commitWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commitTimeout, execute: work)
    }

    private func scheduleRetry() {
        guard lastLoadedHTML != nil, retryCount < Self.maxAutomaticRetries else { return }
        let delay = Self.retryDelays[retryCount]
        retryCount += 1
        let generation = loadGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.loadGeneration == generation,
                  let html = self.lastLoadedHTML else { return }
            self.startLoad(html)
        }
        pendingRetry?.cancel()
        pendingRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // The 2026-07-18 manual recovery (switch apps and back), automated: if the
    // newest load is uncommitted and stale, returning to the app retries with a
    // fresh budget. Also covers recovery timers deferred by App Nap while the
    // app was inactive. The age check keeps a healthy in-flight load from
    // being clobbered.
    private func retryIfLoadNeverCommitted() {
        guard let html = lastLoadedHTML,
              !hasCommittedCurrentLoad,
              let startedAt = currentLoadStartedAt,
              Date().timeIntervalSince(startedAt) >= Self.commitTimeout else { return }
        retryCount = 0
        startLoad(html)
    }
}

private final class QueryWebNavigationDelegate: NSObject, WKNavigationDelegate {
    var onInstanceLinkActivated: ((Int64) -> Void)?
    var onQueryLinkActivated: ((Int64, Int64) -> Void)?
    var onWebContentProcessTerminated: (() -> Void)?
    var onNavigationCommitted: ((WKNavigation?) -> Void)?
    var onNavigationFailed: ((WKNavigation?, Error) -> Void)?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onWebContentProcessTerminated?()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onNavigationCommitted?(navigation)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        onNavigationFailed?(navigation, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onNavigationFailed?(navigation, error)
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

        // User-authored RELATIVE hrefs resolve against queryHTMLBaseURL. Under
        // the old nil baseURL they resolved against about:blank and went
        // nowhere; keep that no-op behavior — allowing them would top-level
        // navigate to a base-scheme URL with no handler and blank the query.
        // Same-document fragment links stay allowed (in-page scroll). This
        // branch must run BEFORE the external http/https branch so that with
        // an https fallback base, base-relative links are cancelled here
        // instead of opening a dead link in the browser.
        if url.scheme?.lowercased() == queryHTMLBaseURL.scheme,
           url.host?.lowercased() == queryHTMLBaseURL.host {
            if url.fragment != nil,
               let currentURL = webView.url,
               urlStringIgnoringFragment(url) == urlStringIgnoringFragment(currentURL) {
                decisionHandler(.allow)
                return
            }
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

private func urlStringIgnoringFragment(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    return components?.string ?? url.absoluteString
}
