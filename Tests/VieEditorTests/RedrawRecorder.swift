import AppKit
import ObjectiveC
@testable import VieEditor

/// Records redraw requests (`setNeedsDisplay(_:)`) from the editor's views. They're final, so
/// each class gets its own `setNeedsDisplay(_:)` that logs and then does what NSView's does.
/// (A layer-backed view's `needsDisplay` isn't a reliable signal offscreen.)
@MainActor
enum RedrawRecorder {
    nonisolated(unsafe) private static var requests: [ObjectIdentifier: [NSRect]] = [:]

    private static let installed: Void = {
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

    /// Starts recording `view` afresh.
    static func reset(_ view: NSView) {
        _ = installed
        requests[ObjectIdentifier(view)] = nil
    }

    static func requests(_ view: NSView) -> [NSRect] { requests[ObjectIdentifier(view)] ?? [] }

    /// Whether `view` asked to redraw all of itself since `reset`.
    static func askedForFullRedraw(_ view: NSView) -> Bool {
        requests(view).contains { $0.contains(view.bounds) }
    }
}
