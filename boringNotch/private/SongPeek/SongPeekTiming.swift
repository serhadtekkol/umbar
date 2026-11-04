//
//  SongPeekTiming.swift
//  boringNotch
//
//  Pure rules for how long the song name stays under the closed island when
//  the track changes (Settings › Media › Sneak peek duration). Only the music
//  sneak peek reads this; the volume and brightness HUD keep their own time.
//

import Foundation

enum SongPeekTiming {
    static let range: ClosedRange<Double> = 1...10
    static let step: Double = 0.5

    /// 3 s, not upstream's 1.5 s: the sneak peek is a marquee that waits 1 s
    /// before it scrolls at 30 pt/s, so in 1.5 s a title wider than the
    /// island never gets past its first few letters. 3 s is also what the
    /// inline style and the sneak peek shortcut already use.
    static let defaultSeconds: Double = 3

    /// A stored value brought into the slider's range and onto its steps;
    /// anything unreadable (NaN, infinity) falls back to the default.
    static func seconds(_ stored: Double) -> Double {
        guard stored.isFinite else { return defaultSeconds }
        let snapped = (stored / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}
