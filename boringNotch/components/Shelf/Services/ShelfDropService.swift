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


// MARK: - Dragging items out of the shelf (BR-3.5)
//
// The rules for drags that leave the shelf live here, next to the rules for
// drags that arrive, because umbarTests compiles a fixed list of app sources
// and this file is on it. A file of their own under boringNotch/private/ would
// only be compiled into the app target until the project file grows a
// membership exception for it.
// TODO(emrullah): move this section to boringNotch/private/Shelf/ once a
// project-file change is in scope — see toolbarcakmasi-95.
//
// Who does what: umbar never copies, moves or deletes the user's file when it
// leaves the shelf. It only chooses which operations to *offer*; the
// destination (Finder, Mail, ...) performs the file operation. That is what
// keeps a cross-volume move safe: Finder copies first and removes the source
// only after the copy completed, exactly as for a ⌘-drag between disks in
// Finder itself, and umbar adds no deletion of its own that could run early.

/// What lies under the pointer of an outgoing shelf drag, as far as the
/// operation mask is concerned.
enum ShelfDragDestination: Equatable, Sendable {
    /// One of umbar's own windows (the shelf, the notch panel).
    case ownApp
    /// A Finder window or the Finder desktop.
    case finder
    /// Anything else: Mail, a browser upload field, the Dock, another app.
    case other
}

/// What happens to the dragged shelf items once the drag session ended.
enum ShelfDragEndAction: Equatable, Sendable {
    /// Leave the items on the shelf.
    case keep
    /// Remove the items now. Used for copies: the original stays where it
    /// was, so there is nothing left to confirm.
    case remove
    /// Remove each item only once its file has left the original path. A
    /// destination reports a move when the drop is accepted, before it has
    /// done the work, and the work can still fail or be stopped (disk full,
    /// "Stop" in Finder's name-conflict dialog: AC-3.17, AC-3.18).
    case removeOnceSourceLeaves
}

/// One visible window, reduced to what `ShelfDragOutPolicy.destination` needs.
struct ShelfDragWindow: Equatable, Sendable {
    let ownerPID: pid_t
    let ownerBundleID: String?
    /// The Quartz window level (`kCGWindowLayer`).
    let layer: Int
    /// Bounds in Quartz global coordinates: origin at the top left of the
    /// primary display, y grows downwards.
    let bounds: CGRect
    let alpha: Double
}

/// Device and inode of a file, used to tell "the file is still here" from
/// "something else now has the same name".
struct ShelfFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    /// Reads the identity of whatever is at `path` without following a
    /// trailing symlink, or returns nil if nothing is there.
    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
    }

    init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// A dragged shelf item's file as it was when the drag started.
struct ShelfDragSource: Equatable, Sendable {
    let path: String
    let identity: ShelfFileIdentity

    init(path: String, identity: ShelfFileIdentity) {
        self.path = path
        self.identity = identity
    }

    /// Reads the file at `url`, or returns nil if nothing is there.
    init?(url: URL) {
        guard let identity = ShelfFileIdentity(path: url.path) else { return nil }
        self.init(path: url.path, identity: identity)
    }
}

/// The pure part of dragging items out of the shelf: which operations to offer
/// and what to do with the items afterwards. See BR-3.5 in docs/spec.md.
enum ShelfDragOutPolicy {
    static let finderBundleID = "com.apple.finder"

    /// Window level of the drag image (`kCGDraggingWindowLevel`). Everything
    /// at or above it (the drag image, the cursor, login-window shields that
    /// cover the whole desktop) is never what the pointer is "over".
    static let draggingWindowLevel = 500

    /// The operations the drag offers to `destination`.
    ///
    /// - Parameters:
    ///   - destination: what is under the pointer right now.
    ///   - optionKeyHeld: ⌥ is down. Forces a copy everywhere (AC-3.14).
    ///   - copyOnDrag: the user's "copy on drag" setting. Forces a copy
    ///     everywhere, as it did before move became the default.
    ///   - sourcesDeletable: every dragged file can be removed from where it
    ///     is. When one cannot (read-only volume, no permission), Finder gets
    ///     a copy instead of a move it would fail halfway through (AC-3.20).
    ///     The mask covers the whole session, so one undeletable file turns
    ///     the whole multi-item drag into a copy.
    ///
    /// Finder is offered `.move` alone: when a source offers both copy and
    /// move, Finder picks copy when the destination is on another volume, and BR-3.5
    /// wants a move regardless of the volume (AC-3.12). Everyone else is
    /// offered both, because Mail, browsers and the Dock accept only a copy
    /// or pick it themselves (AC-3.13); the Dock's Trash picks the move.
    ///
    /// Never empty when ⌥ is down: AppKit intersects this mask with the
    /// modifier (⌥ → copy), so a Finder mask of `.move` alone would turn an
    /// ⌥-drop into a refused one.
    static func operationMask(
        destination: ShelfDragDestination,
        optionKeyHeld: Bool,
        copyOnDrag: Bool,
        sourcesDeletable: Bool
    ) -> NSDragOperation {
        if copyOnDrag || optionKeyHeld { return [.copy] }
        switch destination {
        case .ownApp:
            return [.copy, .move, .generic]
        case .finder:
            return sourcesDeletable ? [.move] : [.copy]
        case .other:
            return [.copy, .move]
        }
    }

    /// What to do with the dragged items after the session ended with
    /// `operation`.
    ///
    /// - Parameters:
    ///   - operation: what the destination accepted; empty for a cancelled
    ///     or refused drop (AC-3.15).
    ///   - lastDestination: where the pointer was when the drop happened. A
    ///     drop back onto umbar's own panel never removes anything (AC-3.15),
    ///     even though the panel accepts it.
    ///   - autoRemove: the "remove from shelf after drop" setting. Off keeps
    ///     everything (AC-3.16).
    static func endAction(
        operation: NSDragOperation,
        lastDestination: ShelfDragDestination,
        autoRemove: Bool
    ) -> ShelfDragEndAction {
        guard autoRemove, !operation.isEmpty, lastDestination != .ownApp else { return .keep }
        if !operation.intersection([.move, .delete]).isEmpty {
            return .removeOnceSourceLeaves
        }
        return .remove
    }

    /// Whether a file that was dragged out with a move has left its original
    /// path: nothing is there any more, or something with a different
    /// identity is (the user recreated a file with the same name).
    static func sourceHasLeft(original: ShelfFileIdentity, now: ShelfFileIdentity?) -> Bool {
        now != original
    }

    /// Classifies the front-most window under `point` (Quartz coordinates).
    ///
    /// - Parameter windows: on-screen windows, front to back, as
    ///   `CGWindowListCopyWindowInfo` returns them.
    /// - Parameter ownPID: umbar's process. Its windows are skipped: AppKit
    ///   already reports drags over umbar's drop targets as "within the
    ///   application", so an own window seen here is a transparent part of
    ///   the notch window that does not take the drop.
    static func destination(at point: CGPoint, windows: [ShelfDragWindow], ownPID: pid_t) -> ShelfDragDestination {
        for window in windows {
            guard window.layer < draggingWindowLevel,
                  window.alpha > 0,
                  window.ownerPID != ownPID,
                  window.bounds.contains(point) else { continue }
            return window.ownerBundleID == finderBundleID ? .finder : .other
        }
        return .other
    }

    /// Converts an AppKit screen point (origin at the bottom left of the
    /// primary screen) to Quartz global coordinates (origin at its top left).
    static func quartzPoint(fromAppKit point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}

/// Removes a shelf item once its file has left the original path after a move
/// (`ShelfDragEndAction.removeOnceSourceLeaves`).
///
/// Polls with `lstat` instead of holding a file descriptor or a file
/// presenter: an open descriptor on a file on an external disk keeps the disk
/// from ejecting, which is exactly what a user may want to do next.
///
/// The wait is bounded. Fast polls cover the common case (a same-volume move
/// is a rename, so the item leaves well inside AC-3.3's one second); slow
/// polls cover a long cross-volume copy. When the budget runs out the item
/// stays: if the move did complete later, the item shows "not found"
/// (AC-3.8) and can be removed by hand; the file itself is never touched.
@MainActor
final class ShelfMoveOutcomeWatcher {
    typealias Probe = @Sendable (String) -> ShelfFileIdentity?
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// 10 × 200 ms, then 1 s up to ten minutes in total.
    nonisolated static let defaultSchedule: [Duration] =
        Array(repeating: .milliseconds(200), count: 10) + Array(repeating: .seconds(1), count: 598)

    private let schedule: [Duration]
    private let probe: Probe
    private let sleep: Sleep
    private var tasks: [UUID: (generation: UInt64, task: Task<Void, Never>)] = [:]
    private var nextGeneration: UInt64 = 0

    init(
        schedule: [Duration] = ShelfMoveOutcomeWatcher.defaultSchedule,
        probe: @escaping Probe = { ShelfFileIdentity(path: $0) },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.schedule = schedule
        self.probe = probe
        self.sleep = sleep
    }

    /// Item IDs that are still being watched.
    var watchedIDs: Set<UUID> { Set(tasks.keys) }

    /// Calls `onLeft` once the file at `path` has left (see
    /// `ShelfDragOutPolicy.sourceHasLeft`). Watching an ID again replaces the
    /// earlier watch for it.
    ///
    /// - Returns: the polling task, so tests can await it.
    @discardableResult
    func watch(id: UUID, path: String, original: ShelfFileIdentity, onLeft: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        tasks[id]?.task.cancel()
        nextGeneration += 1
        let generation = nextGeneration
        let schedule = schedule, probe = probe, sleep = sleep
        let task = Task { @MainActor [weak self] in
            defer { self?.finish(id, generation: generation) }
            for delay in schedule {
                do { try await sleep(delay) } catch { return }
                if Task.isCancelled { return }
                if ShelfDragOutPolicy.sourceHasLeft(original: original, now: probe(path)) {
                    onLeft()
                    return
                }
            }
        }
        tasks[id] = (generation, task)
        return task
    }

    /// Stops watching `id`, e.g. because the user removed the item by hand.
    func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.task.cancel()
    }

    /// Unregisters a finished watch, unless a newer watch for the same ID has
    /// replaced it in the meantime.
    private func finish(_ id: UUID, generation: UInt64) {
        if tasks[id]?.generation == generation {
            tasks[id] = nil
        }
    }
}
