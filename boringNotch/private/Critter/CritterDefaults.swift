//
//  CritterDefaults.swift
//  boringNotch
//
//  Defaults keys for the idle critter. Kept out of Constants.swift on
//  purpose to avoid merge conflicts.
//

import Defaults
import Foundation

extension CritterFrequency: Defaults.Serializable {}
extension CritterChoice: Defaults.Serializable {}

extension Defaults.Keys {
    /// On by default (the user asked for it). Settings > Appearance.
    static let critterEnabled = Key<Bool>("critterEnabled", default: true)
    static let critterFrequency = Key<CritterFrequency>("critterFrequency", default: .sometimes)
    static let critterChoice = Key<CritterChoice>("critterChoice", default: .mixed)
    /// Off by default: with music the island is the player, not a playground.
    static let critterWhileMusic = Key<Bool>("critterWhileMusic", default: false)
}
