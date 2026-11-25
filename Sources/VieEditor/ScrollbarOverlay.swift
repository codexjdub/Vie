import AppKit

/// The editor's scrollbars, drawn above the text in a layer of their own, so they can fade
/// without the text redrawing. Clicks go through to the editor, which drags them.
final class ScrollbarOverlay: NSView {
    /// What it draws, and the theme it drew in: it redraws only when either changes.
    var thumbs: [CGRect] = []
    var themeGeneration = -1

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Theme.scrollbar)
        for r in thumbs where r != .zero {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
        }
    }
}

extension EditorView {
    /// Scrollbars stay when the Mac is set to always show them (System Settings ▸ Appearance,
    /// or "Automatically" with a mouse); otherwise they show while scrolling and fade after.
    var scrollersAlwaysShown: Bool { scrollersAlwaysShownForTesting ?? (NSScroller.preferredScrollerStyle == .legacy) }

    /// Whether the scrollbars are showing (for tests): fully, or on their way out.
    public var scrollbarsShown: Bool { (scrollbarOverlay?.alphaValue ?? 0) > 0 }

    /// After each frame: the thumbs where the text now is, shown if the text scrolled.
    func updateScrollbars() {
        let overlay = scrollbarOverlay ?? {
            let made = ScrollbarOverlay(frame: bounds)
            made.autoresizingMask = [.width, .height]
            made.wantsLayer = true
            made.alphaValue = scrollersAlwaysShown ? 1 : 0
            addSubview(made)
            scrollbarOverlay = made
            return made
        }()
        let thumbs = [verticalThumb, horizontalThumb]
        if overlay.thumbs != thumbs || overlay.themeGeneration != Theme.generation {
            overlay.thumbs = thumbs
            overlay.themeGeneration = Theme.generation
            overlay.needsDisplay = true
        }
        let scroll = [CGFloat(top.line), CGFloat(top.row), topOffset, scrollX]
        if let last = lastScroll, last != scroll { showScrollbars() }
        lastScroll = scroll
    }

    /// Shows the scrollbars and, unless they always show, fades them out after
    /// `scrollbarFadeDelay` (not while one is being dragged).
    func showScrollbars() {
        guard let overlay = scrollbarOverlay else { return }
        scrollbarFade?.cancel()
        scrollbarFade = nil
        if overlay.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                overlay.animator().alphaValue = 1
            }
        }
        guard !scrollersAlwaysShown else { return }
        let fade = DispatchWorkItem { [weak self] in
            guard let self, let overlay = self.scrollbarOverlay, !self.scrollersAlwaysShown,
                  self.draggingScrollbar == nil else { return }
            self.scrollbarFade = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3
                overlay.animator().alphaValue = 0
            }
        }
        scrollbarFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + scrollbarFadeDelay, execute: fade)
    }

    /// The pointer near the right or bottom edge, where a scrollbar is.
    func isNearScrollbar(_ p: NSPoint) -> Bool {
        let reach = scrollbarWidth + 6
        return (p.x >= bounds.width - reach && canScrollVertically)
            || (p.y >= bounds.height - reach && p.x > gutterWidth && maxScrollX > 0)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if scrollbarTracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            scrollbarTracking = area
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if isNearScrollbar(convert(event.locationInWindow, from: nil)) { showScrollbars() }
    }

    /// The Mac's scrollbar setting changed: show them (and fade them if they now may).
    @objc func scrollerStyleChanged(_ note: Notification) {
        showScrollbars()
    }
}
