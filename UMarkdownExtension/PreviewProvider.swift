//
//  PreviewProvider.swift
//  UMarkdownExtension
//
//  Created by Sbarex on 16/12/20.
//

import Cocoa
import Quartz
import OSLog


class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    /// Size suggested to Quick Look. Reduced to fit the screen.
    static var previewContentSize: CGSize {
        let size = Settings.shared.qlWindowSize
        guard let screen = NSScreen.main else {
            return size
        }
        let available = screen.visibleFrame.size
        return CGSize(
            width: min(size.width, available.width * 0.9),
            height: min(size.height, available.height * 0.9)
        )
    }

    /// Provides HTML preview data for Quick Look.
    /// This is the primary entry point on macOS 12+ when QLIsDataBasedPreview is set to true.
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        Settings.shared.startMonitorChange()

        let html = try renderMD(url: request.fileURL)

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: Self.previewContentSize) { (replyToUpdate: QLPreviewReply) in
            replyToUpdate.stringEncoding = .utf8
            return html.data(using: .utf8)!
        }

        return reply
    }

    func renderMD(url: URL) throws -> String {
        os_log(
            "Generating preview for file %{public}s",
            log: OSLog.quickLookExtension,
            type: .info,
            url.path
        )

        let settings = Settings.shared
        let markdown_url = Settings.getMarkdownFile(from: url)
        let text = try settings.render(file: markdown_url, baseDir: markdown_url.deletingLastPathComponent().path)

        let html = settings.getCompleteHTML(title: url.lastPathComponent, body: text)

        return html
    }
}
