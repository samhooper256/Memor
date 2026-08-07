//
//  GraphPageView.swift
//  Memor
//
//  Graph page: search instances and render a force-directed node/edge graph.
//

import AppKit
import SwiftUI
import WebKit

struct GraphPageView: View {
    let appDatabase: AppDatabase

    @State private var searchQuery = ""
    @State private var graphData: GraphData?
    @State private var errorMessage: String?
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SearchQueryTextField("Search instances", text: $searchQuery, onSubmit: { runSearch() })
                    .searchCodeEditorStyle()
                Button("Search") {
                    runSearch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSearching)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

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
                    GraphWebView(graphData: graphData)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("Run a search to see the graph.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func runSearch() {
        let query = searchQuery
        isSearching = true
        Task {
            do {
                let data = try appDatabase.fetchGraphData(query: query)
                graphData = data
                errorMessage = nil
            } catch {
                graphData = nil
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }
}

private struct GraphWebView: NSViewRepresentable {
    let graphData: GraphData

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = makeLocalContentWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        // Stable baseURL (never nil) so this webview's WebContent process is
        // cacheable/reusable — see the queryHTMLBaseURL comment in QueryHTMLView.swift.
        webView.loadHTMLString(Self.graphHTML, baseURL: queryHTMLBaseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(graphData: graphData, on: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var isLoaded = false
        private var lastSent: GraphData?
        private var pending: GraphData?

        func update(graphData: GraphData, on webView: WKWebView) {
            guard graphData != lastSent else { return }
            if isLoaded {
                send(graphData, to: webView)
            } else {
                pending = graphData
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let data = pending {
                pending = nil
                send(data, to: webView)
            }
        }

        private func send(_ data: GraphData, to webView: WKWebView) {
            lastSent = data
            let nodesArray: [[String: Any]] = data.nodes.map { node in
                ["id": node.instanceID, "label": node.label,
                 "isSource": data.sourceNodeIDs.contains(node.instanceID)]
            }
            let edgesArray: [[String: Any]] = data.edges.map { edge in
                ["from": edge.fromInstanceID, "to": edge.toInstanceID]
            }
            guard let nodesData = try? JSONSerialization.data(withJSONObject: nodesArray),
                  let edgesData = try? JSONSerialization.data(withJSONObject: edgesArray),
                  let nodesStr = String(data: nodesData, encoding: .utf8),
                  let edgesStr = String(data: edgesData, encoding: .utf8) else { return }
            webView.evaluateJavaScript("setGraphData(\(nodesStr), \(edgesStr))", completionHandler: nil)
        }
    }

    // Force-directed graph with pan/zoom and hover tooltips
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

        var R = 14;       // node radius (world units)
        var ARROW = 9;    // arrowhead size

        var nodes = [], edges = [], nodeMap = new Map();
        var tx = 0, ty = 0, sc = 1;
        var panning = false, px0 = 0, py0 = 0, ptx = 0, pty = 0;
        var hovered = null;

        function resize() {
            DPR = window.devicePixelRatio || 1;
            canvas.width  = window.innerWidth  * DPR;
            canvas.height = window.innerHeight * DPR;
            canvas.style.width  = window.innerWidth  + 'px';
            canvas.style.height = window.innerHeight + 'px';
            draw();
        }
        window.addEventListener('resize', resize);

        function setGraphData(ns, es) {
            tip.style.display = 'none';
            hovered = null;
            var spread = Math.max(200, Math.sqrt(ns.length) * 60);
            nodes = ns.map(function(n) {
                return { id: n.id, label: n.label, isSource: n.isSource,
                         x: (Math.random() - 0.5) * spread,
                         y: (Math.random() - 0.5) * spread,
                         vx: 0, vy: 0 };
            });
            edges = es;
            nodeMap = new Map(nodes.map(function(n) { return [n.id, n]; }));
            tx = 0; ty = 0; sc = 1;
            simulate();
            draw();
        }

        function simulate() {
            var N = nodes.length;
            if (N === 0) return;
            var steps = Math.min(700, 300 + N * 2);
            for (var i = 0; i < steps; i++) {
                tick(Math.max(0.01, 0.5 * Math.pow(0.985, i)));
            }
        }

        function tick(alpha) {
            var N = nodes.length;
            var i, j, n, e, dx, dy, d, f, a, b;

            for (i = 0; i < N; i++) { nodes[i].fx = 0; nodes[i].fy = 0; }

            // Repulsion
            for (i = 0; i < N; i++) {
                for (j = i + 1; j < N; j++) {
                    dx = nodes[j].x - nodes[i].x;
                    dy = nodes[j].y - nodes[i].y;
                    var d2 = dx*dx + dy*dy + 1;
                    f = 2500 / d2;
                    d = Math.sqrt(d2);
                    nodes[i].fx -= f*dx/d;  nodes[i].fy -= f*dy/d;
                    nodes[j].fx += f*dx/d;  nodes[j].fy += f*dy/d;
                }
            }

            // Spring attraction along edges
            for (i = 0; i < edges.length; i++) {
                e = edges[i];
                a = nodeMap.get(e.from); b = nodeMap.get(e.to);
                if (!a || !b) continue;
                dx = b.x - a.x; dy = b.y - a.y;
                d = Math.sqrt(dx*dx + dy*dy) + 0.001;
                f = (d - 100) * 0.12;
                a.fx += f*dx/d;  a.fy += f*dy/d;
                b.fx -= f*dx/d;  b.fy -= f*dy/d;
            }

            // Gravity toward centroid
            var cx = 0, cy = 0;
            for (i = 0; i < N; i++) { cx += nodes[i].x; cy += nodes[i].y; }
            cx /= N; cy /= N;
            for (i = 0; i < N; i++) {
                nodes[i].fx -= (nodes[i].x - cx) * 0.04;
                nodes[i].fy -= (nodes[i].y - cy) * 0.04;
            }

            // Integrate
            for (i = 0; i < N; i++) {
                n = nodes[i];
                n.vx = (n.vx + n.fx * alpha) * 0.75;
                n.vy = (n.vy + n.fy * alpha) * 0.75;
                n.x += n.vx;
                n.y += n.vy;
            }
        }

        function W() { return canvas.width; }
        function H() { return canvas.height; }

        function hitNode(csx, csy) {
            var wx = (csx * DPR - W()/2 - tx) / sc;
            var wy = (csy * DPR - H()/2 - ty) / sc;
            for (var i = 0; i < nodes.length; i++) {
                var n = nodes[i];
                var dx = n.x - wx, dy = n.y - wy;
                if (dx*dx + dy*dy <= R*R) return n;
            }
            return null;
        }

        function draw() {
            ctx.clearRect(0, 0, W(), H());
            if (nodes.length === 0) return;
            ctx.save();
            ctx.translate(W()/2 + tx, H()/2 + ty);
            ctx.scale(sc, sc);
            for (var i = 0; i < edges.length; i++) {
                var f = nodeMap.get(edges[i].from), t = nodeMap.get(edges[i].to);
                if (f && t) drawEdge(f, t);
            }
            for (var j = 0; j < nodes.length; j++) {
                drawNode(nodes[j], nodes[j] === hovered);
            }
            ctx.restore();
        }

        function drawEdge(f, t) {
            var dx = t.x - f.x, dy = t.y - f.y;
            var dist = Math.sqrt(dx*dx + dy*dy);
            if (dist < R*2 + 2) return;
            var nx = dx/dist, ny = dy/dist;
            var sx = f.x + nx*R, sy = f.y + ny*R;
            var ex = t.x - nx*R, ey = t.y - ny*R;

            ctx.beginPath();
            ctx.moveTo(sx, sy);
            ctx.lineTo(ex, ey);
            ctx.strokeStyle = 'rgba(120,120,135,0.55)';
            ctx.lineWidth = 1.3;
            ctx.stroke();

            var ang = Math.atan2(dy, dx);
            var aa = 0.42;
            ctx.beginPath();
            ctx.moveTo(ex, ey);
            ctx.lineTo(ex - ARROW*Math.cos(ang - aa), ey - ARROW*Math.sin(ang - aa));
            ctx.lineTo(ex - ARROW*Math.cos(ang + aa), ey - ARROW*Math.sin(ang + aa));
            ctx.closePath();
            ctx.fillStyle = 'rgba(120,120,135,0.55)';
            ctx.fill();
        }

        function drawNode(n, hl) {
            ctx.beginPath();
            ctx.arc(n.x, n.y, R, 0, Math.PI*2);
            ctx.fillStyle = n.isSource ? '#30D158' : '#0A84FF';
            ctx.fill();
            if (hl) {
                ctx.lineWidth = 2.5;
                ctx.strokeStyle = 'rgba(255,255,255,0.9)';
                ctx.stroke();
            }
        }

        canvas.addEventListener('mousedown', function(e) {
            if (!hitNode(e.clientX, e.clientY)) {
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
            if (n) {
                tip.style.display = 'block';
                tip.textContent = n.label || '(no label)';
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
            hovered = null;
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
