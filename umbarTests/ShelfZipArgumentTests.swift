//
//  ShelfZipArgumentTests.swift
//  umbarTests
//
//  Card #47: the shelf's "compress" action passes the dropped file's name to
//  /usr/bin/zip as an argument. A name starting with "-" was read as an
//  option ("-T" tests the archive instead of adding the file; "-TT<cmd>"
//  names the command used for that test) instead of as a file to archive.
//

import Foundation
import Testing

@Suite("TemporaryFileStorageService.createZip argument handling")
struct ShelfZipArgumentTests {
    /// Names of the archive's entries, via `zipinfo -1`.
    private static func entries(of archive: URL) throws -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        proc.arguments = ["-1", archive.path]
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        proc.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }

    private static func removeArchive(_ url: URL?) {
        if let url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    @Test(arguments: ["-T", "-q", "--help"])
    func fileNamedLikeAnOptionIsArchived(_ name: String) async throws {
        let dir = try ScratchDir()
        let file = dir.url.appendingPathComponent(name)
        try Data("payload".utf8).write(to: file)

        let archive = await TemporaryFileStorageService.shared.createZip(from: [file])
        defer { Self.removeArchive(archive) }

        let url = try #require(archive, "zip must archive a file named \(name)")
        #expect(try Self.entries(of: url) == [name])
    }

    /// "-TT<cmd>" names the command zip runs to test the archive. A file
    /// name cannot hold "/", but zip runs in the file's folder, so a relative
    /// command would land its marker there. The name must stay just a file,
    /// and the command must not run.
    @Test func commandInANameDoesNotRun() async throws {
        let dir = try ScratchDir()
        let marker = dir.url.appendingPathComponent("ran")
        let file = dir.url.appendingPathComponent("-TTtouch ran")
        try Data("payload".utf8).write(to: file)

        let archive = await TemporaryFileStorageService.shared.createZip(from: [file])
        defer { Self.removeArchive(archive) }

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let url = try #require(archive)
        #expect(try Self.entries(of: url) == [file.lastPathComponent])
    }

    @Test func folderNamedLikeAnOptionIsArchivedWithItsContents() async throws {
        let dir = try ScratchDir()
        let folder = dir.url.appendingPathComponent("-r", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: folder.appendingPathComponent("inner.txt"))

        let archive = await TemporaryFileStorageService.shared.createZip(from: [folder])
        defer { Self.removeArchive(archive) }

        let url = try #require(archive)
        #expect(try Set(Self.entries(of: url)) == ["-r/", "-r/inner.txt"])
    }
}
