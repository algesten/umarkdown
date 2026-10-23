//
//  AppDelegate.swift
//  UMarkdown
//
//  Created by Sbarex on 09/12/20.
//

import Cocoa
import WebKit
import UniformTypeIdentifiers

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var settingsWindowController: PreferencesWindowController?

    private var previewWindows: [MarkdownPreviewWindowController] = []
    private var receivedFileOpenAtLaunch = false

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        receivedFileOpenAtLaunch = true
        return openPreview(for: URL(fileURLWithPath: filename))
    }

    @IBAction func showSettings(_ sender: Any?) {
        let controller = settingsWindowController ?? NSApp.windows.compactMap { $0.windowController as? PreferencesWindowController }.first
            ?? NSStoryboard(name: "Main", bundle: nil).instantiateController(withIdentifier: "SettingsWindow") as? PreferencesWindowController
        guard let controller else { return }
        settingsWindowController = controller
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMarkdownPreview(sender)
        }
        return true
    }

    @discardableResult
    func openPreview(for file: URL) -> Bool {
        do {
            let markdown = Settings.getMarkdownFile(from: file)
            guard FileManager.default.isReadableFile(atPath: markdown.path) else {
                throw CocoaError(.fileReadNoPermission)
            }
            let body = try Settings.shared.render(file: markdown, baseDir: markdown.deletingLastPathComponent().path)
            let html = Settings.shared.getCompleteHTML(title: file.lastPathComponent, body: body)
            let controller = try MarkdownPreviewWindowController(file: markdown, html: html)
            controller.renderHTML = {
                guard let body = try? Settings.shared.render(file: markdown, baseDir: markdown.deletingLastPathComponent().path) else { return nil }
                return Settings.shared.getCompleteHTML(title: file.lastPathComponent, body: body)
            }
            controller.onClose = { [weak self, weak controller] in
                self?.previewWindows.removeAll { $0 === controller }
            }
            previewWindows.append(controller)
            controller.showWindow(self)
            controller.window?.makeKeyAndOrderFront(self)
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String.localizedStringWithFormat(NSLocalizedString("Unable to open %@", comment: "Markdown open error"), file.lastPathComponent)
            alert.runModal()
            return false
        }
    }

    @IBAction func openMarkdownPreview(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText,
                                     UTType(filenameExtension: "markdown") ?? .plainText,
                                     UTType(filenameExtension: "rmd") ?? .plainText,
                                     UTType(filenameExtension: "qmd") ?? .plainText]
        panel.message = NSLocalizedString("Select Markdown files to preview", comment: "")
        guard panel.runModal() == .OK else { return }
        for file in panel.urls {
            openPreview(for: file)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for window in sender.windows {
            if let wc = window.windowController as? PreferencesWindowController, !wc.windowShouldClose(window) {
                return .terminateCancel
            }
        }

        return .terminateNow
    }

    func localizeMainMenu() {
        let appKitBundle = Bundle(for: NSMenuItem.self)
        /*guard let appKitBundle = Bundle(path: "/System/Library/Frameworks/AppKit.framework") else {
            return
        }*/
        guard let mainMenu = NSApp.mainMenu else {
            return
        }

        let tables = ["MenuCommands", "InputManager"]

        func localize(key: String) -> String? {
            for table in tables {
                let localized = appKitBundle.localizedString(
                    forKey: key,
                    value: nil,
                    table: table)
                if localized != key {
                    return localized
                }
            }

            return nil
        }

        func localize(menu: NSMenu, indent: String = "") {
            let title = menu.title

            // print("\(indent) [\(title)]")
            if !title.isEmpty {
                if let localized = localize(key: title) {
                    // print("\(indent) - \(title) → \(localized)")
                    menu.title = localized
                }
            }

            for item in menu.items {
                guard !item.isSeparatorItem else {
                    continue
                }

                let title = item.title

                if let localized = localize(key: title) {
                    // print("\(indent) - \(title) → \(localized)")
                    item.title = localized
                }

                if let submenu = item.submenu, !submenu.items.isEmpty {
                    localize(menu: submenu, indent: indent + " ")
                }
            }
        }

        localize(menu: mainMenu)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        settingsWindowController = NSApp.windows.compactMap { $0.windowController as? PreferencesWindowController }.first
        settingsWindowController?.window?.orderOut(self)
        if let lang = Bundle.main.preferredLocalizations.first, lang != "en" {
            localizeMainMenu()
        }

        Settings.shared.installDependencies(override: .onlyOlder)

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.receivedFileOpenAtLaunch, self.previewWindows.isEmpty else { return }
            self.openMarkdownPreview(self)
        }
    }

    @objc private func printPreview(_ sender: Any?) {
        guard let webView = activeWebView(), let window = webView.window,
              !webView.isLoading, window.attachedSheet == nil else { return }
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.horizontalPagination = .fit
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        let operation = webView.printOperation(with: printInfo)
        operation.jobTitle = window.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(printPreview(_:)) {
            guard let webView = activeWebView() else { return false }
            return !webView.isLoading && webView.window?.attachedSheet == nil
        }
        return true
    }

    private func activeWebView() -> WKWebView? {
        guard let window = NSApp.keyWindow else { return nil }
        func firstWebView(in view: NSView) -> WKWebView? {
            if let preview = view as? BufferedMarkdownView { return preview.webView }
            if let webView = view as? WKWebView { return webView }
            for subview in view.subviews {
                if let webView = firstWebView(in: subview) { return webView }
            }
            return nil
        }
        return window.contentView.flatMap(firstWebView(in:))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }


}
