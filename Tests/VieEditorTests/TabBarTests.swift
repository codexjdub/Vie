import AppKit
import Testing
@testable import VieEditor

/// The tab bar's layout: tabs shrink to a minimum width, then the row scrolls sideways.
@MainActor
@Suite struct TabBarTests {
    private func bar(_ count: Int, title: (Int) -> String = { "a-rather-long-file-name-\($0).swift" }) -> TabBarView {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        bar.tabs = (0..<count).map { TabBarView.Tab(title: title($0), isDirty: false) }
        return bar
    }

    @Test func tabsShrinkThenTheRowScrolls() {
        let few = bar(3) { "f\($0).txt" }
        #expect(few.contentWidth <= 600 && few.scrollX == 0)
        #expect(few.tabRects().map(\.minX) == [0, few.tabWidths()[0], few.tabWidths()[0] + few.tabWidths()[1]])

        let many = bar(12)
        #expect(many.tabWidths().allSatisfy { $0 >= TabBarView.minimumTabWidth })
        #expect(many.contentWidth > 600 && many.scrollX == 0)
        many.selectedIndex = 11
        let last = many.tabRects()[11]
        #expect(many.scrollX > 0 && last.minX >= 0 && last.maxX <= 600.5)
        many.selectedIndex = 0
        #expect(many.scrollX == 0)
        many.scroll(to: 10_000)
        #expect(many.scrollX == many.contentWidth - 600)
        // Wider, the row no longer needs scrolling.
        many.setFrameSize(NSSize(width: many.contentWidth + 100, height: TabBarView.height))
        #expect(many.scrollX == 0)
    }

    /// A mouse wheel's up and down scroll the row sideways.
    @Test func wheelScrollsSideways() throws {
        let many = bar(12)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cg))
        many.scrollWheel(with: event)
        #expect(many.scrollX >= 3 * 40)
    }

    /// Where a dragged tab would land: past the middle of a tab goes after it.
    @Test func dropsLandBetweenTabs() {
        let few = bar(3) { "f\($0).txt" }
        let w = few.tabWidths()
        #expect(few.insertionIndex(at: 1) == 0)
        #expect(few.insertionIndex(at: w[0] / 2 + 1) == 1)
        #expect(few.insertionIndex(at: w[0] + w[1] - 1) == 2)
        #expect(few.insertionIndex(at: 599) == 3)
    }
}
