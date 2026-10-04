//
//  WebViewPrewarm.swift
//  Memor
//
//  One-shot WebKit warm-up so the session's first query webview (Study mode
//  or a Query Preview) doesn't pay in-process WebKit initialization plus the
//  launch of the shared Networking/GPU helper processes (~hundreds of ms
//  combined) on a user-visible render. It cannot pre-spawn the WebContent
//  process itself — see the doc comment on prewarm().
//

import AppKit

enum WebViewPrewarmer {
    private static var container: QueryWebContainerView?
    private static var didPrewarm = false

    /// Creates an unmounted QueryWebContainerView and loads a trivial page
    /// through the normal pipeline (stable memor-query:// base URL, recovery
    /// machinery intact). The container is released once the load commits —
    /// not retained forever: a retained, page-less webview would stay in-use
    /// and cost ~tens of MB without helping the first real query (every
    /// WKWebView gets its own WebContent process, and WebKit's process cache
    /// has no capacity for apps that don't swap processes on navigation — the
    /// 2026-10-02 session log shows "WebProcessCache::canCacheProcess: Not
    /// caching process because the cache has no capacity" on every teardown).
    /// What the warm-up buys is the in-process WebKit initialization plus the
    /// Networking and GPU helper processes, which are shared and do persist.
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
