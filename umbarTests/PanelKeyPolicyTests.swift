//
//  PanelKeyPolicyTests.swift
//  umbarTests
//
//  Can B1, #98: which openings give the panel the keyboard and what closes
//  a key panel (AC-1.4 R1.2 exception, AC-1.16–AC-1.19).
//

import Testing

@Suite("PanelKeyPolicy")
struct PanelKeyPolicyTests {
    @Test(arguments: [PanelOpenSource.shortcut, .menu])
    func keyboardOpeningsTakeTheKeyboard(_ source: PanelOpenSource) {
        #expect(PanelKeyPolicy.takesKeyboard(openedBy: source))
    }

    @Test(arguments: [PanelOpenSource.hover, .pointer, .drag, .automatic])
    func pointerAndAutomaticOpeningsLeaveTheKeyboardAlone(_ source: PanelOpenSource) {
        #expect(!PanelKeyPolicy.takesKeyboard(openedBy: source))
    }

    @Test func pointerExitClosesOnlyANonKeyPanel() {
        #expect(PanelKeyPolicy.closesOnPointerExit(isKey: false))
        #expect(!PanelKeyPolicy.closesOnPointerExit(isKey: true))
    }

    @Test func shortcutOpensACompactPanel() {
        #expect(PanelKeyPolicy.shortcutAction(isOpen: false, isKey: false) == .openWithKeyboard)
    }

    @Test func shortcutOnAHoverPanelTakesTheKeyboardInsteadOfClosing() {
        #expect(PanelKeyPolicy.shortcutAction(isOpen: true, isKey: false) == .takeKeyboard)
    }

    @Test func shortcutAgainClosesAKeyPanel() {
        #expect(PanelKeyPolicy.shortcutAction(isOpen: true, isKey: true) == .close)
    }

    @Test func outsideClickClosesAKeyPanel() {
        #expect(PanelKeyPolicy.closesOnResignKey(wasKey: true, newKeyWindowIsPanelChild: false))
    }

    @Test func aPopoverFromThePanelDoesNotCloseIt() {
        #expect(!PanelKeyPolicy.closesOnResignKey(wasKey: true, newKeyWindowIsPanelChild: true))
    }

    @Test func resignKeyOfANonKeyPanelIsIgnored() {
        #expect(!PanelKeyPolicy.closesOnResignKey(wasKey: false, newKeyWindowIsPanelChild: false))
    }

    @Test func commandDigitsMapToTheFixedPages() {
        let expected: [(UInt16, PanelPage)] = [
            (18, .now), (19, .shelf), (20, .calendar), (21, .network), (23, .tools),
        ]
        for (code, page) in expected {
            #expect(PanelKeyPolicy.page(forKeyCode: code, commandOnly: true) == page)
        }
        #expect(PanelPage.allCases.map(\.rawValue) == [1, 2, 3, 4, 5])
    }

    @Test func digitsWithOtherModifiersAreNotPanelKeys() {
        #expect(PanelKeyPolicy.page(forKeyCode: 18, commandOnly: false) == nil)
    }

    @Test(arguments: [UInt16(22), 25, 26, 28, 29, 0])
    func otherKeysAreNotPanelPages(_ code: UInt16) {
        // 22 is the 6 key; 25/26/28/29 are 9/7/8/0; 0 is A.
        #expect(PanelKeyPolicy.page(forKeyCode: code, commandOnly: true) == nil)
    }

    @Test func bareEscapeCloses() {
        #expect(PanelKeyPolicy.isClose(keyCode: 53, noModifiers: true))
        #expect(!PanelKeyPolicy.isClose(keyCode: 53, noModifiers: false))
        #expect(!PanelKeyPolicy.isClose(keyCode: 36, noModifiers: true))
    }
}
