//
//  ShelfItem.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Foundation

/// What a shelf item refers to. The shelf holds files only (AC-3.11).
///
/// The `{type, value}` wire format is kept from upstream, whose shelf also
/// stored `"text"` and `"link"` items. Those tags now fail to decode, and
/// `ShelfPersistenceService.load()` decodes item by item, so such entries in an
/// existing items.json are dropped while file items survive.
enum ShelfItemKind: Codable, Equatable, Sendable {
    case file(bookmark: Data)

    enum CodingKeys: String, CodingKey { case type, value }

    enum KindTag: String, Codable { case file }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(KindTag.self, forKey: .type)
        self = .file(bookmark: try container.decode(Data.self, forKey: .value))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let bookmark):
            try container.encode(KindTag.file, forKey: .type)
            try container.encode(bookmark, forKey: .value)
        }
    }

}

@MainActor
struct ShelfItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: ShelfItemKind
    var isTemporary: Bool
    init(id: UUID = UUID(), kind: ShelfItemKind, isTemporary: Bool = false) {
        self.id = id
        self.kind = kind
        self.isTemporary = isTemporary
    }
    
    var displayName: String {
        switch kind {
        case .file(let bookmarkData):
            let bookmark = Bookmark(data: bookmarkData)
            guard let resolvedURL = bookmark.resolveURL() else { return "" }
            
            return (try? resolvedURL.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? resolvedURL.lastPathComponent
        }
    }
    
    var fileURL: URL? {
        guard case .file = kind else { return nil }
        return ShelfStateViewModel.shared.resolveFileURL(for: self)
    }
    
    var URL: URL? {
        if case let .file(bookmark) = kind { return resolvedContext(for: bookmark)?.url }
        return nil
    }
    
    var icon: NSImage {
        guard case .file = kind else {
            return Self.thumbnailSymbolImage(systemName: kind.iconSymbolName) ?? NSImage()
        }
        if let resolvedURL = ShelfStateViewModel.shared.resolveFileURL(for: self) {
            return NSWorkspace.shared.icon(forFile: resolvedURL.path)
        }
        return NSImage()
    }
    

    func cleanupStoredData() {
        guard case let .file(bookmark) = kind,
              let context = resolvedContext(for: bookmark) else { return }
        
        let url = context.url
        
        // Handle temporary files
        if isTemporary {
            TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url)
            return
        }
    }
}

private extension ShelfItem {
   static func thumbnailSymbolImage(
        systemName: String,
    size: CGSize = CGSize(width: 64, height: 80), 
    symbolPointSize: CGFloat = 38,
    backgroundColor: NSColor = NSColor.white,
    symbolColor: NSColor = NSColor.labelColor
    ) -> NSImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = CGRect(origin: .zero, size: size)
        let cornerRadius = min(size.width, size.height) * 0.06
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: cornerRadius, yRadius: cornerRadius)
        backgroundColor.setFill()
        path.fill()

        if let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) {
            let symbolSize = CGSize(width: symbolPointSize, height: symbolPointSize)
            let symbolOrigin = CGPoint(
                x: (size.width - symbolSize.width) / 2,
                y: (size.height - symbolSize.height) / 2
            )
            let symbolRect = CGRect(origin: symbolOrigin, size: symbolSize)
            symbol.draw(in: symbolRect)
        }

        return image
    }
}

// MARK: - Identity key for deduplication
extension ShelfItem {
    var identityKey: String {
        switch kind {
        case .file(let bookmark):
            if let url = resolvedContext(for: bookmark)?.url {
                return "file://" + url.standardizedFileURL.path
            }
            return "file://missing/" + bookmark.base64EncodedString()
        }
    }
}

// MARK: - Private helpers
private extension ShelfItemKind {
    var iconSymbolName: String {
        switch self {
        case .file:
            return "questionmark.circle"
        }
    }
}

private extension ShelfItem {
    func resolvedContext(for bookmarkData: Data) -> (url: URL, bookmark: Data)? {
        let bookmark = Bookmark(data: bookmarkData)
        if let url = bookmark.resolveURL() {
            return (url, bookmark.refreshedData ?? bookmarkData)
        }
        return nil
    }
}
