import Cocoa
@preconcurrency import WebKit

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

@main
struct LinkNavigationTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            fputs("FAIL: Link navigation tests exceeded 45 seconds\n", stderr)
            exit(1)
        }
        Task { @MainActor in
            do {
                try await run()
                print("All link navigation tests passed.")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    private static let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>body { margin: 16px; } #section { margin-top: 2000px; height: 800px; }</style>
        </head><body id="document">
        <a id="https" href="https://example.com/preview">Website</a>
        <a id="http" href="http://example.com/preview">HTTP website</a>
        <a id="blank" href="https://example.com/new-window" target="_blank">New window</a>
        <a id="mail" href="mailto:preview@example.com">Email</a>
        <a id="custom" href="umarkdown-link-test://open/document">Another application</a>
        <a id="anchor" href="#section">Heading</a>
        <h1 id="section">Document heading</h1>
        </body></html>
        """

    @MainActor private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor private static func waitUntil(_ message: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "Timed out: \(message)")
    }

    @MainActor private static func js(_ view: WKWebView, _ source: String) async throws -> Any? {
        try await view.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    @MainActor private static func checkLinks(in preview: BufferedMarkdownView) async throws {
        var opened: [URL] = []
        var confirmed: [URL] = []
        var allowCustomScheme = false
        preview.openURL = { opened.append($0); return true }
        preview.confirmOpenURL = { confirmed.append($0); return allowCustomScheme }
        let view = preview.webView

        for (id, destination) in [
            ("https", "https://example.com/preview"),
            ("http", "http://example.com/preview"),
            ("blank", "https://example.com/new-window"),
            ("mail", "mailto:preview@example.com")
        ] {
            let previous = opened.count
            _ = try await js(view, "document.getElementById('\(id)').click(); return true;")
            try await waitUntil("\(id) link handed to the system") { opened.count > previous }
            try check(opened.count == previous + 1 && opened.last?.absoluteString == destination,
                      "Link must open its destination exactly once: \(opened)")
        }
        try check(confirmed.isEmpty, "Web and email links must open without a confirmation")
        try check(try await js(view, "return document.body.id;") as? String == "document",
                  "External links must keep the rendered document in the preview")

        _ = try await js(view, "document.getElementById('custom').click(); return true;")
        try await waitUntil("custom scheme confirmation") { confirmed.count == 1 }
        try check(opened.count == 4, "Declining a custom scheme must not open it")
        allowCustomScheme = true
        _ = try await js(view, "document.getElementById('custom').click(); return true;")
        try await waitUntil("confirmed custom scheme handed to the system") { opened.count == 5 }
        try check(confirmed.count == 2 && opened.last == confirmed.last,
                  "Custom schemes must require confirmation before opening")

        _ = try await js(view, "document.getElementById('anchor').click(); return true;")
        do {
            try await waitUntil("heading link scrolls inside the document") {
                try await js(view, "return location.hash === '#section' && window.scrollY > 1000;") as? Bool == true
            }
        } catch {
            let state = try await js(view, "return [location.href, document.baseURI, window.scrollY];")
            throw Failure(description: "\(error); URL: \(String(describing: view.url)), page: \(String(describing: state)), confirmations: \(confirmed)")
        }
        try check(opened.count == 5 && confirmed.count == 2,
                  "Heading links must stay in the document without opening another application")
    }

    @MainActor private static func run() async throws {
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = project.appendingPathComponent("link-test.md")
        let controller = try MarkdownPreviewWindowController(file: file, html: html,
                                                              searchResources: project.appendingPathComponent("Resources/Find"))
        controller.showWindow(nil)
        let preview = controller.window!.contentView!.subviews.compactMap { $0 as? BufferedMarkdownView }.first!
        try await waitUntil("document preview displayed") {
            try await js(preview.webView, "return document.body?.id;") as? String == "document"
        }
        try await checkLinks(in: preview)
        print("PASS: Document links, new-window links, mail, scheme confirmation, and heading anchors")

        let previousView = preview.webView
        preview.loadHTMLString(html, baseURL: nil, documentURL: nil)
        try await waitUntil("replacement preview displayed") { preview.webView !== previousView }
        try await checkLinks(in: preview)
        print("PASS: Link handling survives buffered reloads and anchors work without a base URL")
        controller.close()
    }
}
