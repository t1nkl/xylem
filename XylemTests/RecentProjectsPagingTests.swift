//
//  RecentProjectsPagingTests.swift
//  XylemTests
//
//  Recent Projects shows a page of whole rows that fit on screen (at least
//  two); with more projects left the last cell is "Show more", so the grid
//  ends on a full row and no card sits alone.
//

import Testing
import CoreGraphics

struct RecentProjectsPagingTests {

    @Test func aPageThatHoldsEverythingHasNoButton() {
        let p = RecentProjectsPaging(total: 20, columns: 4, rows: 5)
        #expect(p.shownCards == 20)
        #expect(!p.hasMore)
        #expect(RecentProjectsPaging(total: 7, columns: 4, rows: 5).shownCards == 7)
    }

    @Test func moreProjectsLeaveTheLastCellForTheTile() {
        // A 1728x1005 window: 5 columns, 5 rows fit.
        let p = RecentProjectsPaging(total: 56, columns: 5, rows: 5)
        #expect(p.page == 25)
        #expect(p.hasMore)
        #expect(p.shownCards == 24)
        #expect(p.nextPageCards == 25)
    }

    @Test func showMoreAddsAPage() {
        let first = RecentProjectsPaging(total: 45, columns: 4, rows: 5)
        let second = RecentProjectsPaging(total: 45, columns: 4, rows: 5, cells: first.cells + first.page)
        #expect(second.shownCards == 39)          // 40 cells: 39 cards + tile
        #expect(second.hasMore)
        #expect(second.nextPageCards == 6)
        let third = RecentProjectsPaging(total: 45, columns: 4, rows: 5, cells: second.cells + second.page)
        #expect(third.shownCards == 45)
        #expect(!third.hasMore)
    }

    @Test func everyPageWithATileEndsOnAFullRow() {
        for columns in 1...8 {
            for rows in 1...8 {
                let p = RecentProjectsPaging(total: 500, columns: columns, rows: rows)
                #expect((p.shownCards + 1) % columns == 0)
            }
        }
    }

    @Test func resizeKeepsWhatWasOpenedOnWholePages() {
        // Opened two pages of 4 x 5 (40 cells), then the window shrank to 3 x 4.
        let p = RecentProjectsPaging(total: 500, columns: 3, rows: 4, cells: 40)
        #expect(p.cells == 48)                     // 4 pages of 12, not fewer than were open
        #expect((p.shownCards + 1) % 3 == 0)
    }

    @Test func columnCountMatchesTheAdaptiveGrid() {
        #expect(NewTabPickerView.columnCount(forWidth: 864) == 4)
        #expect(NewTabPickerView.columnCount(forWidth: 100) == 1)
        #expect(NewTabPickerView.columnCount(forWidth: 550) == 2)
        #expect(NewTabPickerView.columnCount(forWidth: 570) == 3)
    }

    @Test func rowCountIsWholeRowsWithAtLeastTwo() {
        // 106 pt cards + 10 pt spacing: 5 rows need 5*106 + 4*10 = 570 pt.
        #expect(NewTabPickerView.rowCount(forHeight: 570, cardHeight: 106) == 5)
        #expect(NewTabPickerView.rowCount(forHeight: 569, cardHeight: 106) == 4)
        #expect(NewTabPickerView.rowCount(forHeight: 50, cardHeight: 106) == 2)
        #expect(NewTabPickerView.rowCount(forHeight: 900, cardHeight: 0) == 2)   // not measured yet
    }
}
