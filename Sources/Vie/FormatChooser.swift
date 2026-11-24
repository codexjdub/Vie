import AppKit
import VieText

/// The Save As panel's Encoding and Line Endings pop-ups, set to the file's current format.
@MainActor
final class FormatChooser {
    let view: NSView
    let encodingPopUp = NSPopUpButton()
    let lineEndingPopUp = NSPopUpButton()
    private let original: TextFormat

    init(_ format: TextFormat) {
        original = format
        let menu = encodingPopUp.menu ?? NSMenu()
        // A format Vie reads but doesn't offer (UTF-32) stays available as it is; tag -1.
        let offered = TextEncoding.all.firstIndex { $0.encoding == format.encoding && $0.hasBOM == format.hasBOM }
        if offered == nil {
            let item = NSMenuItem(title: format.encodingName, action: nil, keyEquivalent: "")
            item.tag = -1
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for (k, choice) in TextEncoding.all.enumerated() {
            if choice.encoding == .windowsCP1252 || choice.encoding == .shiftJIS { menu.addItem(.separator()) }
            let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            item.tag = k
            menu.addItem(item)
        }
        encodingPopUp.selectItem(withTag: offered ?? -1)
        for ending in LineEnding.allCases {
            lineEndingPopUp.addItem(withTitle: WorkspaceWindowController.lineEndingTitle(ending))
        }
        lineEndingPopUp.selectItem(at: LineEnding.allCases.firstIndex(of: format.lineEnding) ?? 0)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Encoding:"), encodingPopUp],
            [NSTextField(labelWithString: "Line Endings:"), lineEndingPopUp],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
        ])
        let size = grid.fittingSize
        box.frame = NSRect(x: 0, y: 0, width: size.width + 40, height: size.height + 24)
        view = box
    }

    /// The format chosen.
    var format: TextFormat {
        var format = original
        let tag = encodingPopUp.selectedTag()
        if TextEncoding.all.indices.contains(tag) {
            format.encoding = TextEncoding.all[tag].encoding
            format.hasBOM = TextEncoding.all[tag].hasBOM
        }
        let k = lineEndingPopUp.indexOfSelectedItem
        if LineEnding.allCases.indices.contains(k) { format.lineEnding = LineEnding.allCases[k] }
        return format
    }
}
