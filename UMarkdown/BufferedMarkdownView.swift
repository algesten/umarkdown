import Cocoa
import WebKit

/// Prepares each update underneath the displayed page so loading and scroll
/// restoration never appear in the visible preview.
final class BufferedMarkdownView: NSView, WKNavigationDelegate {
    private(set) var webView: WKWebView
    weak var navigationDelegate: WKNavigationDelegate?
    var onDisplay: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private let configuration: WKWebViewConfiguration
    private var pendingWebView: WKWebView?
    private var pendingNavigation: WKNavigation?
    private var displayedDocument: URL?
    private var hasDisplayedDocument = false
    private var revision = 0

    init(frame: NSRect, configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        self.configuration = configuration
        webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init(frame: frame)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        addSubview(webView)
    }

    required init?(coder: NSCoder) { nil }

    func loadHTMLString(_ html: String, baseURL: URL?, documentURL: URL?) {
        revision += 1
        discardPendingView()

        let nextView = WKWebView(frame: bounds, configuration: configuration)
        nextView.autoresizingMask = [.width, .height]
        nextView.navigationDelegate = self
        nextView.pageZoom = webView.pageZoom
        // Keep it attached and rendering, with the current page covering it.
        addSubview(nextView, positioned: .below, relativeTo: webView)
        pendingWebView = nextView
        pendingDocument = documentURL
        pendingNavigation = nextView.loadHTMLString(html, baseURL: baseURL)
    }

    private var pendingDocument: URL?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === pendingWebView, navigation === pendingNavigation else { return }
        let revision = self.revision
        let document = pendingDocument
        webView.callAsyncJavaScript("""
            // Math typesetting and fonts can change the page height after navigation.
            if (window.MathJax?.startup?.promise) {
                await window.MathJax.startup.promise.catch(() => {});
            }
            await document.fonts.ready;
            await Promise.all(Array.from(document.images, image => image.decode().catch(() => {})));
            return true;
            """, arguments: [:], in: nil, in: .page) { [weak self, weak webView] result in
                guard let self, let webView, self.isCurrent(webView, revision: revision) else { return }
                switch result {
                case .success:
                    self.restorePosition(in: webView, document: document, revision: revision)
                case .failure(let error):
                    self.fail(webView, error: error)
                }
            }
    }

    private func restorePosition(in nextView: WKWebView, document: URL?, revision: Int) {
        guard hasDisplayedDocument, displayedDocument == document else {
            finishPreparing(nextView, position: ["x": 0, "y": 0], document: document, revision: revision)
            return
        }
        // Read the visible page at the last moment, including any scrolling during loading.
        webView.evaluateJavaScript("({x: window.scrollX, y: window.scrollY})") { [weak self, weak nextView] value, error in
            guard let self, let nextView, self.isCurrent(nextView, revision: revision) else { return }
            if let error {
                self.fail(nextView, error: error)
                return
            }
            self.finishPreparing(nextView, position: value as? [String: Double] ?? ["x": 0, "y": 0], document: document, revision: revision)
        }
    }

    private func finishPreparing(_ nextView: WKWebView, position: [String: Double], document: URL?, revision: Int) {
        nextView.callAsyncJavaScript("""
            // Explicitly override smooth scrolling, including custom stylesheets.
            window.scrollTo({left: x, top: y, behavior: 'instant'});
            // Let WebKit paint the restored viewport before revealing the page.
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            return true;
            """, arguments: ["x": position["x"] ?? 0, "y": position["y"] ?? 0], in: nil, in: .defaultClient) { [weak self, weak nextView] result in
                guard let self, let nextView, self.isCurrent(nextView, revision: revision) else { return }
                switch result {
                case .success:
                    let previousView = self.webView
                    let hadFocus = (self.window?.firstResponder as? NSView)?.isDescendant(of: previousView) == true
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0
                        context.allowsImplicitAnimation = false
                        self.webView = nextView
                        self.pendingWebView = nil
                        self.pendingNavigation = nil
                        self.displayedDocument = document
                        self.hasDisplayedDocument = true
                        previousView.navigationDelegate = nil
                        previousView.removeFromSuperview()
                    }
                    if hadFocus { self.window?.makeFirstResponder(nextView) }
                    self.onDisplay?()
                case .failure(let error):
                    self.fail(nextView, error: error)
                }
            }
    }

    private func isCurrent(_ view: WKWebView, revision: Int) -> Bool {
        view === pendingWebView && revision == self.revision
    }

    private func discardPendingView() {
        pendingWebView?.navigationDelegate = nil
        pendingWebView?.stopLoading()
        pendingWebView?.removeFromSuperview()
        pendingWebView = nil
        pendingNavigation = nil
    }

    private func fail(_ view: WKWebView, error: Error) {
        guard view === pendingWebView else { return }
        discardPendingView()
        onFailure?(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(webView, error: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationDelegate?.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler) == nil {
            decisionHandler(.allow)
        }
    }
}
