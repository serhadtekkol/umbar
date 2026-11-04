//
//  PanelKeyPolicy.swift
//  boringNotch
//
//  When the notch panel takes the keyboard, and what closes it (Can B1,
//  #98; spec AC-1.4 (R1.2) exception, AC-1.16–AC-1.22, DEC-21).
//  Foundation only, so umbarTests can compile it without AppKit.
//

import Foundation

/// How the panel came to be open. The source decides whether the panel
/// takes the keyboard; nothing else does.
enum PanelOpenSource: Equatable {
    /// The pointer rested on the notch (AC-1.1).
    case hover
    /// A click or a downward swipe on the notch.
    case pointer
    /// A drag entered the notch region (opens on the shelf).
    case drag
    /// umbar opened it on its own: the eye-break prompt, the HUD access card.
    case automatic
    /// The global panel shortcut (AC-1.18).
    case shortcut
    /// "Open panel" in the menu bar extra (AC-1.20).
    case menu
}

/// The pages behind ⌘1…⌘6, in tab order. A number stays with its page when
/// another page is turned off (AC-1.19); a page that is off is a key the
/// panel swallows and does nothing with, so it never leaks to the app behind.
enum PanelPage: Int, CaseIterable {
    case now = 1
    case shelf = 2
    case calendar = 3
    case network = 4
    case tools = 5
    case mirror = 6
}

/// What the panel shortcut does in a given state (AC-1.18).
enum PanelShortcutAction: Equatable {
    /// Panel compact: open it with the keyboard.
    case openWithKeyboard
    /// Panel open from a hover or click: keep it open and give it the keyboard.
    case takeKeyboard
    /// Panel already holds the keyboard: pressing again closes it.
    case close
}

enum PanelKeyPolicy {
    /// A hover-, click-, drag- or umbar-opened panel must not take the
    /// keyboard: with it key, ⌘2 meant for Safari would switch the panel's
    /// page instead (AC-1.16). Only an explicit keyboard request does.
    static func takesKeyboard(openedBy source: PanelOpenSource) -> Bool {
        switch source {
        case .shortcut, .menu: true
        case .hover, .pointer, .drag, .automatic: false
        }
    }

    /// The 500 ms pointer-exit close applies only while the panel does not
    /// hold the keyboard. A key panel is being typed into or was opened by
    /// someone who may not be using the pointer at all; it stays until Esc,
    /// an outside click, or the shortcut again (AC-1.4 R1.2 exception).
    static func closesOnPointerExit(isKey: Bool) -> Bool {
        !isKey
    }

    /// AC-1.18. A hover-open panel does not close on the shortcut; it takes
    /// the keyboard, since the person reaching for the shortcut wants to use
    /// the panel they already see.
    static func shortcutAction(isOpen: Bool, isKey: Bool) -> PanelShortcutAction {
        guard isOpen else { return .openWithKeyboard }
        return isKey ? .close : .takeKeyboard
    }

    /// Losing key status closes a key panel (an outside click activates
    /// another app), unless the window that took the keyboard is one of
    /// the panel's own children: a popover or picker opened from the panel
    /// must not fold the panel under it.
    static func closesOnResignKey(wasKey: Bool, newKeyWindowIsPanelChild: Bool) -> Bool {
        wasKey && !newKeyWindowIsPanelChild
    }

    // MARK: Keys handled inside a key panel

    /// Virtual key codes of the top-row 1…6 keys. Physical positions, not
    /// characters: on AZERTY the digits need Shift, and Safari, Finder and
    /// Xcode all bind ⌘1… by position on those layouts too.
    static let digitKeyCodes: [UInt16: PanelPage] = [
        18: .now, 19: .shelf, 20: .calendar, 21: .network, 23: .tools, 22: .mirror,
    ]

    /// kVK_Escape.
    static let escapeKeyCode: UInt16 = 53

    /// The page for ⌘<digit>, or nil if the key is not ⌘1…⌘6. Only ⌘ alone
    /// counts: ⌘⇧1 or ⌥⌘1 are someone else's shortcuts.
    static func page(forKeyCode keyCode: UInt16, commandOnly: Bool) -> PanelPage? {
        guard commandOnly else { return nil }
        return digitKeyCodes[keyCode]
    }

    /// Esc with no modifiers closes a key panel (AC-1.5, AC-1.18).
    static func isClose(keyCode: UInt16, noModifiers: Bool) -> Bool {
        noModifiers && keyCode == escapeKeyCode
    }
}
