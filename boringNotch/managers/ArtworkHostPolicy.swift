//
//  ArtworkHostPolicy.swift
//  boringNotch
//
//  Kept apart from ImageService so the rule can be compiled into the unit
//  test bundle without ImageService's Defaults dependency (card #56).
//

import Foundation

/// Which artwork URLs the app may download.
enum ArtworkHostPolicy {
    /// Spotify serves `artwork url` from its image CDN (`i.scdn.co` today).
    /// Apple Music artwork arrives as bytes over AppleScript and needs no host.
    static let allowedHostSuffixes = ["scdn.co", "spotifycdn.com"]

    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
