import AppKit
import ObjectiveC
import Testing
import VieText
@testable import VieEditor

/// The custom views redraw only when asked (layer-backed, `.onSetNeedsDisplay`), so they must
/// ask for a full redraw when their size changes. Otherwise a live resize draws only the
/// uncovered strip and leaves what was at the old edge behind: the scrollbar, the status bar's
/// right-aligned text, rows wrapped at the old width.
@MainActor
@Suite struct ResizeRedrawTests {
    /// Redraw requests (`setNeedsDisplay(_:)`) by view.
    nonisolated(unsafe) private static var requests: [ObjectIdentifier: [NSRect]] = [:]

    /// The views are final, so their requests are recorded by giving each class its own
    /// `setNeedsDisplay(_:)` that logs and then does what NSView's does.
    private static let recording: Void = {
        let selector = #selector(NSView.setNeedsDisplay(_:))
        let method = class_getInstanceMethod(NSView.self, selector)!
        typealias Imp = @convention(c) (NSView, Selector, NSRect) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Imp.self)
        let log: @convention(block) (NSView, NSRect) -> Void = { view, rect in
            requests[ObjectIdentifier(view), default: []].append(rect)
            original(view, selector, rect)
        }
        for cls in [EditorView.self, StatusBarView.self, TabBarView.self] as [AnyClass] {
            class_replaceMethod(cls, selector, imp_implementationWithBlock(log), method_getTypeEncoding(method))
        }
    }()

    @Test func viewsAskForAFullRedrawWhenTheirSizeChanges() {
        _ = Self.recording
        let editor = EditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), buffer: Buffer(rope: Rope("hello\n")))
        let status = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 22), editor: editor)
        let tabs = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        for view in [editor, status, tabs] as [NSView] {
            window.contentView?.addSubview(view)
            view.displayIfNeeded()
            for width in [600, 500] as [CGFloat] {
                Self.requests[ObjectIdentifier(view)] = nil
                view.setFrameSize(NSSize(width: width, height: view.frame.height))
                let asked = Self.requests[ObjectIdentifier(view)] ?? []
                #expect(asked.contains { $0.contains(view.bounds) }, "\(type(of: view)) at width \(width)")
            }
            Self.requests[ObjectIdentifier(view)] = nil
            view.setFrameSize(view.frame.size)
            #expect(Self.requests[ObjectIdentifier(view)] == nil, "\(type(of: view)) redraws when its size didn't change")
        }
    }
}
