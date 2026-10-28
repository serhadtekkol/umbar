//
//  CapturePrivacyPolicy.swift
//  boringNotch
//
//  Muhittin L5: the clipboard history (Pano) must not reach a screen share
//  or a recording. While it is on screen the notch window is excluded from
//  capture whatever "Hide from screen recording" says; when it leaves, the
//  user's setting applies again. Foundation only, so umbarTests can compile
//  it without AppKit.
//

import Foundation

enum CapturePrivacyPolicy {
    /// How long the window stays excluded after the last sensitive view
    /// left. The view is removed when the panel starts to close, but it is
    /// still drawn while it fades and the island folds over it
    /// (UmbarMotion.contentOut, .close: about 0.36 s), so the window is not
    /// shared again until that has finished.
    static let restoreDelay: TimeInterval = 0.5

    /// Whether the notch window is excluded from screen capture.
    static func excludesFromCapture(userHides: Bool, sensitiveOnScreen: Bool) -> Bool {
        userHides || sensitiveOnScreen
    }
}

/// How many views that must not be captured are on screen. A count, not a
/// flag: during a page change the leaving and arriving views overlap, and
/// the arriving one appears before the leaving one disappears.
struct SensitiveContentTally: Equatable {
    private(set) var count = 0

    var isShowing: Bool { count > 0 }

    mutating func appear() { count += 1 }

    /// Never below zero: an unmatched disappear must not hide a later appear.
    mutating func disappear() { count = max(0, count - 1) }
}
