//
//  sizeMatters.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

let shadowPadding: CGFloat = 20
/// design-language §4: one fixed size for every page (no layout shift when
/// the page changes). 640 × 190 fit neither five tabs beside the notch nor a
/// page body that is not crammed.
let openNotchSize: CGSize = .init(width: 600, height: 174)
let windowSize: CGSize = .init(width: openNotchSize.width, height: openNotchSize.height + shadowPadding)
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 14, bottom: 20), closed: (top: 6, bottom: 14))

/// The open panel's vertical rhythm inside `openNotchSize`: the header
/// (tab bar) on top, then the page, then the bottom inset. The page gets
/// what is left and never more: a page taller than that is clipped at the
/// island's bottom instead of pushing the header up (ContentView centres an
/// oversized island in its fixed frame, so overflow used to move the tab
/// bar and cut off the top of the selected capsule).
enum PanelLayout {
    /// Between the header and the page.
    static let headerSpacing: CGFloat = 5
    /// Left and right, on top of the corner-radius inset.
    static let sideInset: CGFloat = 12
    /// Under the page. More than the sides: the bottom corners make
    /// a tiny gap read as touching the edge.
    static let bottomInset: CGFloat = 10

    /// As tall as the notch, so the tab bar sits beside it, but never
    /// shorter than the tab bar itself: on a screen without a notch (or a
    /// hidden one) the notch height is 0 or the 24 pt menu bar, and a 28 pt
    /// capsule in a 24 pt row is cut off at the top of the screen.
    static func headerHeight(notchHeight: CGFloat) -> CGFloat {
        max(TabSelectionView.height, notchHeight)
    }
}

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 10.0, closed: 4.0)
    static let size = (opened: CGSize(width: 64, height: 64), closed: CGSize(width: 20, height: 20))
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}
