//
//  HTMLPreviewView.swift
//  Memor
//
//  WebView-based HTML preview, the card-style canvas wrapper, and the preview HTML validator.
//

import AppKit
import SwiftUI
import WebKit

struct PreviewCanvasSection: View {
    let html: String
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preview")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            Group {
                if let errorMessage {
                    ScrollView {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(16)
                            .textSelection(.enabled)
                    }
                } else {
                    HTMLPreviewView(html: html)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 500)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }
}

struct HTMLPreviewView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> PreviewWebContainerView {
        let containerView = PreviewWebContainerView()
        return containerView
    }

    func updateNSView(_ containerView: PreviewWebContainerView, context: Context) {
        containerView.showWebView()
        containerView.loadHTML(html)
    }
}

final class PreviewWebContainerView: NSView {
    let webView: WKWebView

    private let errorScrollView = NSScrollView()
    private let errorTextView = NSTextView()
    private let frameLoadDelegate = PreviewWebFrameLoadDelegate()
    private let imageSchemeHandler = LocalImageURLSchemeHandler()

    override init(frame frameRect: NSRect) {
        let configuration = makeLocalContentWebViewConfiguration()
        configuration.preferences.isTextInteractionEnabled = true
        configuration.setURLSchemeHandler(imageSchemeHandler, forURLScheme: localImageResourceScheme)
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadHTML(_ html: String) {
        frameLoadDelegate.containerView = self
        webView.loadHTMLString(rewriteLocalFileResourceURLs(in: html), baseURL: nil)
    }

    func showWebView() {
        webView.isHidden = false
        errorScrollView.isHidden = true
    }

    func showError(message: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        errorTextView.textStorage?.setAttributedString(
            NSAttributedString(string: message, attributes: attributes)
        )
        webView.isHidden = true
        errorScrollView.isHidden = false
    }

    private func setupViews() {
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = frameLoadDelegate
        addSubview(webView)

        errorScrollView.translatesAutoresizingMaskIntoConstraints = false
        errorScrollView.drawsBackground = false
        errorScrollView.borderType = .noBorder
        errorScrollView.hasVerticalScroller = true
        errorScrollView.hasHorizontalScroller = false
        errorScrollView.autohidesScrollers = true
        errorScrollView.isHidden = true

        errorTextView.drawsBackground = false
        errorTextView.isEditable = false
        errorTextView.isSelectable = true
        errorTextView.textContainerInset = NSSize(width: 16, height: 16)
        errorTextView.textContainer?.lineFragmentPadding = 0
        errorScrollView.documentView = errorTextView

        addSubview(errorScrollView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            errorScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            errorScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            errorScrollView.topAnchor.constraint(equalTo: topAnchor),
            errorScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private final class PreviewWebFrameLoadDelegate: NSObject, WKNavigationDelegate {
    weak var containerView: PreviewWebContainerView?

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        containerView?.showError(message: error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        containerView?.showError(message: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        containerView?.showWebView()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        containerView?.showError(message: "Preview rendering process terminated unexpectedly.")
    }
}

enum PreviewHTMLValidator {
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    static func validate(_ html: String) throws {
        let pattern = #"<\s*(/)?\s*([A-Za-z][A-Za-z0-9:-]*)\b[^>]*?>"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)
        var stack: [String] = []

        for match in matches {
            guard
                let fullRange = Range(match.range(at: 0), in: html),
                let tagNameRange = Range(match.range(at: 2), in: html)
            else {
                continue
            }

            let fullTag = String(html[fullRange])
            let tagName = String(html[tagNameRange]).lowercased()
            let isClosingTag = match.range(at: 1).location != NSNotFound
            let isSelfClosingTag = fullTag.hasSuffix("/>")

            if fullTag.hasPrefix("<!--") || fullTag.hasPrefix("<!") || fullTag.hasPrefix("<?") {
                continue
            }

            if isClosingTag {
                guard let lastTag = stack.popLast() else {
                    throw PreviewRenderError.invalidHTML("Unexpected closing tag </\(tagName)>.")
                }

                guard lastTag == tagName else {
                    throw PreviewRenderError.invalidHTML(
                        "Mismatched closing tag </\(tagName)>. Expected </\(lastTag)>."
                    )
                }

                continue
            }

            if isSelfClosingTag || voidElements.contains(tagName) {
                continue
            }

            stack.append(tagName)
        }

        if let unclosedTag = stack.last {
            throw PreviewRenderError.invalidHTML("Unclosed tag <\(unclosedTag)>.")
        }
    }
}

private enum PreviewRenderError: LocalizedError {
    case invalidHTML(String)

    var errorDescription: String? {
        switch self {
        case .invalidHTML(let message):
            return message
        }
    }
}
