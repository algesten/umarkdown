import Cocoa
@preconcurrency import WebKit
import OSLog

/// Owns the asynchronous bridge to the bundled search library. Each preview has
/// its own search state; document scripts cannot access the isolated world.
@MainActor
final class PreviewSearch {
    struct Result: Equatable {
        var current = 0
        var total = 0
        var isSearching = false
        var failed = false
    }

    var onChange: ((Result) -> Void)?
    private var webView: WKWebView
    private var pending: Task<Void, Never>?
    private var revision = 0
    private(set) var query = ""
    private(set) var isVisible = false

    static func configuration(resourceDirectory: URL) throws -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        for name in ["advanced-mark.min.js", "find.js"] {
            let source = try String(contentsOf: resourceDirectory.appendingPathComponent(name), encoding: .utf8)
            configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true, in: .defaultClient))
        }
        return configuration
    }

    init(webView: WKWebView) {
        self.webView = webView
    }

    func setWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    func find(_ query: String, debounce: Bool = true) {
        self.query = query
        isVisible = true
        run("search", delay: debounce ? 120_000_000 : 0)
    }

    func move(backwards: Bool) {
        isVisible = true
        run("move", direction: backwards ? -1 : 1)
    }

    func hide() {
        isVisible = false
        run("hide")
    }

    func documentWillLoad() {
        revision += 1
        pending?.cancel()
        onChange?(Result(isSearching: isVisible && !query.isEmpty))
    }

    func documentDidLoad() {
        if isVisible { find(query, debounce: false) }
    }

    private func run(_ action: String, direction: Int = 1, delay: UInt64 = 0) {
        revision += 1
        let request = revision
        let query = query
        pending?.cancel()
        if action == "search" { onChange?(Result(isSearching: !query.isEmpty)) }

        pending = Task { [weak self] in
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                guard let self, !Task.isCancelled else { return }
                let value = try await self.webView.callAsyncJavaScript("""
                    if (!window.umarkdownFind) return { current: 0, total: 0 };
                    return window.umarkdownFind[action](query, direction);
                    """, arguments: ["action": action, "query": query, "direction": direction],
                    in: nil, contentWorld: .defaultClient)
                guard request == self.revision, !Task.isCancelled else { return }
                if let result = value as? [String: Int] {
                    self.onChange?(Result(current: result["current"] ?? 0, total: result["total"] ?? 0))
                }
            } catch is CancellationError {
                // A newer query, navigation, or dismissal superseded this task.
            } catch {
                guard let self, request == self.revision, !Task.isCancelled else { return }
                Logger(subsystem: "UMarkdown", category: "Find").error("Find failed: \(error.localizedDescription, privacy: .public)")
                self.onChange?(Result(failed: true))
            }
        }
    }
}
