import AppKit
import VieEditor

/// The menu bar, built in code (no nib). Actions travel the responder chain: editing commands
/// reach the EditorView, document commands its window controller.
@MainActor
enum MainMenu {
    /// `recent` is File ▸ Open Recent's menu (an empty one in tests).
    static func build(recent: NSMenu = NSMenu(title: "Open Recent")) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Vie", [
            item("About Vie", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
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
            submenu("Open Recent", recent),
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
            submenu("Find", [
                item("Find…", #selector(WorkspaceWindowController.showFindBar(_:)), "f"),
                item("Find and Replace…", #selector(WorkspaceWindowController.showFindAndReplace(_:)), "f", [.command, .option]),
                item("Find Next", #selector(WorkspaceWindowController.findNextMatch(_:)), "g"),
                item("Find Previous", #selector(WorkspaceWindowController.findPreviousMatch(_:)), "g", [.command, .shift]),
                item("Use Selection for Find", #selector(WorkspaceWindowController.useSelectionForFind(_:)), "e"),
            ]),
            .separator(),
            item("Shift Right", #selector(EditorView.shiftRight(_:)), "]"),
            item("Shift Left", #selector(EditorView.shiftLeft(_:)), "["),
            .separator(),
            item("Vim Mode", #selector(AppDelegate.toggleVimMode(_:)), "v", [.command, .control]),
        ]))
        main.addItem(submenu("View", [
            item("Hide Sidebar", #selector(WorkspaceWindowController.toggleFileTree(_:)), "s", [.command, .control]),
            .separator(),
            item("Wrap Lines", #selector(AppDelegate.toggleWrapLines(_:)), "l", [.command, .option]),
            .separator(),
            item("Increase Font Size", #selector(AppDelegate.increaseFontSize(_:)), "+"),
            hidden(item("Increase Font Size", #selector(AppDelegate.increaseFontSize(_:)), "=")),
            item("Decrease Font Size", #selector(AppDelegate.decreaseFontSize(_:)), "-"),
            item("Reset Font Size", #selector(AppDelegate.resetFontSize(_:)), "0"),
        ]))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Next Tab", #selector(WorkspaceWindowController.showNextTab(_:)), "]", [.command, .shift]),
            item("Show Previous Tab", #selector(WorkspaceWindowController.showPreviousTab(_:)), "[", [.command, .shift]),
        ] + numberedTabs() + [
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        // As the help menu, it gets the system's search field, which finds any menu command.
        let help = submenu("Help", [
            item("Vie Help", #selector(AppDelegate.showVieHelp(_:)), "?"),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    /// ⌘1–⌘9 pick a tab. Hidden, as in Safari: holding ⌘ shows the numbers on the tabs.
    private static func numberedTabs() -> [NSMenuItem] {
        (1...9).map { n in
            let tab = hidden(item("Show Tab \(n)", #selector(WorkspaceWindowController.showTabNumber(_:)), "\(n)"))
            tab.tag = n
            return tab
        }
    }

    /// A menu item that isn't shown but keeps its key equivalent (⌘= next to ⌘+, say).
    private static func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        return submenu(title, menu)
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
