import AppKit

public extension NSView {
    /// Fades a view that just appeared in, quickly (at once if the Mac is set to reduce
    /// motion), as popovers do. Hiding stays instant, so nothing waits on it.
    func fadeIn(over duration: TimeInterval = 0.12) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = 1
            return
        }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            animator().alphaValue = 1
        }
    }
}
