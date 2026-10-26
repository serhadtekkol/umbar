//
//  ShelfDropServiceTests.swift
//  umbarTests
//
//  AC-3.11: the shelf holds files only. Text, links and other non-file drags
//  must not become shelf items.
//

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite("ShelfDropService")
struct ShelfDropServiceTests {
    /// A provider that offers only raw bytes of one type, like a drag from an
    /// app that publishes no plain-text or file flavor.
    private static func dataOnlyProvider(_ type: UTType, _ data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// Writes a scratch file and removes it when the test ends.
    private static func withScratchFile(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbarTests-shelf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        try await body(file)
    }

    /// Drops that the service turns into a temporary file are cleaned up so the
    /// test leaves nothing in the temp directory.
    private static func removeTemporaryFiles(of items: [ShelfItem]) {
        for item in items where item.isTemporary {
            if let url = item.URL {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
    }

    @Test func fileURLBecomesOneNonTemporaryItem() async throws {
        try await Self.withScratchFile { file in
            let provider = try #require(NSItemProvider(contentsOf: file))
            let items = await ShelfDropService.items(from: [provider])
            #expect(items.count == 1)
            #expect(items.first?.isTemporary == false)
            #expect(items.first?.URL?.standardizedFileURL == file.standardizedFileURL)
        }
    }

    @Test(arguments: [
        "just some text",
        "Şüğ 😀 مرحبا",
    ])
    func plainTextIsRejected(_ text: String) async {
        let items = await ShelfDropService.items(from: [NSItemProvider(object: text as NSString)])
        #expect(items.isEmpty)
    }

    @Test func textThatLooksLikeAPathIsRejected() async throws {
        try await Self.withScratchFile { file in
            let items = await ShelfDropService.items(from: [NSItemProvider(object: file.path as NSString)])
            #expect(items.isEmpty, "a path typed as text is text, not a file")
        }
    }

    @Test func webLinkIsRejected() async throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let items = await ShelfDropService.items(from: [NSItemProvider(object: url as NSURL)])
        #expect(items.isEmpty)
    }

    @Test func nonTextDataBecomesOneTemporaryItem() async {
        let png = Self.dataOnlyProvider(.png, Data([0x89, 0x50, 0x4E, 0x47]))
        let items = await ShelfDropService.items(from: [png])
        defer { Self.removeTemporaryFiles(of: items) }
        #expect(items.count == 1)
        #expect(items.first?.isTemporary == true)
    }

    @Test func emptyDropYieldsNoItems() async {
        #expect(await ShelfDropService.items(from: []).isEmpty)
    }

    /// Rich text without a plain-text flavor still falls through to the data
    /// path and becomes a temp file. Fixed on feat/shelf-hud-bugs (883639e);
    /// remove the `withKnownIssue` wrapper when that lands, at which point
    /// Swift Testing reports this test as failing until you do.
    @Test(arguments: [
        (UTType.rtf, Data("{\\rtf1 hi}".utf8)),
        (UTType.html, Data("<b>hi</b>".utf8)),
    ])
    func richTextOnlyDragIsRejected(_ type: UTType, _ data: Data) async {
        let items = await ShelfDropService.items(from: [Self.dataOnlyProvider(type, data)])
        defer { Self.removeTemporaryFiles(of: items) }
        withKnownIssue("Card #60: rich text / HTML-only drags become temp files") {
            #expect(items.isEmpty)
        }
    }
}
