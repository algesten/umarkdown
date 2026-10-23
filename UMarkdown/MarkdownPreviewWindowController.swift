import Cocoa
@preconcurrency import WebKit

final class MarkdownPreviewWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    var onClose: (() -> Void)?
    var webView: WKWebView { preview.webView }
    private let preview: BufferedMarkdownView
    var renderHTML: (() -> String?)?
    private var monitor: MarkdownFileMonitor?
    let findBar = FindBarView()
    let search: PreviewSearch
    private var findBarHeight: NSLayoutConstraint!

    init(file: URL, html: String, searchResources: URL? = nil) throws {
        let resources = searchResources ?? Bundle.main.resourceURL!.appendingPathComponent("Find")
        preview = BufferedMarkdownView(frame: .zero, configuration: try PreviewSearch.configuration(resourceDirectory: resources))
        search = PreviewSearch(webView: preview.webView)

        let window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 700),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.title = file.lastPathComponent
        window.representedURL = file
        window.minSize = NSSize(width: 400, height: 250)
        window.center()
        super.init(window: window)
        window.delegate = self
        preview.onFailure = { [weak self] error in
            guard let window = self?.window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
        preview.onDisplay = { [weak self] in
            guard let self else { return }
            self.search.documentWillLoad()
            self.search.setWebView(self.webView)
            self.search.documentDidLoad()
        }

        let content = NSView()
        window.contentView = content
        for view in [findBar, preview] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        findBar.isHidden = true
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: content.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            findBarHeight,
            preview.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        findBar.onQueryChange = { [weak self] query in self?.search.find(query) }
        findBar.onMove = { [weak self] backwards in self?.search.move(backwards: backwards) }
        findBar.onDismiss = { [weak self] in self?.hideFindBar() }
        search.onChange = { [weak self] result in self?.findBar.update(result) }
        preview.loadHTMLString(html, baseURL: file.deletingLastPathComponent(), documentURL: file)
        monitor = MarkdownFileMonitor(file: file) { [weak self] in
            guard let self, let html = self.renderHTML?() else { return }
            self.preview.loadHTMLString(html, baseURL: file.deletingLastPathComponent(), documentURL: file)
        }
    }

    required init?(coder: NSCoder) { nil }

    @IBAction func showFindBar(_ sender: Any?) {
        if findBar.isHidden {
            revealFindBar()
            search.find(findBar.searchField.stringValue, debounce: false)
        }
        window?.makeFirstResponder(findBar.searchField)
        findBar.searchField.selectText(sender)
    }

    @IBAction func findNext(_ sender: Any?) {
        revealFindBar()
        search.move(backwards: false)
    }

    @IBAction func findPrevious(_ sender: Any?) {
        revealFindBar()
        search.move(backwards: true)
    }

    private func revealFindBar() {
        findBar.isHidden = false
        findBarHeight.constant = 44
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func hideFindBar() {
        guard !findBar.isHidden else { return }
        search.hide()
        window?.makeFirstResponder(webView)
        findBar.isHidden = true
        findBarHeight.constant = 0
    }

    override func cancelOperation(_ sender: Any?) { hideFindBar() }

    func windowWillClose(_ notification: Notification) {
        monitor = nil
        search.documentWillLoad()
        onClose?()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        search.documentWillLoad()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        search.documentDidLoad()
    }
}

private final class PreviewWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        // WebKit and the search field's field editor can both consume Escape.
        // Handle it at the preview window so one press always dismisses Find.
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let preview = windowController as? MarkdownPreviewWindowController,
           !preview.findBar.isHidden {
            preview.hideFindBar()
            return
        }
        super.sendEvent(event)
    }
}

/// Watches both the file inode and its parent directory. The directory event
/// catches editors that save by renaming a replacement over the original file.
final class MarkdownFileMonitor {
    private let file: URL
    private let onChange: () -> Void
    private var lastContents: Data?
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?

    init(file: URL, onChange: @escaping () -> Void) {
        self.file = file
        self.onChange = onChange
        self.lastContents = try? Data(contentsOf: file)
        directorySource = makeSource(path: file.deletingLastPathComponent().path, mask: [.write, .rename, .delete]) { [weak self] in
            self?.armFile()
            self?.reportChange()
        }
        armFile()
    }

    private func armFile() {
        fileSource?.cancel()
        fileSource = makeSource(path: file.path, mask: [.write, .rename, .delete, .revoke]) { [weak self] in
            self?.armFile()
            self?.reportChange()
        }
    }

    private func reportChange() {
        guard let contents = try? Data(contentsOf: file), contents != lastContents else { return }
        lastContents = contents
        onChange()
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent, handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(FileManager.default.fileSystemRepresentation(withPath: path), O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }
}
