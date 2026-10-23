// Run with a macOS GUI session:
// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -swift-version 5 \
//   UMarkdown/BufferedMarkdownView.swift Tests/BufferedMarkdownViewTests.swift \
//   -o /tmp/umarkdown-preview-tests && /tmp/umarkdown-preview-tests
import Cocoa
import WebKit

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class PreviewTests: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var preview: BufferedMarkdownView!
    private let file = URL(fileURLWithPath: "/tmp/buffered-preview-test.md")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "UMarkdown preview regression tests"
        preview = BufferedMarkdownView(frame: .zero)
        preview.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // A single test timeout; production monitoring and display use no timers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: Preview did not become ready within 30 seconds\n", stderr)
            exit(1)
        }
        Task {
            do {
                try await run()
                print("PASS: Buffered preview position, pixels, rapid updates, and document switching")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func html(_ version: String, height: Int = 6000, delay: Int = 0) -> String {
        """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-test'">
        <style>
        html { scroll-behavior: smooth !important; }
        body { margin: 0; }
        main { width: 1600px; height: \(height)px; background: repeating-linear-gradient(#123456 0px, #abcdef 90px, #fedcba 180px); }
        </style>
        <script nonce="test">
        window.MathJax = {startup: {promise: new Promise(resolve => setTimeout(resolve, \(delay)))}};
        </script></head><body data-version="\(version)"><main></main></body></html>
        """
    }

    private func display(_ html: String, document: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            preview.onDisplay = { [weak self] in
                self?.preview.onDisplay = nil
                self?.preview.onFailure = nil
                continuation.resume()
            }
            preview.onFailure = { [weak self] error in
                self?.preview.onDisplay = nil
                self?.preview.onFailure = nil
                continuation.resume(throwing: error)
            }
            preview.loadHTMLString(html, baseURL: document.deletingLastPathComponent(), documentURL: document)
        }
    }

    private func script(_ source: String, in view: WKWebView? = nil) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            (view ?? preview.webView).callAsyncJavaScript(source, arguments: [:], in: nil, in: .defaultClient) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func position() async throws -> [Double] {
        try await script("return [window.scrollX, window.scrollY];") as! [Double]
    }

    private func assert(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    private func snapshot() async throws -> Data {
        let view = preview.webView
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? Failure(description: "Missing snapshot")) }
            }
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    private func assertStationary(at expected: [Double]) async throws {
        let positions = try await script("""
            const positions = [];
            for (let frame = 0; frame < 12; frame++) {
                positions.push([window.scrollX, window.scrollY]);
                await new Promise(resolve => requestAnimationFrame(resolve));
            }
            return positions;
            """) as! [[Double]]
        try assert(positions.allSatisfy { $0 == expected }, "Viewport moved after reveal: \(positions), expected \(expected)")
    }

    private func run() async throws {
        try await display(html("first"), document: file)
        _ = try await script("window.scrollTo({left: 120, top: 2400, behavior: 'instant'}); await new Promise(requestAnimationFrame); return true;")
        let expected = try await position()
        try assert(expected == [120, 2400], "Test did not reach the scrolled viewport")
        let before = try await snapshot()
        try await display(html("second"), document: file)
        try await assertStationary(at: expected)
        let after = try await snapshot()
        try assert(before == after, "An unchanged viewport rendered different pixels after reload")
        print("PASS: Smooth CSS cannot animate restoration; viewport pixels match across reload")

        let visibleView = preview.webView
        let pending = Task { try await display(html("slow", delay: 600), document: file) }
        try await Task.sleep(nanoseconds: 150_000_000)
        try assert(preview.webView === visibleView && preview.subviews.last === visibleView,
                   "Loading replaced or uncovered the visible document early")
        _ = try await script("window.scrollTo({left: 160, top: 3500, behavior: 'instant'}); return true;")
        try await pending.value
        try await assertStationary(at: [160, 3500])
        print("PASS: Current document stays visible; scrolling during preparation is preserved")

        preview.loadHTMLString(html("superseded", delay: 600), baseURL: file.deletingLastPathComponent(), documentURL: file)
        try await Task.sleep(nanoseconds: 150_000_000)
        try await display(html("latest"), document: file)
        try assert(try await script("return document.body.dataset.version;") as? String == "latest", "A superseded update was displayed")
        try await assertStationary(at: [160, 3500])
        try assert(preview.subviews.count == 1, "Finished or superseded views were retained")
        print("PASS: Rapid updates display the latest revision")

        try await display(html("short", height: 1000), document: file)
        let clamped = try await position()
        try assert(clamped == [160, 400], "Shorter document did not clamp its viewport: \(clamped)")
        try await assertStationary(at: clamped)
        try await display(html("other"), document: URL(fileURLWithPath: "/tmp/another-preview.md"))
        try await assertStationary(at: [0, 0])
        print("PASS: Shorter documents clamp instantly; opening another document starts at the top")
    }
}

@main
private struct TestApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let tests = PreviewTests()
        app.delegate = tests
        app.run()
    }
}
