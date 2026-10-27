//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

// Global shortcut defaults (DEC-21 as changed by the user on 2026-10-26,
// AC-1.22). A fresh install gets exactly one global shortcut, the panel
// toggle; everything else starts unassigned and is set in Settings >
// Shortcuts. A default only applies until the user records or clears one.
//
// Why ⌃⇧⌘Space for the panel, checked against Apple's "Mac keyboard
// shortcuts" (support.apple.com/102650, macOS 27) and common apps:
// - Space family taken: ⌘Space Spotlight, ⌥⌘Space Finder search,
//   ⌃Space / ⌃⌥Space input sources, ⌃⌘Space Character Viewer,
//   ⇧⌘Space Siri about the active window (macOS 27) and 1Password Quick
//   Access, ⌥Space Raycast / Alfred / ChatGPT / Claude, ⌃⇧Space JetBrains
//   smart completion. ⌃⇧⌘Space is in none of these; macOS matches global
//   shortcuts on the exact modifier set, so it does not collide with
//   ⌃⌘Space.
// - No ⌃⌥: that pair is the VoiceOver modifier, and VO-⌘-<letter> is
//   VoiceOver's attribute navigation. The panel's main keyboard audience
//   includes VoiceOver users (AC-1.21).
// - No ⇧⌘<letter>: Finder's Go menu holds most of them (⌘⇧I iCloud
//   Drive, ⌘⇧C Computer, ⌘⇧H Home: the upstream defaults collided here,
//   Can B1).
// - Space is the largest key and needs no layout lookup; it is the same
//   physical key on the Turkish Q, Turkish F, US and AZERTY layouts.
// It cannot be proven free against every installed app (DEC-21 says so);
// the user can change or clear it in Settings.
extension KeyboardShortcuts.Name {
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.space, modifiers: [.control, .shift, .command]))

    // Upstream defaults ⌘⇧C and ⌘⇧H run Finder's Go > Computer / Go > Home
    // (AC-1.22); none of these get a default.
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel")
    static let toggleSneakPeek = Self("toggleSneakPeek")

    // Declared but never registered as hot keys (no onKeyDown handler), so
    // they are not global shortcuts; kept as upstream left them.
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
}
