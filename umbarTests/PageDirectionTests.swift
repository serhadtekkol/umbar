//
//  PageDirectionTests.swift
//  umbarTests
//
//  The open panel's page change slides toward the tab you picked: a tab to
//  the right brings its page in from the right, one to the left from the left.
//

import Testing

@Suite("PageDirection", .timeLimit(.minutes(1)))
struct PageDirectionTests {
    /// The tab bar's order: Şimdi, Raf, Takvim, Ağ, Araçlar.
    let tabs = ["now", "shelf", "calendar", "network", "tools"]

    @Test func aTabToTheRightComesInFromTheRight() {
        #expect(PageDirection.between("now", "shelf", in: tabs) == .forward)
        #expect(PageDirection.between("network", "tools", in: tabs) == .forward)
        #expect(PageDirection.between("now", "tools", in: tabs) == .forward)
    }

    @Test func aTabToTheLeftComesInFromTheLeft() {
        #expect(PageDirection.between("shelf", "now", in: tabs) == .backward)
        #expect(PageDirection.between("tools", "network", in: tabs) == .backward)
        #expect(PageDirection.between("tools", "now", in: tabs) == .backward)
    }

    @Test func thereAndBackAreMirrorImages() {
        for (a, b) in zip(tabs, tabs.dropFirst()) {
            #expect(PageDirection.between(a, b, in: tabs).sign == -PageDirection.between(b, a, in: tabs).sign)
        }
    }

    @Test func signIsTheSlideFactor() {
        #expect(PageDirection.forward.sign == 1)
        #expect(PageDirection.backward.sign == -1)
    }

    @Test func theSamePageStaysForward() {
        #expect(PageDirection.between("calendar", "calendar", in: tabs) == .forward)
    }

    /// A page missing from the order (its tab was turned off) sits where the
    /// panel falls back to: the first tab.
    @Test func aMissingPageCountsAsTheFirst() {
        let withoutShelf = ["now", "calendar", "network", "tools"]
        #expect(PageDirection.between("shelf", "network", in: withoutShelf) == .forward)
        #expect(PageDirection.between("tools", "shelf", in: withoutShelf) == .backward)
    }
}
