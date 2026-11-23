import AppKit

/// File ▸ Open Recent: recent files and folders, newest first, then Clear Menu. The list is the
/// system's (`NSDocumentController`'s), which the Dock icon's menu shows too. The items are made
/// each time the menu opens, so launching pays nothing for them.
@MainActor
final class RecentMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Open Recent")
    private let urls: () -> [URL]
    private let onOpen: (URL) -> Void
    private let onClear: () -> Void

    /// `urls` gives the list, newest first.
    init(urls: @escaping () -> [URL], open: @escaping (URL) -> Void, clear: @escaping () -> Void) {
        self.urls = urls
        self.onOpen = open
        self.onClear = clear
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    /// The system's list, as many as the "Recent documents" setting allows.
    static func system(open: @escaping (URL) -> Void) -> RecentMenu {
        RecentMenu(urls: { NSDocumentController.shared.recentDocumentURLs }, open: open,
                   clear: { NSDocumentController.shared.clearRecentDocuments(nil) })
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = urls().filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        for (url, title) in zip(urls, Self.titles(for: urls)) {
            let item = NSMenuItem(title: title, action: #selector(openItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            // macOS 27 hides menu item images unless asked; a folder's or file's icon tells which it is.
            item.preferredImageVisibility = .visible
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clear(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpen(url)
    }

    @objc private func clear(_ sender: Any?) { onClear() }

    /// Each item's name; names that appear more than once get as much of their folder as tells
    /// them apart ("main.swift — tools", "main.swift — app/src").
    static func titles(for urls: [URL]) -> [String] {
        let names = urls.map(\.lastPathComponent)
        var titles = names
        for (name, indices) in Dictionary(grouping: names.indices, by: { names[$0] }) where indices.count > 1 {
            let folders = indices.map { Array(urls[$0].deletingLastPathComponent().pathComponents.dropFirst()) }
            for (k, folder) in folders.enumerated() {
                let others = folders.indices.filter { $0 != k }.map { folders[$0] }
                var depth = 1
                while depth < folder.count && others.contains(where: { $0.suffix(depth) == folder.suffix(depth) }) { depth += 1 }
                let shown = folder.suffix(depth).joined(separator: "/")
                titles[indices[k]] = shown.isEmpty ? name : "\(name) — \(shown)"
            }
        }
        return titles
    }
}
