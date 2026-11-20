import AppKit
import VieEditor

/// The menu bar, built in code (no nib). Actions travel the responder chain: editing commands
/// reach the EditorView, document commands its window controller.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Vie", [
            item("About Vie", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Vie", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Vie", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("New Window", #selector(AppDelegate.newDocument(_:)), "n"),
            item("New Tab", #selector(WorkspaceWindowController.newTab(_:)), "t"),
            item("Open…", #selector(AppDelegate.openDocument(_:)), "o"),
            item("Open Quickly…", #selector(WorkspaceWindowController.openQuickly(_:)), "p"),
            .separator(),
            item("Close Tab", #selector(WorkspaceWindowController.closeTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            item("Save", #selector(WorkspaceWindowController.saveDocument(_:)), "s"),
            item("Save As…", #selector(WorkspaceWindowController.saveDocumentAs(_:)), "s", [.command, .shift]),
            item("Revert to Saved", #selector(WorkspaceWindowController.revertDocumentToSaved(_:))),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", #selector(EditorView.undo(_:)), "z"),
            item("Redo", #selector(EditorView.redo(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(EditorView.cut(_:)), "x"),
            item("Copy", #selector(EditorView.copy(_:)), "c"),
            item("Paste", #selector(EditorView.paste(_:)), "v"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            item("Shift Right", #selector(EditorView.shiftRight(_:)), "]"),
            item("Shift Left", #selector(EditorView.shiftLeft(_:)), "["),
            .separator(),
            item("Vim Mode", #selector(AppDelegate.toggleVimMode(_:))),
        ]))
        main.addItem(submenu("View", [
            item("Hide Sidebar", #selector(WorkspaceWindowController.toggleFileTree(_:)), "s", [.command, .control]),
        ]))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Next Tab", #selector(WorkspaceWindowController.selectNextTab(_:)), "]", [.command, .shift]),
            item("Show Previous Tab", #selector(WorkspaceWindowController.selectPreviousTab(_:)), "[", [.command, .shift]),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }
}
