//
//  PageDirection.swift
//  boringNotch
//
//  Which side a new page comes in from. Pure, so the umbarTests bundle
//  compiles it without the views: PanelPageView asks it with the tab order
//  (PanelTab.all), the tests with any list.
//

import CoreGraphics

enum PageDirection: Equatable {
    /// The new tab is to the right of the old one: the page comes in from
    /// the right and the leaving page goes out to the left.
    case forward
    /// The new tab is to the left: the mirror image.
    case backward

    /// +1 forward, -1 backward: the factor on the slide offset.
    var sign: CGFloat { self == .forward ? 1 : -1 }

    /// The direction from `old` to `new` in `order` (the tab bar, left to
    /// right). A page that is not in the order (turned off, or not a tab)
    /// counts as the first one, where the panel falls back to. Same page:
    /// forward, so a re-selection never flips a page mid-flight.
    static func between<T: Equatable>(_ old: T, _ new: T, in order: [T]) -> PageDirection {
        let from = order.firstIndex(of: old) ?? 0
        let to = order.firstIndex(of: new) ?? 0
        return to >= from ? .forward : .backward
    }
}
