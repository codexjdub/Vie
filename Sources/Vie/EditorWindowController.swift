import AppKit
import VieEditor
import VieText

/// One window showing one file. M3 replaces this with workspace windows (tree + tabs).
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorView: EditorView
    let fileURL: URL?
    var onClose: ((EditorWindowController) -> Void)?

    /// True for an empty window nobody has typed into, which opening a file may replace.
    var isUntouchedUntitled: Bool { fileURL == nil && !editorView.isModified }

    init(rope: Rope, url: URL?, size: NSSize) {
        fileURL = url
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = url?.lastPathComponent ?? "Untitled"
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 200)
        editorView = EditorView(frame: rect, rope: rope)
        window.contentView = editorView
        super.init(window: window)
        window.delegate = self
        window.makeFirstResponder(editorView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}
