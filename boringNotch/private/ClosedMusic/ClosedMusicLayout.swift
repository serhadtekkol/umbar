//
//  ClosedMusicLayout.swift
//  boringNotch
//
//  Pure rules for the music ears on the closed island: how wide they are
//  (album art and the song name on the left, the spectrum on the right) and
//  when they are there at all. ContentView draws them; nothing here
//  imports SwiftUI, so the numbers can be tested.
//
//  The island is centred on the camera, so the ears stay symmetric: the
//  song name widens the left ear and the right ear widens by the same
//  amount, the spectrum staying at its outer edge. Nothing is ever drawn
//  under the physical notch.
//

import CoreGraphics
import Foundation

enum ClosedMusicLayout {
    /// The song name's slot in the left ear. Fixed, not fitted to the
    /// name, so the island does not change width on every track change; a
    /// longer name scrolls (or, under Reduce Motion, is cut off).
    static let titleWidth: CGFloat = 96
    /// Between the album art and the song name.
    static let titleGap: CGFloat = 6
    /// Between an ear and the black over the notch (the HStack's spacing
    /// before the name existed).
    static let earGap: CGFloat = 8
    /// Inset of the album art and spectrum from the island's height.
    static let artInset: CGFloat = 12

    /// The album art's (and the spectrum ear's) side for a closed height.
    static func artSide(notchHeight: CGFloat) -> CGFloat {
        max(0, notchHeight - artInset)
    }

    /// Whether the left ear carries the song name: the setting is on, there
    /// is a name, there is an island to draw it in, and the inline sneak
    /// peek (which shows the name over the notch itself) is not up.
    static func showsTitle(enabled: Bool, title: String, notchHeight: CGFloat, inlinePeekShowing: Bool) -> Bool {
        enabled && notchHeight > 0 && !inlinePeekShowing
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Width the name adds to each ear (the right one mirrors the left).
    static func titleExtra(showsTitle: Bool) -> CGFloat {
        showsTitle ? titleWidth + titleGap : 0
    }

    /// What the music ears add to the closed notch's width, at `presence`
    /// (0 folded into the notch, 1 fully out). The chin, the critter and
    /// the eye-break banner read this; the drawn island and its hover rect
    /// are measured and come out the same.
    static func earsWidth(notchHeight: CGFloat, showsTitle: Bool, presence: CGFloat = 1) -> CGFloat {
        let p = min(max(presence, 0), 1)
        let ears = 2 * artSide(notchHeight: notchHeight) + 20 + 2 * titleExtra(showsTitle: showsTitle)
        return ears * p
    }
}

/// When the closed island shows the music ears. Playing shows them at
/// once; a pause takes them away `hideDelay` later, unless playback comes
/// back first. Only the closed island reads this: the open panel and the
/// media inactivity timeout (`isPlayerIdle`) are left as they are.
struct ClosedMusicPresence: Equatable {
    /// How long a pause waits before the ears fold: long enough that a
    /// quick pause/play or a track change does not flicker, short enough
    /// to read as the answer to the pause.
    static let hideDelay: TimeInterval = 0.6

    enum Step: Equatable {
        case none
        /// Bring the ears out now.
        case enter
        /// Call `hideDue(token:)` with this token after `hideDelay`.
        case scheduleHide(token: Int)
    }

    private(set) var shown: Bool
    private(set) var generation = 0

    init(playing: Bool) {
        shown = playing
    }

    mutating func playbackChanged(isPlaying: Bool) -> Step {
        generation += 1
        if isPlaying {
            guard !shown else { return .none }
            shown = true
            return .enter
        }
        return shown ? .scheduleHide(token: generation) : .none
    }

    /// True when the ears should fold now; false for a hide that a later
    /// play (or pause) has made stale.
    mutating func hideDue(token: Int) -> Bool {
        guard token == generation, shown else { return false }
        shown = false
        return true
    }
}
