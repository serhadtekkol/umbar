//
//  QuickTogglesDefaults.swift
//  boringNotch
//
//  Defaults keys for F20 quick toggles. Kept out of Constants.swift like
//  CaffeinateDefaults.swift.
//

import Defaults

extension Defaults.Keys {
    /// Shows the quick toggles row on the "Now" page (AC-1.13 pattern: off
    /// removes the row). The row never prompts on its own, so it is safe to
    /// show by default.
    static let quickTogglesEnabled = Key<Bool>("quickTogglesEnabled", default: true)

    /// Name of the Shortcut the Focus tile runs. Empty until the user picks
    /// one; macOS has no public Focus setter, so this is the only route.
    static let quickTogglesFocusShortcut = Key<String>("quickTogglesFocusShortcut", default: "")
}
