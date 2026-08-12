//
//  WebViewPrewarm.swift
//  Memor
//
//  One-shot WebKit warm-up so the session's first query webview (Study mode
//  or a Query Preview) doesn't pay in-process WebKit initialization plus the
//  first WebContent process spawn (~hundreds of ms combined) on a
//  user-visible render.
//

import AppKit

enum WebViewPrewarmer {
    private static var container: QueryWebContainerView?
    private static var didPrewarm = false

    /// Creates an unmounted QueryWebContainerView and loads a trivial page
    /// through the normal pipeline (stable memor-query:// base URL, recovery
    /// machinery intact). The container is released once the load commits —
    /// not retained forever: a page-less WebContent process drops into
    /// WebKit's process cache, where the first real query webview can pick it
    /// up warm, while a retained one would stay in-use and cost ~tens of MB.
    /// The release is deferred a runloop turn so the webview is never torn
    /// down inside its own navigation-delegate callback. Runs once per
    /// process; call it shortly after the main window's first paint.
    static func prewarm() {
        guard !didPrewarm else { return }
        didPrewarm = true
        let view = QueryWebContainerView(disableUserInteraction: true)
        container = view
        view.onContentCommitted = { _ in
            DispatchQueue.main.async {
                container = nil
            }
        }
        view.loadHTML("<html><body></body></html>")
    }
}
