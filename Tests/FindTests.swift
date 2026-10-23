import Cocoa
@preconcurrency import WebKit

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

/// Runs against a real WKWebView and AppKit responder chain, without additional
/// package dependencies or a signed application test host.
@main
struct FindTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            fputs("FAIL: Find integration tests exceeded 90 seconds\n", stderr)
            exit(1)
        }
        Task { @MainActor in
            do {
                try await run()
                print("All find integration tests passed.")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor private static func waitUntil(_ message: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "Timed out: \(message)")
    }

    @MainActor private static func js(_ preview: MarkdownPreviewWindowController, _ source: String,
                                     arguments: [String: Any] = [:]) async throws -> Any? {
        try await preview.webView.callAsyncJavaScript(source, arguments: arguments,
                                                     in: nil, contentWorld: .defaultClient)
    }

    @MainActor private static func find(_ preview: MarkdownPreviewWindowController, _ query: String,
                                       total: Int, current: Int = 1) async throws {
        let result = try await js(preview, "return await window.umarkdownFind.search(query);", arguments: ["query": query]) as? [String: Int]
        try check(result?["total"] == total, "\(query.debugDescription): expected \(total) matches, got \(String(describing: result))")
        try check(result?["current"] == (total > 0 ? current : 0), "Incorrect current match for \(query.debugDescription)")
    }

    @MainActor private static func run() async throws {
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = """
            <!doctype html><html><head><meta charset="utf-8">
            <style>body { font: 18px system-ui; padding: 24px; background: white; color: #222; }
            .invisible { display: none; }</style></head><body>
            <h1>Every reader</h1><p>EVERY preview finds everything.</p>
            <p>Search <strong>across</strong> <em>inline</em> formatting.</p>
            <p>Café cafe CAFÉ naïve</p>
            <p>Résumé, résumé, Résumé.</p>
            <p>visible<span style="display:none">secret</span>end</p>
            <aside style="position:relative;z-index:0">stacked result</aside>
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="40"><text x="0" y="24">diagramneedle</text></svg>
            <p>first</p><p>second</p>
            <p>fish&nbsp;and\n\t chips</p>
            <pre><code>literal.a+b [x] (y) .* ? \\ ^ $</code></pre>
            <p>こんにちは世界 東京 👩🏽‍💻 🦊 🦊</p>
            <p hidden>Every hiddenneedle</p>
            <div class="invisible"><p>Every csshiddenneedle</p></div>
            <p style="visibility:hidden">Every visibilityneedle</p>
            <details><summary>Closed details</summary><p>Every closedneedle</p></details>
            <script>const scriptneedle = "Every";</script>
            <p id="injection">\"; window.injected = true; //</p>
            </body></html>
            """
        let preview = try MarkdownPreviewWindowController(file: project.appendingPathComponent("find-test.md"),
                                                          html: fixture,
                                                          searchResources: project.appendingPathComponent("Resources/Find"))
        preview.showWindow(nil)
        preview.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitUntil("document scripts loaded") {
            try await js(preview, "return !!window.umarkdownFind;") as? Bool == true
        }

        try await find(preview, "every", total: 3)
        try await find(preview, "Search across inline", total: 1)
        let fragments = try await js(preview, "return document.querySelectorAll('umarkdown-find-match').length;") as? Int
        try check((fragments ?? 0) > 1, "Formatted phrase should have multiple fragments but one result")
        try await find(preview, "first second", total: 0)
        try await find(preview, "fish and chips", total: 1)
        try await find(preview, "cafe", total: 3)
        try await find(preview, "résumé", total: 3)
        try await find(preview, "résumé", total: 3)
        try await find(preview, "visiblesecretend", total: 0)
        try await find(preview, "visibleend", total: 1)
        try await find(preview, "stacked result", total: 1)
        try await checkRenderedHighlight(preview)
        try await find(preview, "diagramneedle", total: 1)
        try check(try await js(preview, "return document.querySelector('svg text').getBBox().width > 0;") as? Bool == true,
                  "Finding SVG labels must preserve their glyphs")
        try await checkRenderedHighlight(preview)
        for query in ["a+b", "[x]", "(y)", ".*", "?", "\\", "^", "$"] {
            try await find(preview, query, total: 1)
        }
        try await find(preview, "🦊", total: 2)
        try await find(preview, "👩🏽‍💻", total: 1)
        try await find(preview, "こんにちは", total: 1)
        for query in ["hiddenneedle", "csshiddenneedle", "visibilityneedle", "closedneedle", "scriptneedle"] {
            try await find(preview, query, total: 0)
        }
        try await find(preview, "\"; window.injected = true; //", total: 1)
        try check(try await preview.webView.evaluateJavaScript("typeof window.umarkdownFind") as? String == "undefined",
                  "Find bridge must be isolated from document scripts")
        try check(try await preview.webView.evaluateJavaScript("typeof window.injected") as? String == "undefined",
                  "Query must be passed as data")
        print("PASS: literal text, phrases, formatting, whitespace, accents, emoji, hidden text, script isolation")

        try await find(preview, "every", total: 3)
        let activeColor = try await js(preview, "return getComputedStyle(document.querySelector('.umarkdown-find-current')).backgroundColor;") as? String
        let inactiveColor = try await js(preview, "return getComputedStyle(document.querySelector('.umarkdown-find-result:not(.umarkdown-find-current)')).backgroundColor;") as? String
        try check(activeColor == "rgb(255, 255, 84)", "Current result must use reference yellow")
        try check(inactiveColor == "rgb(255, 255, 255)", "Inactive results must use white")

        try installFindMenu(project: project)
        try pressKey("f", keyCode: 3)
        try check(!preview.findBar.isHidden, "Command-F must reveal the find bar")
        try check(preview.findBar.searchField.currentEditor() != nil,
                  "Command-F must focus the search field; responder: \(String(describing: preview.window?.firstResponder)); field: \(preview.findBar.searchField.frame)")
        preview.findBar.searchField.stringValue = "every"
        preview.findBar.onQueryChange?("every")
        try await waitUntil("native result count") { preview.findBar.searchField.resultLabel.stringValue == "1 of 3 matches" }
        preview.window!.contentView!.layoutSubtreeIfNeeded()
        if let editor = preview.findBar.searchField.currentEditor() {
            try check(editor.frame.maxX <= preview.findBar.searchField.resultLabel.frame.minX,
                      "The match count must not overlap the search field editor")
        }
        if let option = CommandLine.arguments.firstIndex(of: "--snapshot"), option + 1 < CommandLine.arguments.count {
            let content = preview.window!.contentView!
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[option + 1]))
        }
        try postReturn(preview)
        try await waitUntil("Return in search field") { preview.findBar.searchField.resultLabel.stringValue == "2 of 3 matches" }
        try postReturn(preview, backwards: true)
        try await waitUntil("Shift-Return in search field") { preview.findBar.searchField.resultLabel.stringValue == "1 of 3 matches" }
        try pressKey("g", keyCode: 5)
        try await waitUntil("Command-G in search field") { preview.findBar.searchField.resultLabel.stringValue == "2 of 3 matches" }
        try pressKey("G", keyCode: 5, modifiers: [.command, .shift])
        try await waitUntil("Shift-Command-G") { preview.findBar.searchField.resultLabel.stringValue == "1 of 3 matches" }
        try pressKey("G", keyCode: 5, modifiers: [.command, .shift])
        try await waitUntil("previous wraps") { preview.findBar.searchField.resultLabel.stringValue == "3 of 3 matches" }
        preview.window?.makeFirstResponder(preview.webView)
        try pressKey("g", keyCode: 5)
        try await waitUntil("Command-G in WebKit and next wraps") { preview.findBar.searchField.resultLabel.stringValue == "1 of 3 matches" }

        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: preview.window!.windowNumber,
                                      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        preview.window?.sendEvent(escape)
        try check(preview.findBar.isHidden, "Escape in WebKit must close the find bar")
        try await waitUntil("Escape removes highlights") {
            try await js(preview, "return document.querySelectorAll('umarkdown-find-match').length === 0;") as? Bool == true
        }
        try pressKey("f", keyCode: 3)
        try await waitUntil("reopen retains query") { preview.findBar.searchField.resultLabel.stringValue == "1 of 3 matches" }
        preview.window?.sendEvent(escape)
        try check(preview.findBar.isHidden, "Escape in search field must close the find bar")
        print("PASS: native menu shortcuts, focus, wraparound, Escape in both views, reopening")

        // Superseded requests must not restore old counts or highlights.
        preview.showFindBar(nil)
        preview.findBar.searchField.stringValue = "every"
        preview.search.find("every")
        preview.findBar.searchField.stringValue = "notpresent"
        preview.search.find("notpresent")
        try await waitUntil("latest query wins") { preview.findBar.searchField.resultLabel.stringValue == "Not found" }
        preview.search.find("every")
        preview.hideFindBar()
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(try await js(preview, "return document.querySelectorAll('umarkdown-find-match').length;") as? Int == 0,
                  "Closing during debounce must prevent late highlights")
        print("PASS: rapid query changes and dismissal during pending search")

        try await find(preview, "dynamicterm", total: 0)
        _ = try await js(preview, "const p = document.createElement('p'); p.textContent = 'dynamicterm'; document.body.append(p);")
        try await find(preview, "dynamicterm", total: 1)
        try await find(preview, "closedneedle", total: 0)
        _ = try await js(preview, "document.querySelector('details').open = true;")
        try await find(preview, "closedneedle", total: 1)
        print("PASS: search index refreshes after document and visibility changes")

        // A buffered document swap must reconnect Find to the displayed web view.
        let reloadFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try fixture.write(to: reloadFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: reloadFile) }
        let live = try MarkdownPreviewWindowController(file: reloadFile, html: fixture,
                                                       searchResources: project.appendingPathComponent("Resources/Find"))
        live.renderHTML = { try? String(contentsOf: reloadFile, encoding: .utf8) }
        live.showWindow(nil)
        try await waitUntil("live preview ready") {
            try await js(live, "return !!window.umarkdownFind;") as? Bool == true
        }
        live.showFindBar(nil)
        live.findBar.searchField.stringValue = "every"
        live.search.find("every", debounce: false)
        try await waitUntil("initial live search") { live.findBar.searchField.resultLabel.stringValue == "1 of 3 matches" }
        let previousView = live.webView
        try "<html><body><p>Every replacement</p></body></html>".write(to: reloadFile, atomically: true, encoding: .utf8)
        try await waitUntil("Find reconnects after atomic save") {
            live.webView !== previousView && live.findBar.searchField.resultLabel.stringValue == "1 match"
        }
        live.window?.close()
        print("PASS: live reload preserves Find query across buffered view replacement")

        let original = try await js(preview, "return document.body.textContent;") as? String
        try await find(preview, "Search across inline", total: 1)
        _ = try await js(preview, "return await window.umarkdownFind.hide();")
        try check(try await js(preview, "return document.body.textContent;") as? String == original,
                  "Searching and dismissing must preserve the document text")

        let large = (0..<10_000).map { "<p>Row \($0): a <strong>scaled</strong> search result.</p>" }.joined()
        _ = try await js(preview, "document.body.innerHTML = html;", arguments: ["html": large])
        let start = Date()
        try await find(preview, "scaled search", total: 10_000)
        print(String(format: "PASS: 10,000 formatted matches in %.3f seconds", Date().timeIntervalSince(start)))
        let moveStart = Date()
        for _ in 0..<10 {
            _ = try await js(preview, "return await window.umarkdownFind.move(query, 1);", arguments: ["query": "scaled search"])
        }
        print(String(format: "PASS: 10 navigation steps through 10,000 matches in %.3f seconds", Date().timeIntervalSince(moveStart)))
        preview.window?.close()
    }

    @MainActor private static func checkRenderedHighlight(_ preview: MarkdownPreviewWindowController) async throws {
        _ = try await js(preview, "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));")
        let rect = try await js(preview, """
            const rect = document.querySelector('.umarkdown-find-current').getBoundingClientRect();
            return {x: rect.x, y: rect.y, width: rect.width, height: rect.height};
            """) as! [String: Double]
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: rect["x"]!, y: rect["y"]!, width: rect["width"]!, height: rect["height"]!)
        let image = try await preview.webView.takeSnapshot(configuration: configuration)
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        var foundYellow = false
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                bitmap.getPixel(&pixel, atX: x, y: y)
                if pixel[0] == 255 && pixel[1] == 255 && (80...88).contains(pixel[2]) { foundYellow = true }
            }
        }
        try check(foundYellow, "The current highlight must remain yellow inside a stacking context")
    }

    @MainActor private static func installFindMenu(project: URL) throws {
        let document = try XMLDocument(contentsOf: project.appendingPathComponent("UMarkdown/Base.lproj/Main.storyboard"))
        let mainMenu = NSMenu()
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Edit")
        for node in try document.nodes(forXPath: "//menu[@id='find-menu']/items/menuItem") {
            guard let node = node as? XMLElement,
                  let title = node.attribute(forName: "title")?.stringValue,
                  let key = node.attribute(forName: "keyEquivalent")?.stringValue,
                  let action = try node.nodes(forXPath: "connections/action/@selector").first?.stringValue else {
                throw Failure(description: "Invalid Find menu wiring")
            }
            submenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
        }
        try check(submenu.items.count == 3, "Find menu must contain all three keyboard commands")
        item.submenu = submenu
        mainMenu.addItem(item)
        NSApp.mainMenu = mainMenu
    }

    @MainActor private static func pressKey(_ characters: String, keyCode: UInt16,
                                          modifiers: NSEvent.ModifierFlags = .command) throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: 0, windowNumber: NSApp.keyWindow!.windowNumber,
                                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: keyCode)!
        try check(NSApp.mainMenu!.performKeyEquivalent(with: event), "Menu did not handle \(characters)")
    }

    @MainActor private static func postReturn(_ preview: MarkdownPreviewWindowController, backwards: Bool = false) throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: backwards ? .shift : [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: preview.window!.windowNumber,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                     isARepeat: false, keyCode: 36)!
        NSApp.postEvent(event, atStart: false)
    }
}
