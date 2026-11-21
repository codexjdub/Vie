import AppKit
import Testing
import VieText
@testable import VieEditor

/// The custom views redraw only when asked (layer-backed, `.onSetNeedsDisplay`), so they must
/// ask for a full redraw when their size changes. Otherwise a live resize draws only the
/// uncovered strip and leaves what was at the old edge behind: the scrollbar, the status bar's
/// right-aligned text, rows wrapped at the old width.
@MainActor
@Suite struct ResizeRedrawTests {
    @Test func viewsAskForAFullRedrawWhenTheirSizeChanges() {
        let editor = EditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), buffer: Buffer(rope: Rope("hello\n")))
        let status = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 22), editor: editor)
        let tabs = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        for view in [editor, status, tabs] as [NSView] {
            window.contentView?.addSubview(view)
            view.displayIfNeeded()
            for width in [600, 500] as [CGFloat] {
                RedrawRecorder.reset(view)
                view.setFrameSize(NSSize(width: width, height: view.frame.height))
                #expect(RedrawRecorder.askedForFullRedraw(view), "\(type(of: view)) at width \(width)")
            }
            RedrawRecorder.reset(view)
            view.setFrameSize(view.frame.size)
            #expect(RedrawRecorder.requests(view).isEmpty, "\(type(of: view)) redraws when its size didn't change")
        }
    }
}
