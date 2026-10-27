//
//  ScreenshotShelfPolicy.swift
//  umbar
//
//  F16: the pure rules for "is this new file a screenshot, and is it
//  finished?". Foundation only so umbarTests can compile it without the app.
//

import Foundation

enum ScreenshotShelfPolicy {
    /// Extension-level kinds macOS writes for captures.
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "gif", "pdf"]
    private static let recordingExtensions: Set<String> = ["mov"]

    /// Name prefixes macOS uses, per UI language. The system localizes the
    /// prefix, so a Turkish Mac writes "Ekran Resmi 2026-..." (older macOS:
    /// "Ekran Görüntüsü"), and "Screen Shot ..." was the English form before
    /// macOS Mojave. Name matching is only the fallback: the capture xattr is
    /// preferred because it works in every language and cannot be spoofed by
    /// a download that happens to be called "Screenshot".
    private static let imagePrefixes = ["Screenshot", "Screen Shot", "Ekran Resmi", "Ekran Görüntüsü"]
    private static let recordingPrefixes = ["Screen Recording", "Ekran Kaydı"]

    /// Name of the extended attribute macOS sets on files made by screencapture.
    static let captureAttributeName = "com.apple.metadata:kMDItemIsScreenCapture"

    enum Verdict: Equatable {
        case accept
        case ignore
    }

    /// Whether `name` is a temporary file: screencapture writes
    /// ".Screenshot ...png" first and renames it when the capture is done.
    static func isTemporaryName(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasSuffix(".tmp") || name.hasSuffix(".part")
    }

    /// Decides whether a finished-looking file belongs on the shelf.
    ///
    /// - Parameters:
    ///   - hasCaptureAttribute: the file carries kMDItemIsScreenCapture.
    ///     `nil` means the attribute is not (yet) readable; the name decides.
    static func classify(name: String, hasCaptureAttribute: Bool?, includeRecordings: Bool) -> Verdict {
        if isTemporaryName(name) { return .ignore }
        let ext = (name as NSString).pathExtension.lowercased()
        let isImage = imageExtensions.contains(ext)
        let isRecording = recordingExtensions.contains(ext)
        guard isImage || (isRecording && includeRecordings) else { return .ignore }

        if hasCaptureAttribute == true { return .accept }
        // The attribute is written a moment after the rename. If it is
        // explicitly absent we still accept a system-looking name, since the
        // attribute can be missing on captures made by third-party tools.
        // NFC: APFS may hand back decomposed "ü", the table above is composed.
        let normalized = name.precomposedStringWithCanonicalMapping
        let prefixes = isRecording ? recordingPrefixes : imagePrefixes
        let matches = prefixes.contains { normalized.hasPrefix($0.precomposedStringWithCanonicalMapping) }
        return matches ? .accept : .ignore
    }

    /// Resolves the folder macOS saves captures to. `configured` is the
    /// `location` value of com.apple.screencapture (may be nil, empty or "~/...").
    static func resolveLocation(configured: String?, home: URL) -> URL {
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return desktop
        }
        let expanded: String
        if raw == "~" {
            expanded = home.path
        } else if raw.hasPrefix("~/") {
            expanded = home.path + "/" + raw.dropFirst(2)
        } else {
            expanded = raw
        }
        guard expanded.hasPrefix("/") else { return desktop }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
}

/// Decides when a candidate file has stopped growing. A file is complete once
/// two consecutive observations agree on size and modification date and the
/// size is non-zero. Value type: the owner feeds it from a timer.
struct ScreenshotStabilityTracker {
    struct Snapshot: Equatable {
        let size: Int64
        let modified: Date
    }

    private var last: [String: Snapshot] = [:]
    private var attempts: [String: Int] = [:]
    let maxAttempts: Int

    init(maxAttempts: Int = 40) {
        self.maxAttempts = maxAttempts
    }

    enum Outcome: Equatable {
        case pending
        case stable
        case giveUp
    }

    mutating func observe(_ name: String, snapshot: Snapshot?) -> Outcome {
        guard let snapshot else {
            forget(name)
            return .giveUp
        }
        let count = (attempts[name] ?? 0) + 1
        attempts[name] = count
        if snapshot.size > 0, last[name] == snapshot {
            forget(name)
            return .stable
        }
        last[name] = snapshot
        if count >= maxAttempts {
            forget(name)
            return .giveUp
        }
        return .pending
    }

    mutating func forget(_ name: String) {
        last[name] = nil
        attempts[name] = nil
    }
}
