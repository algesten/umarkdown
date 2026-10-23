import Cocoa

/// A native Safari-style find bar, with the result count inside the search field.
final class FindBarView: NSView, NSSearchFieldDelegate {
    let searchField = FindSearchField()
    let navigation = NSSegmentedControl()
    var onQueryChange: ((String) -> Void)?
    var onMove: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        searchField.delegate = self
        searchField.placeholderString = NSLocalizedString("Find in document", comment: "Find field placeholder")
        searchField.setAccessibilityLabel(NSLocalizedString("Find in document", comment: "Find field label"))
        searchField.font = .systemFont(ofSize: 13)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(queryChanged)
        searchField.searchMenuTemplate = nil
        searchField.maximumRecents = 0

        navigation.segmentCount = 2
        navigation.segmentStyle = .rounded
        navigation.trackingMode = .momentary
        navigation.controlSize = .small
        for (index, symbol) in ["chevron.left", "chevron.right"].enumerated() {
            let label = index == 0 ? NSLocalizedString("Previous match", comment: "Find button")
                : NSLocalizedString("Next match", comment: "Find button")
            navigation.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: index)
            navigation.setWidth(24, forSegment: index)
            navigation.setToolTip(label, forSegment: index)
        }
        navigation.target = self
        navigation.action = #selector(move)
        navigation.isEnabled = false

        let done = NSButton(title: NSLocalizedString("Done", comment: "Close find bar"),
                            target: self, action: #selector(dismiss))
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.font = .systemFont(ofSize: 13)

        let row = NSStackView(views: [searchField, navigation, done])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let preferredWidth = searchField.widthAnchor.constraint(equalToConstant: 550)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            searchField.heightAnchor.constraint(equalToConstant: 24),
            done.widthAnchor.constraint(equalToConstant: 52),
            preferredWidth
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1 / (window?.backingScaleFactor ?? 1)).fill()
    }

    func update(_ result: PreviewSearch.Result) {
        navigation.isEnabled = result.total > 0 && !result.isSearching
        let label: String
        if searchField.stringValue.isEmpty {
            label = ""
        } else if result.failed {
            label = NSLocalizedString("Search unavailable", comment: "Find error")
        } else if result.isSearching {
            label = NSLocalizedString("Searching…", comment: "Find progress")
        } else if result.total == 0 {
            label = NSLocalizedString("Not found", comment: "No find results")
        } else if result.total == 1 {
            label = NSLocalizedString("1 match", comment: "Single find result")
        } else {
            label = String.localizedStringWithFormat(
                NSLocalizedString("%ld of %ld matches", comment: "Current and total find results"),
                result.current, result.total)
        }
        searchField.resultLabel.stringValue = label
        searchField.needsLayout = true
        searchField.setAccessibilityHelp(label)
    }

    @objc private func queryChanged() { onQueryChange?(searchField.stringValue) }
    @objc private func move() { onMove?(navigation.selectedSegment == 0) }
    @objc private func dismiss() { onDismiss?() }

    func controlTextDidChange(_ notification: Notification) {
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        queryChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onMove?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        return false
    }
}

final class FindSearchField: NSSearchField {
    let resultLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        cell = FindSearchFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        isEnabled = true
        isBezeled = true
        usesSingleLineMode = true
        focusRingType = .exterior
        resultLabel.font = .systemFont(ofSize: 13)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.setAccessibilityElement(false)
        addSubview(resultLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        let width = resultLabel.stringValue.isEmpty ? 0 : resultLabel.fittingSize.width
        (cell as? FindSearchFieldCell)?.resultWidth = width > 0 ? width + 8 : 0
        super.layout()
        guard let searchCell = cell as? NSSearchFieldCell else { return }
        let cancel = searchCell.cancelButtonRect(forBounds: bounds)
        resultLabel.frame = NSRect(x: cancel.minX - width - 4,
                                   y: (bounds.height - resultLabel.fittingSize.height) / 2,
                                   width: width, height: resultLabel.fittingSize.height)
        if let editor = currentEditor() {
            editor.frame = searchCell.searchTextRect(forBounds: bounds)
        }
        needsDisplay = true
    }
}

private final class FindSearchFieldCell: NSSearchFieldCell {
    var resultWidth: CGFloat = 0

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var textRect = super.searchTextRect(forBounds: rect)
        textRect.size.width = max(0, textRect.width - resultWidth)
        return textRect
    }
}
