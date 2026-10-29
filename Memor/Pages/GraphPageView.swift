//
//  GraphPageView.swift
//  Memor
//
//  Graph page: search instances and render a force-directed node/edge graph.
//

import AppKit
import SwiftUI
import WebKit

/// How the page lays the graph out: a spanning forest drawn top-down (tree
/// edges never cross) or the force simulation. A display preference, so it
/// persists.
enum GraphLayoutMode: String, CaseIterable, Identifiable {
    case tree
    case force

    static let userDefaultsKey = "com.sam.Memor.graphLayoutMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tree: return "Tree"
        case .force: return "Force"
        }
    }
}

struct GraphPageView: View {
    @EnvironmentObject private var shortcutSettings: ShortcutSettings

    let appDatabase: AppDatabase

    @AppStorage(GraphLayoutMode.userDefaultsKey) private var layoutMode: GraphLayoutMode = .tree
    // The ⌘F find bar: while open, nodes whose hover label contains findText
    // (case-insensitive) draw yellow and every other node gray.
    @State private var isFindPresented = false
    @State private var findText = ""
    @FocusState private var isFindFocused: Bool
    @State private var searchQuery = ""
    @State private var searchFocusRequest: UUID?
    @State private var fieldFilterFocusRequest: UUID?   // Tab/Shift+Tab swap the two boxes
    // The field filter: typename:fieldname entries; ignored unless enabled.
    // Deliberately not persisted — off and empty whenever the tab opens.
    @State private var fieldFilterText = ""
    @State private var isFieldFilterEnabled = false
    @State private var graphData: GraphData?
    @State private var errorMessage: String?
    @State private var isSearching = false
    @State private var layoutProgress: Double?   // 0…1 while the page lays a graph out; nil when idle

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                searchRow
                fieldFilterRow
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            graphArea
                .overlay(alignment: .topTrailing) {
                    if isFindPresented {
                        findBar
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            FindShortcutKeyHandler(shortcutSettings: shortcutSettings) {
                openFind()
            }
        }
        .task {
            // Focus the search box on every visit. Deferred like the
            // Collections page's: arriving from a tab whose own search field
            // was focused, that field's teardown lands after this task starts
            // and swallows an immediate focus set.
            try? await Task.sleep(for: .milliseconds(50))
            searchFocusRequest = UUID()
        }
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            SearchQueryTextField(
                "Search instances",
                text: $searchQuery,
                onSubmit: { runSearch() },
                focusRequest: searchFocusRequest,
                autocomplete: SearchAutocompleteProvider(appDatabase: appDatabase),
                onTab: { fieldFilterFocusRequest = UUID() },
                onBacktab: { fieldFilterFocusRequest = UUID() }
            )
            .searchCodeEditorStyle()
            Button("Search") {
                runSearch()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSearching)

            Picker("Layout:", selection: $layoutMode) {
                ForEach(GraphLayoutMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Tree: a spanning forest drawn top-down — tree arrows never cross. Force: the physics layout.")
            .onChange(of: layoutMode) { _, _ in
                // The page re-lays out the current graph; force mode reports progress.
                if let graphData, !graphData.nodes.isEmpty {
                    layoutProgress = 0
                }
            }

            if isSearching || layoutProgress != nil {
                ProgressView()
                    .controlSize(.small)
                Text(isSearching ? "Searching…" : "Laying out… \(Int((layoutProgress ?? 0) * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // Checkbox + the filter box + help. The checkbox re-runs the last search
    // at once; filter text applies on the next Search (Return in the box runs it).
    private var fieldFilterRow: some View {
        HStack(spacing: 10) {
            Toggle("Field filter", isOn: $isFieldFilterEnabled)
                .toggleStyle(.checkbox)
                .onChange(of: isFieldFilterEnabled) { _, _ in
                    if graphData != nil || errorMessage != nil {
                        runSearch()
                    }
                }
            SearchQueryTextField(
                "Field filter, e.g. Vocab:Definition",
                text: $fieldFilterText,
                onSubmit: { runSearch() },
                focusRequest: fieldFilterFocusRequest,
                autocomplete: SearchAutocompleteProvider(appDatabase: appDatabase),
                grammar: .fieldFilter,
                onTab: { searchFocusRequest = UUID() },
                onBacktab: { searchFocusRequest = UUID() }
            )
            .searchCodeEditorStyle()
            .opacity(isFieldFilterEnabled ? 1 : 0.6)
            HelpWindowButton(windowID: "graph-field-filter-help", tooltip: "How the field filter works")
        }
    }

    @ViewBuilder
    private var graphArea: some View {
        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let graphData {
            if graphData.nodes.isEmpty {
                Text("No instances match the search.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GraphWebView(
                    graphData: graphData,
                    layoutMode: layoutMode,
                    findQuery: isFindPresented ? findText : nil,
                    onLayoutProgress: { progress in
                        layoutProgress = progress < 1 ? progress : nil
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Text("Run a search to see the graph.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Chrome-style find bar: close button on the left, the field, the count.
    private var findBar: some View {
        HStack(spacing: 8) {
            Button {
                closeFind()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (Escape)")

            TextField("Find in graph", text: $findText)
                .textFieldStyle(.plain)
                .focused($isFindFocused)
                .frame(width: 180)
                .onExitCommand { closeFind() }

            Text(findMatchCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        }
        .padding(12)
        .onAppear { isFindFocused = true }
    }

    // Same test the page applies (case-insensitive substring of the hover label).
    private var findMatchCountText: String {
        guard !findText.isEmpty, let graphData else { return "" }
        let count = graphData.nodes.filter {
            fieldDisplayPlainText($0.label).range(of: findText, options: .caseInsensitive) != nil
        }.count
        return "\(count) \(count == 1 ? "match" : "matches")"
    }

    private func openFind() {
        isFindPresented = true
        // Already open: just put the caret back in the field.
        DispatchQueue.main.async { isFindFocused = true }
    }

    private func closeFind() {
        isFindPresented = false
        searchFocusRequest = UUID()
    }

    private func runSearch() {
        let query = searchQuery
        let fieldFilter = isFieldFilterEnabled ? fieldFilterText : nil
        isSearching = true
        Task {
            do {
                let data = try appDatabase.fetchGraphData(query: query, fieldFilter: fieldFilter)
                // The page reports progress only for data it hasn't laid out
                // yet, and only while mounted (a non-empty graph).
                layoutProgress = (!data.nodes.isEmpty && data != graphData) ? 0 : nil
                graphData = data
                errorMessage = nil
            } catch {
                graphData = nil
                layoutProgress = nil
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }
}

private struct GraphWebView: NSViewRepresentable {
    let graphData: GraphData
    let layoutMode: GraphLayoutMode
    /// The find bar's text while it is open; nil when closed (normal colours).
    let findQuery: String?
    /// Layout progress 0…1 from the page (1 = finished).
    let onLayoutProgress: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = makeLocalContentWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: Coordinator.progressMessageName)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.onLayoutProgress = onLayoutProgress
        // Stable baseURL (never nil) so this webview's WebContent process is
        // cacheable/reusable — see the queryHTMLBaseURL comment in QueryHTMLView.swift.
        webView.loadHTMLString(Self.graphHTML, baseURL: queryHTMLBaseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLayoutProgress = onLayoutProgress
        context.coordinator.update(graphData: graphData, layoutMode: layoutMode, findQuery: findQuery, on: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // The user content controller retains its handlers; drop ours.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.progressMessageName)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let progressMessageName = "layoutProgress"
        var onLayoutProgress: ((Double) -> Void)?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.progressMessageName,
                  let body = message.body as? [String: Any],
                  let step = body["step"] as? Double,
                  let steps = body["steps"] as? Double else { return }
            onLayoutProgress?(steps > 0 ? min(1, step / steps) : 1)
        }

        // Required with the custom-scheme baseURL: the initial loadHTMLString
        // navigation IS policy-checked, and WebKit's DEFAULT handling of an
        // unimplemented decidePolicyFor hands a scheme it can't display to
        // Launch Services (error dialog + blank view). The graph HTML is
        // self-contained, so nothing but the initial load is ever allowed.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
        }

        private var isLoaded = false
        private var lastSent: GraphData?
        private var lastSentMode: GraphLayoutMode?
        private var lastSentFindQuery: String?
        private var hasSentFindQuery = false
        private var pending: (data: GraphData, mode: GraphLayoutMode, find: String?)?

        func update(graphData: GraphData, layoutMode: GraphLayoutMode, findQuery: String?, on webView: WKWebView) {
            let findChanged = !hasSentFindQuery || findQuery != lastSentFindQuery
            guard graphData != lastSent || layoutMode != lastSentMode || findChanged else { return }
            if isLoaded {
                send(graphData, layoutMode: layoutMode, findQuery: findQuery, to: webView)
            } else {
                pending = (graphData, layoutMode, findQuery)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let pending {
                self.pending = nil
                send(pending.data, layoutMode: pending.mode, findQuery: pending.find, to: webView)
            }
        }

        private func send(_ data: GraphData, layoutMode: GraphLayoutMode, findQuery: String?, to webView: WKWebView) {
            if data != lastSent {
                sendData(data, layoutMode: layoutMode, to: webView)
            } else if layoutMode != lastSentMode {
                // Same data, new mode: re-lay out in place rather than resending it.
                lastSentMode = layoutMode
                webView.evaluateJavaScript("setLayoutMode('\(layoutMode.rawValue)')", completionHandler: nil)
            }
            if !hasSentFindQuery || findQuery != lastSentFindQuery {
                hasSentFindQuery = true
                lastSentFindQuery = findQuery
                let literal = findQuery
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                webView.evaluateJavaScript("setFindQuery(\(literal))", completionHandler: nil)
            }
        }

        private func sendData(_ data: GraphData, layoutMode: GraphLayoutMode, to webView: WKWebView) {
            lastSent = data
            lastSentMode = layoutMode
            // The display field partially rendered: `html` for the tooltip,
            // `label` the same as plain text for find matching.
            let nodesArray: [[String: Any]] = data.nodes.map { node in
                ["id": node.instanceID,
                 "label": fieldDisplayPlainText(node.label),
                 "html": fieldDisplayHTML(node.label),
                 "isSource": data.sourceNodeIDs.contains(node.instanceID)]
            }
            let edgesArray: [[String: Any]] = data.edges.map { edge in
                ["from": edge.fromInstanceID, "to": edge.toInstanceID]
            }
            guard let nodesData = try? JSONSerialization.data(withJSONObject: nodesArray),
                  let edgesData = try? JSONSerialization.data(withJSONObject: edgesArray),
                  let nodesStr = String(data: nodesData, encoding: .utf8),
                  let edgesStr = String(data: edgesData, encoding: .utf8) else { return }
            webView.evaluateJavaScript("setGraphData(\(nodesStr), \(edgesStr), '\(layoutMode.rawValue)')", completionHandler: nil)
        }
    }

    // Force-directed graph with pan/zoom and hover tooltips. The layout is a
    // Barnes–Hut force simulation run in time-sliced frames (see the script's
    // "layout" block, which a scratch jsc harness can extract and exercise).
    private static let graphHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        html, body { width: 100%; height: 100%; overflow: hidden; background: transparent; }
        #c { display: block; }
        #tip {
            position: fixed;
            background: rgba(20,20,20,0.88);
            color: #fff;
            padding: 4px 9px;
            border-radius: 6px;
            font: 12px -apple-system, BlinkMacSystemFont, sans-serif;
            pointer-events: none;
            display: none;
            z-index: 100;
            max-width: 300px;
            word-wrap: break-word;
        }
        </style>
        </head>
        <body>
        <canvas id="c"></canvas>
        <div id="tip"></div>
        <script>
        var canvas = document.getElementById('c');
        var ctx = canvas.getContext('2d');
        var tip = document.getElementById('tip');
        var DPR = 1;

        // Screen sizes (device pixels), constant across zoom: when drawing in
        // the zoomed world space they are divided by the zoom factor, so nodes
        // shrink in world terms as the user zooms in and grow as he zooms out.
        var R = 14;       // node radius
        var ARROW = 14;   // arrowhead length (a node radius)

        // Node metadata ({id, label, isSource, kind}) by index; positions,
        // velocities and forces in typed arrays so the hot loops never touch
        // objects. Edges are index pairs. The connected nodes are stored first
        // (indices 0..NC-1) and are the only ones the force layout moves; the
        // isolated (red) ones follow and are placed as their own cluster.
        var nodes = [], N = 0, NC = 0;
        var X, Y, VX, VY, FX, FY;
        var EF, ET, E = 0;
        var tx = 0, ty = 0, sc = 1;
        var panning = false, px0 = 0, py0 = 0, ptx = 0, pty = 0;
        var hovered = -1;

        function resize() {
            DPR = window.devicePixelRatio || 1;
            canvas.width  = window.innerWidth  * DPR;
            canvas.height = window.innerHeight * DPR;
            canvas.style.width  = window.innerWidth  + 'px';
            canvas.style.height = window.innerHeight + 'px';
            draw();
        }
        window.addEventListener('resize', resize);

        function setGraphData(ns, es, mode) {
            if (mode) layoutMode = mode;
            tip.style.display = 'none';
            hovered = -1;
            N = ns.length;
            // Resolve edges and colour kinds in the given order first: 2 = has
            // an incoming arrow (blue), 1 = outgoing arrows only (green),
            // 0 = no arrows at all (red).
            var indexByID = new Map();
            for (var i = 0; i < N; i++) indexByID.set(ns[i].id, i);
            var from = [], to = [];
            for (var k = 0; k < es.length; k++) {
                var a = indexByID.get(es[k].from), b = indexByID.get(es[k].to);
                if (a === undefined || b === undefined) continue;
                from.push(a); to.push(b);
            }
            var linked = new Uint8Array(N);
            for (var m = 0; m < from.length; m++) { linked[from[m]] = 1; linked[to[m]] = 1; }
            var kinds = ns.map(function(n, j) { return n.isSource ? (linked[j] ? 1 : 0) : 2; });
            // Connected nodes first, isolated ones after (see NC above).
            var order = [];
            for (var c = 0; c < N; c++) if (kinds[c] !== 0) order.push(c);
            NC = order.length;
            for (var d = 0; d < N; d++) if (kinds[d] === 0) order.push(d);
            var newIndex = new Int32Array(N);
            nodes = order.map(function(old, idx) {
                newIndex[old] = idx;
                return { id: ns[old].id, label: ns[old].label, html: ns[old].html, isSource: ns[old].isSource, kind: kinds[old] };
            });
            E = from.length;
            EF = new Int32Array(E); ET = new Int32Array(E);
            for (var e = 0; e < E; e++) { EF[e] = newIndex[from[e]]; ET[e] = newIndex[to[e]]; }
            X = new Float64Array(N); Y = new Float64Array(N);
            VX = new Float64Array(N); VY = new Float64Array(N);
            FX = new Float64Array(N); FY = new Float64Array(N);
            var spread = Math.max(200, Math.sqrt(NC) * 60);
            for (var p = 0; p < NC; p++) {
                X[p] = (Math.random() - 0.5) * spread;
                Y[p] = (Math.random() - 0.5) * spread;
            }
            applyFind();
            tx = 0; ty = 0; sc = 1;
            startLayout();
        }

        // The host's find bar: null while closed (normal colours); while open,
        // nodes whose label contains the text (case-insensitive) draw yellow
        // and all others gray — nothing typed yet means all gray. Recolours
        // without any relayout, and the query survives new data.
        var findQuery = null, findMatch = null;

        function setFindQuery(q) {
            findQuery = (typeof q === 'string') ? q : null;
            applyFind();
            draw();
        }

        function applyFind() {
            if (findQuery === null || N === 0) { findMatch = null; return; }
            findMatch = new Uint8Array(N);
            var q = findQuery.toLowerCase();
            if (q.length === 0) return;
            for (var i = 0; i < N; i++) {
                if ((nodes[i].label || '').toLowerCase().indexOf(q) >= 0) findMatch[i] = 1;
            }
        }

        // 'tree' (a spanning forest drawn top-down — see treeLayout) or
        // 'force' (the physics simulation). Switching re-lays out the data in
        // place; force mode then starts from the current positions.
        var layoutMode = 'tree';

        function startLayout() {
            if (layoutMode === 'force') {
                startSimulation();
                return;
            }
            simGeneration++;   // cancels a running force layout's frames
            if (rafID) { cancelAnimationFrame(rafID); rafID = 0; }
            treeLayout();
            placeIsolated();
            draw();
            simStep = 1; simSteps = 1;
            postProgress();
        }

        function setLayoutMode(mode) {
            if (mode !== 'tree' && mode !== 'force') return;
            layoutMode = mode;
            if (N === 0) return;
            tx = 0; ty = 0; sc = 1;
            startLayout();
        }

        // The isolated nodes sit in their own cluster: a compact grid to the
        // right of the connected nodes' bounding box (centred on the origin
        // when every node is isolated), re-placed after every slice so it
        // follows the animating layout.
        var ISO_SPACING = 2 * R + 8, ISO_GAP = 120;
        function placeIsolated() {
            var M = N - NC;
            if (M === 0) return;
            var cols = Math.ceil(Math.sqrt(M)), rows = Math.ceil(M / cols);
            var left, centerY;
            if (NC > 0) {
                var maxX = -Infinity, minY = Infinity, maxY = -Infinity;
                for (var i = 0; i < NC; i++) {
                    if (X[i] > maxX) maxX = X[i];
                    if (Y[i] < minY) minY = Y[i];
                    if (Y[i] > maxY) maxY = Y[i];
                }
                left = maxX + ISO_GAP;
                centerY = (minY + maxY) / 2;
            } else {
                left = -(cols - 1) * ISO_SPACING / 2;
                centerY = 0;
            }
            var top = centerY - (rows - 1) * ISO_SPACING / 2;
            for (var k = 0; k < M; k++) {
                X[NC + k] = left + (k % cols) * ISO_SPACING;
                Y[NC + k] = top + Math.floor(k / cols) * ISO_SPACING;
            }
        }

        // ---- layout begin (DOM-free: a scratch jsc harness extracts this block) ----
        // The force model, over the first NC nodes (the connected ones):
        // pairwise repulsion 2500/(d²+1), springs along edges toward 100 units
        // (k 0.12), gravity toward the centroid (0.04), 0.75 damping,
        // per-step force scale alpha. Repulsion goes through a
        // Barnes–Hut quadtree — a cell far enough away (width/distance < θ)
        // acts as one body at its centre of mass — so a step is O(N log N)
        // instead of O(N²). The tree lives in flat typed arrays rebuilt each
        // step: cell k has children QC[4k..4k+3] (-1 = none), mass QM[k],
        // centre of mass (QMX, QMY) (sums while building, averaged after),
        // leaf point QP[k] (-1 = internal), half-width QS[k], centre (QCX, QCY).
        var MAX_DEPTH = 20, THETA2 = 0.85 * 0.85;
        var QC, QM, QMX, QMY, QP, QS, QCX, QCY, qCount = 0, qCap = 0;
        var stack = new Int32Array(4 * (MAX_DEPTH + 2) * 4);

        function ensureTreeCapacity(cap) {
            if (cap <= qCap) return;
            qCap = cap;
            QC = new Int32Array(4 * cap);
            QM = new Float64Array(cap); QMX = new Float64Array(cap); QMY = new Float64Array(cap);
            QP = new Int32Array(cap); QS = new Float64Array(cap);
            QCX = new Float64Array(cap); QCY = new Float64Array(cap);
        }

        function newCell(cx, cy, half) {
            var k = qCount++, b = 4 * k;
            QC[b] = -1; QC[b+1] = -1; QC[b+2] = -1; QC[b+3] = -1;
            QM[k] = 0; QMX[k] = 0; QMY[k] = 0; QP[k] = -1;
            QS[k] = half; QCX[k] = cx; QCY[k] = cy;
            return k;
        }

        function buildTree() {
            ensureTreeCapacity(8 * NC + 64);
            qCount = 0;
            var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
            for (var i = 0; i < NC; i++) {
                if (X[i] < minX) minX = X[i];
                if (X[i] > maxX) maxX = X[i];
                if (Y[i] < minY) minY = Y[i];
                if (Y[i] > maxY) maxY = Y[i];
            }
            var half = Math.max(maxX - minX, maxY - minY) / 2 + 1;
            var root = newCell((minX + maxX) / 2, (minY + maxY) / 2, half);
            for (var p = 0; p < NC; p++) insertPoint(root, p);
            for (var k = 0; k < qCount; k++) {
                if (QM[k] > 0) { QMX[k] /= QM[k]; QMY[k] /= QM[k]; }
            }
            return root;
        }

        function insertPoint(root, p) {
            var x = X[p], y = Y[p], k = root, depth = 0;
            while (true) {
                QM[k] += 1; QMX[k] += x; QMY[k] += y;
                if (QM[k] === 1) { QP[k] = p; return; }   // was empty: p lives here
                if (QP[k] !== -1) {
                    // A leaf already holding a point: move that point down a
                    // level, then keep descending with p. At max depth (or
                    // out of cells) the points stay aggregated in this cell.
                    if (depth >= MAX_DEPTH || qCount + 2 > qCap) return;
                    var q = QP[k]; QP[k] = -1;
                    var cq = (X[q] >= QCX[k] ? 1 : 0) | (Y[q] >= QCY[k] ? 2 : 0);
                    var hq = QS[k] / 2;
                    var c = newCell(QCX[k] + ((cq & 1) ? hq : -hq), QCY[k] + ((cq & 2) ? hq : -hq), hq);
                    QC[4*k + cq] = c;
                    QP[c] = q; QM[c] = QM[k] - 1; QMX[c] = QMX[k] - x; QMY[c] = QMY[k] - y;
                }
                var ci = (x >= QCX[k] ? 1 : 0) | (y >= QCY[k] ? 2 : 0);
                var child = QC[4*k + ci];
                if (child === -1) {
                    if (qCount + 1 > qCap) return;   // out of cells: p stays aggregated in k
                    var h = QS[k] / 2;
                    child = newCell(QCX[k] + ((ci & 1) ? h : -h), QCY[k] + ((ci & 2) ? h : -h), h);
                    QC[4*k + ci] = child;
                    QP[child] = p; QM[child] = 1; QMX[child] = x; QMY[child] = y;
                    return;
                }
                k = child; depth++;
            }
        }

        function repulsion(root) {
            for (var i = 0; i < NC; i++) {
                var x = X[i], y = Y[i], fx = 0, fy = 0, sp = 0;
                stack[sp++] = root;
                while (sp > 0) {
                    var k = stack[--sp];
                    var m = QM[k];
                    if (m === 0 || (QP[k] === i && m === 1)) continue;
                    var dx = QMX[k] - x, dy = QMY[k] - y;
                    var d2 = dx*dx + dy*dy;
                    var w = QS[k] * 2;
                    if (QP[k] !== -1 || w*w < THETA2 * d2) {
                        var f = 2500 * m / (d2 + 1), d = Math.sqrt(d2 + 1);
                        fx -= f*dx/d; fy -= f*dy/d;
                    } else {
                        var b = 4*k;
                        if (QC[b]   !== -1) stack[sp++] = QC[b];
                        if (QC[b+1] !== -1) stack[sp++] = QC[b+1];
                        if (QC[b+2] !== -1) stack[sp++] = QC[b+2];
                        if (QC[b+3] !== -1) stack[sp++] = QC[b+3];
                    }
                }
                FX[i] += fx; FY[i] += fy;
            }
        }

        // One step at force scale `alpha`; returns the largest node movement.
        function tick(alpha) {
            if (NC === 0) return 0;
            var i;
            for (i = 0; i < NC; i++) { FX[i] = 0; FY[i] = 0; }
            if (NC > 1) repulsion(buildTree());

            // Spring attraction along edges
            for (i = 0; i < E; i++) {
                var a = EF[i], b = ET[i];
                var dx = X[b] - X[a], dy = Y[b] - Y[a];
                var d = Math.sqrt(dx*dx + dy*dy) + 0.001;
                var f = (d - 100) * 0.12;
                FX[a] += f*dx/d; FY[a] += f*dy/d;
                FX[b] -= f*dx/d; FY[b] -= f*dy/d;
            }

            // Gravity toward centroid, then integrate
            var cx = 0, cy = 0;
            for (i = 0; i < NC; i++) { cx += X[i]; cy += Y[i]; }
            cx /= NC; cy /= NC;
            var maxMove = 0;
            for (i = 0; i < NC; i++) {
                FX[i] -= (X[i] - cx) * 0.04;
                FY[i] -= (Y[i] - cy) * 0.04;
                VX[i] = (VX[i] + FX[i] * alpha) * 0.75;
                VY[i] = (VY[i] + FY[i] * alpha) * 0.75;
                X[i] += VX[i]; Y[i] += VY[i];
                var mv = Math.abs(VX[i]) + Math.abs(VY[i]);
                if (mv > maxMove) maxMove = mv;
            }
            return maxMove;
        }

        // ---- Tree layout. A spanning forest of the connected nodes (BFS
        // from each component's highest-degree node, children by degree, so
        // hubs sit on top with their fans beneath), drawn top-down: leaves
        // LEAF_SPACING apart in DFS order, every inner node centred over its
        // children, depth × LEVEL_SPACING down. Tree edges therefore never
        // cross, and two nodes sharing a depth are at least a leaf slot apart
        // (their leaf-index ranges are disjoint). Components are packed into
        // rows, widest first, and the whole thing is centred on the origin.
        // Non-tree edges are just drawn where their ends fall. O(N + E).
        var LEAF_SPACING = 40, LEVEL_SPACING = 80, COMPONENT_GAP = 60;

        function treeLayout() {
            if (NC === 0) return;
            // Undirected adjacency (CSR) over the connected nodes.
            var deg = new Int32Array(NC), i, e;
            for (e = 0; e < E; e++) { deg[EF[e]]++; deg[ET[e]]++; }
            var adjStart = new Int32Array(NC + 1);
            for (i = 0; i < NC; i++) adjStart[i + 1] = adjStart[i] + deg[i];
            var fill = new Int32Array(NC), adj = new Int32Array(adjStart[NC]);
            for (e = 0; e < E; e++) {
                var a = EF[e], b = ET[e];
                adj[adjStart[a] + fill[a]++] = b;
                adj[adjStart[b] + fill[b]++] = a;
            }
            function byDegree(p, q) { return deg[q] - deg[p] || p - q; }

            // Spanning forest: roots in degree order, BFS, children kept as
            // sibling lists in discovery order (neighbours by degree).
            var order = new Int32Array(NC);
            for (i = 0; i < NC; i++) order[i] = i;
            order.sort(byDegree);
            var depth = new Int32Array(NC), comp = new Int32Array(NC), visited = new Uint8Array(NC);
            var firstChild = new Int32Array(NC).fill(-1), lastChild = new Int32Array(NC).fill(-1);
            var nextSibling = new Int32Array(NC).fill(-1);
            var queue = new Int32Array(NC), roots = [];
            for (var r = 0; r < NC; r++) {
                var root = order[r];
                if (visited[root]) continue;
                visited[root] = 1; depth[root] = 0; comp[root] = roots.length;
                roots.push(root);
                var head = 0, tail = 0;
                queue[tail++] = root;
                while (head < tail) {
                    var u = queue[head++];
                    var nb = adj.subarray(adjStart[u], adjStart[u + 1]);
                    nb.sort(byDegree);
                    for (var t = 0; t < nb.length; t++) {
                        var v = nb[t];
                        if (visited[v]) continue;
                        visited[v] = 1; depth[v] = depth[u] + 1; comp[v] = comp[u];
                        if (firstChild[u] === -1) firstChild[u] = v; else nextSibling[lastChild[u]] = v;
                        lastChild[u] = v;
                        queue[tail++] = v;
                    }
                }
            }

            // Per component: pre-order DFS assigns leaf x in visit order; the
            // reverse pass centres inner nodes (children already placed).
            var compWidth = new Float64Array(roots.length), compHeight = new Float64Array(roots.length);
            var stack = new Int32Array(NC), pre = new Int32Array(NC);
            for (var c = 0; c < roots.length; c++) {
                var sp = 0, n = 0, leafCount = 0, maxDepth = 0;
                stack[sp++] = roots[c];
                while (sp > 0) {
                    var w = stack[--sp];
                    pre[n++] = w;
                    if (depth[w] > maxDepth) maxDepth = depth[w];
                    if (firstChild[w] === -1) { X[w] = leafCount * LEAF_SPACING; leafCount++; }
                    for (var ch = firstChild[w]; ch !== -1; ch = nextSibling[ch]) stack[sp++] = ch;
                }
                for (var m = n - 1; m >= 0; m--) {
                    var z = pre[m];
                    if (firstChild[z] !== -1) X[z] = (X[firstChild[z]] + X[lastChild[z]]) / 2;
                    Y[z] = depth[z] * LEVEL_SPACING;
                }
                compWidth[c] = (leafCount - 1) * LEAF_SPACING;
                compHeight[c] = maxDepth * LEVEL_SPACING;
            }

            // Pack components into rows, widest first, about square overall.
            var byWidth = new Int32Array(roots.length);
            for (i = 0; i < roots.length; i++) byWidth[i] = i;
            byWidth.sort(function(p, q) { return compWidth[q] - compWidth[p] || p - q; });
            var totalArea = 0, widest = 0;
            for (i = 0; i < roots.length; i++) {
                totalArea += (compWidth[i] + COMPONENT_GAP) * (compHeight[i] + COMPONENT_GAP);
                if (compWidth[i] > widest) widest = compWidth[i];
            }
            var rowWidth = Math.max(widest, Math.sqrt(totalArea) * 1.2);
            var offsetX = new Float64Array(roots.length), offsetY = new Float64Array(roots.length);
            var cursorX = 0, cursorY = 0, rowHeight = 0;
            for (i = 0; i < roots.length; i++) {
                var k = byWidth[i];
                if (cursorX > 0 && cursorX + compWidth[k] > rowWidth) {
                    cursorY += rowHeight + COMPONENT_GAP;
                    cursorX = 0; rowHeight = 0;
                }
                offsetX[k] = cursorX; offsetY[k] = cursorY;
                cursorX += compWidth[k] + COMPONENT_GAP;
                if (compHeight[k] > rowHeight) rowHeight = compHeight[k];
            }
            var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
            for (i = 0; i < NC; i++) {
                X[i] += offsetX[comp[i]]; Y[i] += offsetY[comp[i]];
                if (X[i] < minX) minX = X[i];
                if (X[i] > maxX) maxX = X[i];
                if (Y[i] < minY) minY = Y[i];
                if (Y[i] > maxY) maxY = Y[i];
            }
            var cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
            for (i = 0; i < NC; i++) { X[i] -= cx; Y[i] -= cy; VX[i] = 0; VY[i] = 0; }
        }
        // ---- layout end ----

        // Steps run in time-sliced frames that draw as they go: a 30 ms
        // synchronous slice first (a small graph appears already settled),
        // then 12 ms per animation frame until the step cap. Pan/zoom/hover
        // work meanwhile. There is deliberately no "nothing moves any more"
        // early stop: at the alpha floor the layout keeps drifting slowly, and
        // a scratch run showed nodes travelling 40–240 more units after every
        // such cutoff — stopping early freezes a visibly different picture.
        var simGeneration = 0, simStep = 0, simSteps = 0, rafID = 0;

        function startSimulation() {
            simGeneration++;
            var generation = simGeneration;
            if (rafID) { cancelAnimationFrame(rafID); rafID = 0; }
            simStep = 0;
            simSteps = Math.min(700, 300 + NC * 2);
            runSlice(30);
            placeIsolated();
            draw();
            postProgress();
            if (simStep >= simSteps) return;
            rafID = requestAnimationFrame(function frame() {
                if (generation !== simGeneration) return;
                runSlice(12);
                placeIsolated();
                draw();
                postProgress();
                rafID = simStep < simSteps ? requestAnimationFrame(frame) : 0;
            });
        }

        // Tells the host how far the layout is (step/steps; equal = done) so
        // it can show a loading indicator.
        function postProgress() {
            var handlers = window.webkit && window.webkit.messageHandlers;
            if (handlers && handlers.layoutProgress) {
                handlers.layoutProgress.postMessage({ step: simStep, steps: simSteps });
            }
        }

        function runSlice(budgetMs) {
            var start = performance.now();
            while (simStep < simSteps) {
                var alpha = Math.max(0.01, 0.5 * Math.pow(0.985, simStep));
                tick(alpha);
                simStep++;
                if (performance.now() - start > budgetMs) break;
            }
        }

        function W() { return canvas.width; }
        function H() { return canvas.height; }

        function hitNode(csx, csy) {
            var wx = (csx * DPR - W()/2 - tx) / sc;
            var wy = (csy * DPR - H()/2 - ty) / sc;
            var r = R / sc;
            for (var i = 0; i < N; i++) {
                var dx = X[i] - wx, dy = Y[i] - wy;
                if (dx*dx + dy*dy <= r*r) return i;
            }
            return -1;
        }

        // Batched: every edge line in one stroke, every arrowhead in one
        // fill, the nodes in one fill per colour.
        function draw() {
            ctx.clearRect(0, 0, W(), H());
            if (N === 0) return;
            ctx.save();
            ctx.translate(W()/2 + tx, H()/2 + ty);
            ctx.scale(sc, sc);

            // World-space sizes for this zoom (constant on screen).
            var r = R / sc, arrow = ARROW / sc, gap = 2 / sc;
            var i, a, b, dx, dy, dist, nx, ny, ex, ey, ang;
            var aa = 0.42;
            ctx.strokeStyle = 'rgba(120,120,135,0.55)';
            ctx.fillStyle = 'rgba(120,120,135,0.55)';
            ctx.lineWidth = 1.3 / sc;
            ctx.beginPath();
            for (i = 0; i < E; i++) {
                a = EF[i]; b = ET[i];
                dx = X[b] - X[a]; dy = Y[b] - Y[a];
                dist = Math.sqrt(dx*dx + dy*dy);
                if (dist < r*2 + gap) continue;
                nx = dx/dist; ny = dy/dist;
                ctx.moveTo(X[a] + nx*r, Y[a] + ny*r);
                ctx.lineTo(X[b] - nx*r, Y[b] - ny*r);
            }
            ctx.stroke();
            ctx.beginPath();
            for (i = 0; i < E; i++) {
                a = EF[i]; b = ET[i];
                dx = X[b] - X[a]; dy = Y[b] - Y[a];
                dist = Math.sqrt(dx*dx + dy*dy);
                if (dist < r*2 + gap) continue;
                nx = dx/dist; ny = dy/dist;
                ex = X[b] - nx*r; ey = Y[b] - ny*r;
                ang = Math.atan2(dy, dx);
                ctx.moveTo(ex, ey);
                ctx.lineTo(ex - arrow*Math.cos(ang - aa), ey - arrow*Math.sin(ang - aa));
                ctx.lineTo(ex - arrow*Math.cos(ang + aa), ey - arrow*Math.sin(ang + aa));
                ctx.closePath();
            }
            ctx.fill();

            if (findMatch) {
                drawFindNodes(0, '#8E8E93', r);
                drawFindNodes(1, '#FFD60A', r);
            } else {
                drawNodes(0, '#FF453A', r);
                drawNodes(1, '#30D158', r);
                drawNodes(2, '#0A84FF', r);
            }

            if (hovered >= 0) {
                ctx.beginPath();
                ctx.arc(X[hovered], Y[hovered], r, 0, Math.PI*2);
                ctx.lineWidth = 2.5 / sc;
                ctx.strokeStyle = 'rgba(255,255,255,0.9)';
                ctx.stroke();
            }
            ctx.restore();
        }

        function drawNodes(kind, color, r) {
            ctx.fillStyle = color;
            ctx.beginPath();
            for (var i = 0; i < N; i++) {
                if (nodes[i].kind !== kind) continue;
                ctx.moveTo(X[i] + r, Y[i]);
                ctx.arc(X[i], Y[i], r, 0, Math.PI*2);
            }
            ctx.fill();
        }

        function drawFindNodes(matching, color, r) {
            ctx.fillStyle = color;
            ctx.beginPath();
            for (var i = 0; i < N; i++) {
                if (findMatch[i] !== matching) continue;
                ctx.moveTo(X[i] + r, Y[i]);
                ctx.arc(X[i], Y[i], r, 0, Math.PI*2);
            }
            ctx.fill();
        }

        canvas.addEventListener('mousedown', function(e) {
            if (hitNode(e.clientX, e.clientY) < 0) {
                panning = true;
                px0 = e.clientX * DPR; py0 = e.clientY * DPR;
                ptx = tx; pty = ty;
                canvas.style.cursor = 'grabbing';
            }
        });

        window.addEventListener('mousemove', function(e) {
            if (panning) {
                tx = ptx + (e.clientX * DPR - px0);
                ty = pty + (e.clientY * DPR - py0);
                draw();
                return;
            }
            var n = hitNode(e.clientX, e.clientY);
            if (n !== hovered) { hovered = n; draw(); }
            if (n >= 0) {
                tip.style.display = 'block';
                // Safe by construction: escaped text with only <b>/<i> (fieldDisplayHTML).
                tip.innerHTML = nodes[n].html || '(no label)';
                tip.style.left = (e.clientX + 14) + 'px';
                tip.style.top  = (e.clientY -  8) + 'px';
                canvas.style.cursor = 'pointer';
            } else {
                tip.style.display = 'none';
                if (!panning) canvas.style.cursor = 'default';
            }
        });

        window.addEventListener('mouseup', function() {
            panning = false;
            canvas.style.cursor = 'default';
        });

        canvas.addEventListener('mouseleave', function() {
            hovered = -1;
            tip.style.display = 'none';
            draw();
        });

        canvas.addEventListener('wheel', function(e) {
            e.preventDefault();
            var zf = e.deltaY < 0 ? 1.08 : 1/1.08;
            var mx = e.clientX * DPR - W()/2;
            var my = e.clientY * DPR - H()/2;
            tx = (tx - mx) * zf + mx;
            ty = (ty - my) * zf + my;
            sc = Math.max(0.03, Math.min(20, sc * zf));
            draw();
        }, { passive: false });

        resize();
        </script>
        </body>
        </html>
        """
}
