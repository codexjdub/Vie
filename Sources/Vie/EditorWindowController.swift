import AppKit
import VieEditor
import VieText
import VieWorkspace

/// One window showing one document. M3 replaces this with workspace windows (tree + tabs).
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let textDocument: Document
    let editorView: EditorView
    var onClose: ((EditorWindowController) -> Void)?
    private var closeConfirmed = false
    private var diskAlertShowing = false

    var fileURL: URL? { textDocument.fileURL }

    /// True for an empty window nobody has typed into, which opening a file may replace.
    var isUntouchedUntitled: Bool {
        textDocument.fileURL == nil && !textDocument.buffer.canUndo && textDocument.buffer.rope.isEmpty
    }

    init(document: Document, size: NSSize) {
        self.textDocument = document
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 200)
        editorView = EditorView(frame: rect, buffer: document.buffer)
        editorView.indentation = textDocument.indentation
        window.contentView = editorView
        super.init(window: window)
        window.delegate = self
        window.makeFirstResponder(editorView)
        textDocument.buffer.addObserver(self) { [weak self] _ in self?.updateEditedState() }
        textDocument.onDiskChange = { [weak self] in self?.handleDiskChange() }
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateTitle() {
        guard let window else { return }
        window.title = textDocument.displayName
        window.representedURL = textDocument.fileURL
        var subtitle = textDocument.format == .utf8 ? "" : textDocument.format.description
        if textDocument.hadMixedLineEndings { subtitle += (subtitle.isEmpty ? "" : " · ") + "mixed line endings" }
        window.subtitle = subtitle
        updateEditedState()
    }

    /// Runs after every edit, so it only touches the window when the state flips.
    private func updateEditedState() {
        let dirty = textDocument.isDirty
        if let window, window.isDocumentEdited != dirty { window.isDocumentEdited = dirty }
    }

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed || !textDocument.isDirty { return true }
        Task {
            if await confirmClose() {
                closeConfirmed = true
                window?.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        textDocument.close()
        onClose?(self)
    }

    /// Asks whether to save unsaved changes. Returns true when it's fine to close: the
    /// textDocument was saved, or the user chose not to save.
    func confirmClose() async -> Bool {
        guard textDocument.isDirty, let window else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(textDocument.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.hasDestructiveAction = true
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: return await save(as: false)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: - Saving

    @objc func saveDocument(_ sender: Any?) { Task { await save(as: false) } }
    @objc func saveDocumentAs(_ sender: Any?) { Task { await save(as: true) } }

    @objc func revertDocumentToSaved(_ sender: Any?) { reloadFromDisk() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(revertDocumentToSaved(_:)): textDocument.fileURL != nil && textDocument.isDirty
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)): !textDocument.isSaving
        default: true
        }
    }

    /// Saves, asking for a location if the textDocument is untitled (or for Save As). Returns
    /// false if the user cancelled or the save failed (the error has been shown).
    @discardableResult
    func save(as saveAs: Bool) async -> Bool {
        guard let window, !textDocument.isSaving else { return false }
        var url = textDocument.fileURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = textDocument.fileURL?.lastPathComponent ?? "Untitled.txt"
            if let dir = textDocument.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
            guard await panel.beginSheetModal(for: window) == .OK, let chosen = panel.url else { return false }
            url = chosen
        }
        guard let url else { return false }
        do {
            try await textDocument.save(to: url)
        } catch TextFileError.unrepresentable(let encoding) {
            guard await askToSaveAsUTF8(encoding) else { return false }
            do {
                try await textDocument.save(to: url, format: TextFormat(encoding: .utf8, lineEnding: textDocument.format.lineEnding))
            } catch {
                await present(error)
                return false
            }
        } catch {
            await present(error)
            return false
        }
        updateTitle()
        return true
    }

    private func askToSaveAsUTF8(_ encoding: String.Encoding) async -> Bool {
        guard let window else { return false }
        let name = String.localizedName(of: encoding)
        let alert = NSAlert()
        alert.messageText = "“\(textDocument.displayName)” can’t be saved as \(name)."
        alert.informativeText = "The text contains characters that \(name) can’t store. Save it as UTF-8 instead?"
        alert.addButton(withTitle: "Save as UTF-8")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    private func present(_ error: Error) async {
        guard let window else { return }
        _ = await NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: - Changes on disk

    func windowDidBecomeKey(_ notification: Notification) {
        // A backstop for the file watcher: check whenever the user comes back to the window.
        handleDiskChange()
    }

    /// Reloads silently if there are no unsaved edits; otherwise asks.
    private func handleDiskChange() {
        guard textDocument.checkDisk() == .changed else { return }
        if !textDocument.isDirty {
            reloadFromDisk()
            return
        }
        guard !diskAlertShowing, let window else { return }
        diskAlertShowing = true
        let alert = NSAlert()
        alert.messageText = "“\(textDocument.displayName)” was changed by another app."
        alert.informativeText = "Reloading replaces your unsaved changes with the version on disk. You can get them back with Undo."
        alert.addButton(withTitle: "Keep My Version")
        alert.addButton(withTitle: "Reload")
        Task {
            let response = await alert.beginSheetModal(for: window)
            diskAlertShowing = false
            if response == .alertSecondButtonReturn { reloadFromDisk() }
        }
    }

    private func reloadFromDisk() {
        do {
            try textDocument.reload()
            updateTitle()
        } catch {
            Task { await present(error) }
        }
    }
}
