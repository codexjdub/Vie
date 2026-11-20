import AppKit
import VieText

/// Mouse selection, scroll wheel, scrollbars, pointer and context menu.
extension EditorView {
    enum Granularity { case character, word, line }

    public override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= charWidth * 3
            dy *= lineHeight * 3
        }
        // Follow the dominant axis so vertical trackpad scrolling doesn't drift sideways.
        if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
        scrollX -= dx
        scrollY -= dy
        clampScroll()
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let axis = scrollbar(at: p) {
            draggingScrollbar = axis
            dragScrollbar(axis, to: p)
            return
        }
        if marked != nil {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        buffer.breakUndoCoalescing()

        let hit = offset(at: p)
        let s = buffer.selection
        let inGutter = p.x < gutterWidth
        let granularity: Granularity = event.clickCount >= 3 || inGutter ? .line : event.clickCount == 2 ? .word : .character
        let anchor: Range<Int>
        if event.modifierFlags.contains(.shift) {
            // Extend from the end of the selection farther from the click.
            let a = hit < s.lowerBound ? s.upperBound : hit > s.upperBound ? s.lowerBound : s.anchor
            anchor = a..<a
        } else {
            anchor = range(at: hit, granularity)
        }
        extendSelection(from: anchor, to: hit, granularity)
        trackSelection(from: anchor, granularity)
    }

    public override func mouseDragged(with event: NSEvent) {
        if let axis = draggingScrollbar { dragScrollbar(axis, to: convert(event.locationInWindow, from: nil)) }
    }

    public override func mouseUp(with event: NSEvent) { draggingScrollbar = nil }

    private func range(at off: Int, _ granularity: Granularity) -> Range<Int> {
        switch granularity {
        case .character: off..<off
        case .word: rope.wordRange(at: off)
        case .line: rope.lineRange(at: off)
        }
    }

    /// Selects from the anchor range to the unit (character, word, line) at `hit`.
    private func extendSelection(from anchor: Range<Int>, to hit: Int, _ granularity: Granularity) {
        let r = range(at: hit, granularity)
        let s = r.lowerBound < anchor.lowerBound
            ? Selection(anchor: anchor.upperBound, head: r.lowerBound)
            : Selection(anchor: anchor.lowerBound, head: max(r.upperBound, anchor.upperBound))
        buffer.selection = s
        goalX = nil
        vimSelectionChanged()
        needsDisplay = true
    }

    /// Follows the mouse until it's released, scrolling when it leaves the view.
    private func trackSelection(from anchor: Range<Int>, _ granularity: Granularity) {
        guard let window else { return }
        NSEvent.startPeriodicEvents(afterDelay: 0.05, withPeriod: 0.03)
        defer { NSEvent.stopPeriodicEvents() }
        var point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if event.type == .leftMouseUp { break }
            if event.type == .leftMouseDragged {
                point = convert(event.locationInWindow, from: nil)
            } else if !autoscroll(toward: point) {
                continue
            }
            extendSelection(from: anchor, to: offset(at: point), granularity)
            displayIfNeeded()
        }
    }

    /// Scrolls toward a point outside the text area. Returns false if the point is inside.
    private func autoscroll(toward p: NSPoint) -> Bool {
        var dx: CGFloat = 0, dy: CGFloat = 0
        if p.y < 0 { dy = p.y } else if p.y > bounds.height { dy = p.y - bounds.height }
        if p.x < textX && scrollX > 0 { dx = p.x - textX } else if p.x > bounds.width - scrollbarWidth { dx = p.x - bounds.width + scrollbarWidth }
        guard dx != 0 || dy != 0 else { return false }
        scrollX += dx
        scrollY += dy
        clampScroll()
        needsDisplay = true
        return true
    }

    // MARK: - Scrollbars

    private func scrollbar(at p: NSPoint) -> ScrollbarAxis? {
        if p.x >= bounds.width - scrollbarWidth && maxScrollY > 0 { return .vertical }
        if p.y >= bounds.height - scrollbarWidth && p.x > gutterWidth && maxScrollX > 0 { return .horizontal }
        return nil
    }

    private func dragScrollbar(_ axis: ScrollbarAxis, to p: NSPoint) {
        switch axis {
        case .vertical:
            let thumbH = verticalThumb.height
            let fraction = (p.y - thumbH / 2) / max(1, bounds.height - thumbH)
            scrollY = min(max(fraction, 0), 1) * maxScrollY
        case .horizontal:
            let thumbW = horizontalThumb.width
            let track = bounds.width - gutterWidth - scrollbarWidth
            let fraction = (p.x - gutterWidth - thumbW / 2) / max(1, track - thumbW)
            scrollX = min(max(fraction, 0), 1) * maxScrollX
        }
        needsDisplay = true
    }

    // MARK: - Pointer and context menu

    public override func resetCursorRects() {
        let width = max(0, bounds.width - gutterWidth - scrollbarWidth)
        addCursorRect(NSRect(x: gutterWidth, y: 0, width: width, height: bounds.height), cursor: .iBeam)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let hit = offset(at: convert(event.locationInWindow, from: nil))
        if !buffer.selection.range.contains(hit) || buffer.selection.isEmpty {
            buffer.breakUndoCoalescing()
            setSelection(Selection(hit), reveal: false)
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        return menu
    }
}
