//
//  ShelfStateViewModelStub.swift
//  umbarTests
//
//  This bundle compiles the shelf model and drop service from the app's
//  sources instead of loading the app (see scripts/test.sh). ShelfItem
//  reaches for ShelfStateViewModel.shared, whose real implementation pulls in
//  the whole shelf UI and persistence; this stand-in provides the one member
//  ShelfItem uses. If ShelfItem starts using more of it, this file is where
//  the build will say so.
//

import Foundation

@MainActor
final class ShelfStateViewModel {
    static let shared = ShelfStateViewModel()

    func resolveFileURL(for item: ShelfItem) -> URL? { item.URL }
}
