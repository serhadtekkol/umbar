//
//  ShelfDropService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-26.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfDropService {
    static func items(from providers: [NSItemProvider]) async -> [ShelfItem] {
        var results: [ShelfItem] = []

        for provider in providers {
            if let item = await processProvider(provider) {
                results.append(item)
            }
        }

        return results
    }
    
    private static func processProvider(_ provider: NSItemProvider) async -> ShelfItem? {
        if let actualFileURL = await provider.extractFileURL() {
            if let bookmark = createBookmark(for: actualFileURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
            return nil
        }
        
        if let url = await provider.extractURL() {
            if url.isFileURL {
                if let bookmark = createBookmark(for: url) {
                    return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
                }
            }
            // Web links are not shelf items (AC-3.11).
            return nil
        }

        // Dragged text also conforms to public.data; check it before the data
        // fallback so a text selection is rejected instead of becoming a file.
        if isTextOnlyDrop(registeredTypeIdentifiers: provider.registeredTypeIdentifiers) {
            return nil
        }
        
        if let data = await provider.loadData() {
            if let tempDataURL = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: provider.suggestedName)),
               let bookmark = createBookmark(for: tempDataURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
            }
            return nil
        }
        
        if let fileURL = await provider.extractItem() {
            if let bookmark = createBookmark(for: fileURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
        }
        
        return nil
    }
    
    /// Decides whether a drag that carries no file URL is a text drag (AC-3.11).
    ///
    /// Checks conformance to `public.text` rather than only `public.plain-text`:
    /// apps that drag rich text or HTML without a plain-text flavor (RTF,
    /// HTML, ...) would otherwise fall through to the raw-data fallback and be
    /// saved as a temp file (card #60). Callers must try file-URL extraction
    /// first; a Finder text file also advertises text types but is a file.
    ///
    /// Pure on purpose so it can be tested without constructing providers.
    static func isTextOnlyDrop(registeredTypeIdentifiers: [String]) -> Bool {
        registeredTypeIdentifiers.contains { identifier in
            UTType(identifier)?.conforms(to: .text) ?? false
        }
    }

    private static func createBookmark(for url: URL) -> Data? {
        return (try? Bookmark(url: url))?.data
    }
}

