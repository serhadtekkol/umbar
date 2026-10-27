//
//  ShelfDropService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-26.
//

import AppKit
import CoreServices
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
struct ShelfFileIdentity: Hashable, Sendable {
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
///
/// `identity` confirms a move (`ShelfMoveOutcomeWatcher`); the rest is the
/// fingerprint that recognises the file after a move to another volume, where
/// it is a new file with a new identity (`ShelfMoveDestinationLocator`).
struct ShelfDragSource: Equatable, Sendable {
    let path: String
    let identity: ShelfFileIdentity
    let isDirectory: Bool
    /// Bytes, for a regular file; 0 for a directory.
    let size: UInt64
    /// Content modification time, seconds since 1970.
    let modificationTime: TimeInterval

    var name: String { (path as NSString).lastPathComponent }

    init(path: String, identity: ShelfFileIdentity, isDirectory: Bool = false, size: UInt64 = 0, modificationTime: TimeInterval = 0) {
        self.path = path
        self.identity = identity
        self.isDirectory = isDirectory
        self.size = size
        self.modificationTime = modificationTime
    }

    /// Reads the file at `url` without following a trailing symlink, or
    /// returns nil if nothing is there.
    init?(url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        self.init(
            path: url.path,
            identity: ShelfFileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino)),
            isDirectory: isDirectory,
            size: isDirectory ? 0 : UInt64(max(info.st_size, 0)),
            modificationTime: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        )
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


// MARK: - Undoing a move out of the shelf (B2, card #100)
//
// After a confirmed move out of the shelf the item stays for a short window
// as a "ghost" with an Undo (ShelfMoveUndoModel), and Undo puts the file back
// at its original path. Same constraint as above: this lives here because
// umbarTests compiles this file (toolbarcakmasi-95).
//
// Finding where the file went.
// - Same volume: Finder's move is a rename and the item's bookmark follows
//   the file (measured on macOS 27.0.1: resolves, isStale = true). The
//   resolved path is accepted only if it has the dragged file's device and
//   inode.
// - Another volume: Finder copies, then deletes the source. The destination
//   is a new file and the bookmark no longer resolves (measured: resolution
//   fails). The drag source is never told the drop folder; NSDraggingSession
//   reports a screen point and an operation. Asking Finder (AppleScript
//   "insertion location", its selection) needs the Automation or
//   Accessibility permission and answers for the front window rather than
//   the one under the drop, so it is not used. Instead the shelf watches the
//   other writable volumes with FSEvents from the start of the drag
//   (ShelfMoveDestinationRecorder) and keeps only created or renamed paths
//   carrying the dragged name or Finder's "Keep Both" form of it
//   ("name 2.ext"). Once the move is confirmed, a candidate must also match
//   type, size and modification time (Finder's copy keeps the time) and be
//   the only match. Anything else leaves the ghost without Undo; it never
//   guesses.
// - Rejected: file promises (NSFilePromiseProvider does tell the source the
//   drop folder, but umbar would then perform the move itself, and Mail and
//   upload fields treat promises differently: a redesign of #93, not a
//   mitigation); Spotlight (external disks are often not indexed, and the
//   index lags); replaying FSEvents history from an event ID saved at drag
//   start (measured: a replay 0.5 s and 2 s after a move returned none of
//   its events, so the stream has to be live before the drop).
//
// Putting it back (ShelfMoveUndoer). Same device: renamex_np(RENAME_EXCL),
// atomic, and it fails rather than replace anything at the original path.
// Another device: copy to a hidden name next to the original, rename that
// into place with RENAME_EXCL, then move the destination copy to the Trash.
// When umbar itself takes a file away it uses FileManager.trashItem, never
// removeItem (Can B2 fix 1; Muhittin: a permanent delete on another disk is
// an integrity issue). A mistake stays recoverable from the Trash.
//
// Privacy: the FSEvents stream sees every file event on the watched volumes.
// Only paths with a dragged name are kept, in memory, for one drag, and none
// is logged.

/// Whether `name` could be what Finder called a dropped file named
/// `original`: the same name, or Finder's "Keep Both" rename of it ("report
/// 2.pdf", "Photos 3"). Swift's `==` compares canonically equivalent Unicode
/// as equal, so an NFC/NFD difference between volumes does not matter.
enum ShelfMoveDestinationNames {
    static func isCandidate(_ name: String, for original: String) -> Bool {
        if name == original { return true }
        let ext = (original as NSString).pathExtension
        let stem = (original as NSString).deletingPathExtension
        guard (name as NSString).pathExtension == ext else { return false }
        let nameStem = (name as NSString).deletingPathExtension
        guard nameStem.hasPrefix(stem + " ") else { return false }
        let number = nameStem.dropFirst(stem.count + 1)
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(number) else { return false }
        return n >= 2
    }
}

/// One mounted volume, reduced to what `ShelfMoveDestinationRecorder` needs.
struct ShelfVolume: Equatable, Sendable {
    let path: String
    let device: UInt64
    let isReadOnly: Bool

    /// The mounted volumes right now.
    static func mounted() -> [ShelfVolume] {
        let keys: [URLResourceKey] = [.volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return urls.compactMap { url in
            guard let identity = ShelfFileIdentity(path: url.path) else { return nil }
            let readOnly = (try? url.resourceValues(forKeys: Set(keys)))?.volumeIsReadOnly ?? true
            return ShelfVolume(path: url.path, device: identity.device, isReadOnly: readOnly)
        }
    }
}

/// Records, from the start of a drag, paths created or renamed on the other
/// volumes whose name could be a dragged file's (see the section comment).
///
/// Thread safety: `paths` is only touched on `queue`, where FSEvents delivers;
/// `stream` is guarded by `lock`, which is also held across a flush so `stop`
/// cannot invalidate the stream underneath it. The callback never takes the
/// lock, so the flush cannot deadlock on it.
final class ShelfMoveDestinationRecorder: @unchecked Sendable {
    /// More than this many matching paths in one drag means something is
    /// churning names like ours; the extra ones are dropped and the locator
    /// will find several candidates, i.e. no Undo, which is the safe side.
    static let maxRecordedPaths = 256

    fileprivate final class Collector: @unchecked Sendable {
        let names: [String]
        var paths: Set<String> = []

        init(names: [String]) { self.names = names }

        func receive(_ newPaths: [String], flags: UnsafePointer<FSEventStreamEventFlags>) {
            let interesting = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
            for (i, path) in newPaths.enumerated() where flags[i] & interesting != 0 {
                guard paths.count < ShelfMoveDestinationRecorder.maxRecordedPaths else { return }
                let name = (path as NSString).lastPathComponent
                if names.contains(where: { ShelfMoveDestinationNames.isCandidate(name, for: $0) }) {
                    paths.insert(path)
                }
            }
        }
    }

    private let queue = DispatchQueue(label: "umbar.shelf.move-destination")
    private let collector: Collector
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// The volumes a move of files on `sourceDevices` could land on: every
    /// writable volume, except system volumes and the one volume all sources
    /// share (a move there is a rename, which the bookmark follows).
    static func watchPaths(volumes: [ShelfVolume], sourceDevices: Set<UInt64>) -> [String] {
        volumes
            .filter { !$0.isReadOnly && !$0.path.hasPrefix("/System/Volumes/") }
            .filter { !(sourceDevices.count == 1 && sourceDevices.contains($0.device)) }
            .map(\.path)
    }

    /// Starts recording for a drag of `sources`, or returns nil when there is
    /// nothing to watch (no other writable volume) or FSEvents refused.
    static func forDrag(of sources: [ShelfDragSource], volumes: [ShelfVolume] = ShelfVolume.mounted()) -> ShelfMoveDestinationRecorder? {
        let paths = watchPaths(volumes: volumes, sourceDevices: Set(sources.map(\.identity.device)))
        return ShelfMoveDestinationRecorder(watching: paths, names: sources.map(\.name))
    }

    init?(watching paths: [String], names: [String]) {
        guard !paths.isEmpty, !names.isEmpty else { return nil }
        let collector = Collector(names: names)
        self.collector = collector
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(collector).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<ShelfMoveDestinationRecorder.Collector>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, shelfMoveDestinationCallback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags
        ) else {
            // The stream never took ownership of the retained collector.
            Unmanaged.passUnretained(collector).release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit { stop() }

    /// Delivers the events FSEvents has not handed over yet, then returns the
    /// paths recorded so far. Blocks briefly; call it off the main thread.
    func recordedPaths() -> [String] {
        lock.withLock {
            if let stream { FSEventStreamFlushSync(stream) }
        }
        return queue.sync { Array(collector.paths) }
    }

    /// Stops recording. Paths recorded so far stay readable.
    func stop() {
        lock.withLock {
            guard let stream else { return }
            self.stream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

private let shelfMoveDestinationCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    let collector = Unmanaged<ShelfMoveDestinationRecorder.Collector>.fromOpaque(info).takeUnretainedValue()
    // kFSEventStreamCreateFlagUseCFTypes: `paths` is a CFArray of CFString.
    let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
    collector.receive(Array(list.prefix(count)), flags: flags)
}

/// Where a moved file went, as far as umbar can tell.
enum ShelfMoveDestination: Equatable, Sendable {
    /// Found; `identity` is the file's identity there, so Undo can tell it
    /// is still the same file.
    case found(URL, identity: ShelfFileIdentity)
    /// No candidate: the destination is not on a watched volume, the
    /// recording could not start, or the file is already gone again.
    case notFound
    /// More than one file looks like the moved one. Undo would be a guess.
    case ambiguous(count: Int)
}

/// Finds where a file went after a confirmed move (see the section comment).
enum ShelfMoveDestinationLocator {
    /// Finder keeps the modification time when it copies, but FAT volumes
    /// store it in 2 s steps.
    static let modificationTimeTolerance: TimeInterval = 2

    /// - Parameters:
    ///   - source: the file as it was at drag start.
    ///   - bookmark: the shelf item's bookmark, which follows a same-volume move.
    ///   - recordedPaths: candidates from `ShelfMoveDestinationRecorder`.
    static func locate(source: ShelfDragSource, bookmark: Data?, recordedPaths: [String]) -> ShelfMoveDestination {
        if let bookmark, let url = resolveWithoutSideEffects(bookmark),
           url.path != source.path,
           ShelfFileIdentity(path: url.path) == source.identity {
            return .found(url, identity: source.identity)
        }

        var matches: [(URL, ShelfFileIdentity)] = []
        var seen: Set<ShelfFileIdentity> = []
        for path in Set(recordedPaths) where path != source.path {
            let url = URL(fileURLWithPath: path)
            guard ShelfMoveDestinationNames.isCandidate(url.lastPathComponent, for: source.name),
                  let candidate = ShelfDragSource(url: url),
                  candidate.identity.device != source.identity.device,
                  fingerprintsMatch(candidate, source),
                  seen.insert(candidate.identity).inserted else { continue }
            matches.append((url, candidate.identity))
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0].0, identity: matches[0].1)
        default: return .ambiguous(count: matches.count)
        }
    }

    /// `locate`, retried while FSEvents may still be delivering the
    /// destination's creation (it lags the file system by tens of ms, more
    /// under load).
    static func locate(
        source: ShelfDragSource,
        bookmark: Data?,
        recordedPaths: @Sendable () -> [String],
        retries: [Duration] = Array(repeating: .milliseconds(100), count: 5),
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> ShelfMoveDestination {
        var result = locate(source: source, bookmark: bookmark, recordedPaths: recordedPaths())
        for delay in retries {
            guard result == .notFound else { break }
            do { try await sleep(delay) } catch { break }
            result = locate(source: source, bookmark: bookmark, recordedPaths: recordedPaths())
        }
        return result
    }

    static func fingerprintsMatch(_ candidate: ShelfDragSource, _ source: ShelfDragSource) -> Bool {
        guard candidate.isDirectory == source.isDirectory else { return false }
        // A folder's size and times change while Finder fills it; its name
        // and the "only one candidate" rule have to do.
        if source.isDirectory { return true }
        return candidate.size == source.size
            && abs(candidate.modificationTime - source.modificationTime) <= modificationTimeTolerance
    }

    /// Resolves without UI and without mounting a volume: a bookmark to an
    /// unmounted disk must not make umbar mount it.
    private static func resolveWithoutSideEffects(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}

/// Why an Undo did not put the file back. In every case nothing was
/// overwritten and nothing was deleted; the file is where the move left it.
enum ShelfUndoFailure: Error, Equatable, Sendable {
    /// The moved file is no longer where it went.
    case destinationMissing
    /// Something else is at the destination now (replaced, or edited into a
    /// new file by an app that saves by replacing).
    case destinationChanged
    /// Something is at the original path again.
    case originalOccupied
    /// The original folder is gone.
    case originalFolderMissing
    /// macOS refused access, typically privacy protection for Desktop,
    /// Documents, Downloads, removable volumes or the Trash.
    case permissionDenied
    /// Copying back to the original volume failed (disk full, ejected).
    case copyFailed
    /// Any other error from the file system, as an errno.
    case fileSystem(errno: Int32)

    /// Stable, machine-readable code for UI copy and logs.
    var code: String {
        switch self {
        case .destinationMissing: "destination_missing"
        case .destinationChanged: "destination_changed"
        case .originalOccupied: "original_occupied"
        case .originalFolderMissing: "original_folder_missing"
        case .permissionDenied: "permission_denied"
        case .copyFailed: "copy_failed"
        case .fileSystem: "file_system_error"
        }
    }
}

/// What a successful Undo did.
enum ShelfUndoOutcome: Equatable, Sendable {
    /// The file is back at its original path and nowhere else.
    case restored
    /// The file is back at its original path, but its copy at the
    /// destination (another volume) could not be moved to the Trash and is
    /// still there.
    case restoredLeavingCopy(URL)
}

/// Moves a file back to where it was before a move out of the shelf, without
/// ever replacing or permanently deleting anything (see the section comment).
///
/// Synchronous and blocking (a cross-volume Undo copies the file); call it off
/// the main actor.
struct ShelfMoveUndoer: Sendable {
    typealias Trash = @Sendable (URL) throws -> Void
    typealias Copy = @Sendable (URL, URL) throws -> Void

    /// The only way umbar takes a file away: recoverable from the Trash.
    static let systemTrash: Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    static let systemCopy: Copy = { try FileManager.default.copyItem(at: $0, to: $1) }

    private let trash: Trash
    private let copy: Copy

    init(trash: @escaping Trash = ShelfMoveUndoer.systemTrash, copy: @escaping Copy = ShelfMoveUndoer.systemCopy) {
        self.trash = trash
        self.copy = copy
    }

    /// Puts the file at `destination` back at `originalPath`.
    ///
    /// - Parameters:
    ///   - destination: where the move left the file.
    ///   - identity: the file's identity at `destination` when it was found
    ///     there; anything else at that path is not touched.
    ///   - originalPath: where the file was before the drag. Must be free.
    func undo(from destination: URL, expecting identity: ShelfFileIdentity, to originalPath: String) -> Result<ShelfUndoOutcome, ShelfUndoFailure> {
        switch Self.identity(at: destination.path) {
        case .failure(let failure): return .failure(failure)
        case .success(nil): return .failure(.destinationMissing)
        case .success(let found?) where found != identity: return .failure(.destinationChanged)
        case .success: break
        }
        let original = URL(fileURLWithPath: originalPath)
        let folder = original.deletingLastPathComponent()
        let folderIdentity: ShelfFileIdentity
        switch Self.identity(at: folder.path) {
        case .failure(let failure): return .failure(failure)
        case .success(nil): return .failure(.originalFolderMissing)
        case .success(let found?): folderIdentity = found
        }
        switch Self.identity(at: originalPath) {
        case .failure(let failure): return .failure(failure)
        case .success(.some): return .failure(.originalOccupied)
        case .success(nil): break
        }

        if folderIdentity.device == identity.device {
            switch Self.renameExclusive(from: destination.path, to: originalPath) {
            case .success: return .success(.restored)
            case .failure(.fileSystem(errno: EXDEV)): break // a mount point in between; copy instead
            case .failure(let failure): return .failure(failure)
            }
        }
        return copyBack(from: destination, expecting: identity, to: original, in: folder)
    }

    private func copyBack(from destination: URL, expecting identity: ShelfFileIdentity, to original: URL, in folder: URL) -> Result<ShelfUndoOutcome, ShelfUndoFailure> {
        // Hidden and unique, so a half-written copy is never mistaken for the
        // file and never collides with one.
        let staging = folder.appendingPathComponent(".umbar-undo-\(UUID().uuidString)-\(original.lastPathComponent)")
        do {
            try copy(destination, staging)
        } catch {
            discardStaging(staging)
            return .failure(Self.isPermissionError(error) ? .permissionDenied : .copyFailed)
        }
        switch Self.renameExclusive(from: staging.path, to: original.path) {
        case .success: break
        case .failure(let failure):
            discardStaging(staging)
            return .failure(failure)
        }
        // The copy is in place. The destination goes to the Trash only if it
        // is still the file that was copied.
        guard ShelfFileIdentity(path: destination.path) == identity else {
            return .success(.restoredLeavingCopy(destination))
        }
        do {
            try trash(destination)
            return .success(.restored)
        } catch {
            return .success(.restoredLeavingCopy(destination))
        }
    }

    /// A staging copy that did not make it into place is umbar's own file,
    /// but it still goes through the Trash, so there is exactly one way files
    /// leave in this code. If even that fails it stays, hidden, next to the
    /// original.
    private func discardStaging(_ staging: URL) {
        guard ShelfFileIdentity(path: staging.path) != nil else { return }
        try? trash(staging)
    }

    /// lstat, with "nothing there" as `nil` and access errors as failures.
    private static func identity(at path: String) -> Result<ShelfFileIdentity?, ShelfUndoFailure> {
        var info = stat()
        if lstat(path, &info) == 0 {
            return .success(ShelfFileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino)))
        }
        switch errno {
        case ENOENT, ENOTDIR: return .success(nil)
        case EACCES, EPERM: return .failure(.permissionDenied)
        case let code: return .failure(.fileSystem(errno: code))
        }
    }

    /// rename(2) that fails instead of replacing anything at `to`.
    private static func renameExclusive(from: String, to: String) -> Result<Void, ShelfUndoFailure> {
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return .success(()) }
        let code = errno
        if code == ENOTSUP || code == EINVAL {
            // Some file systems (exFAT, SMB) lack RENAME_EXCL. FileManager's
            // move refuses an existing target too, with a check-then-rename
            // gap of microseconds; the original path was free a moment ago.
            do {
                try FileManager.default.moveItem(atPath: from, toPath: to)
                return .success(())
            } catch {
                return .failure(isPermissionError(error) ? .permissionDenied : .originalOccupied)
            }
        }
        return .failure(failure(forErrno: code))
    }

    private static func failure(forErrno code: Int32) -> ShelfUndoFailure {
        switch code {
        case EEXIST, ENOTEMPTY: .originalOccupied
        case EACCES, EPERM: .permissionDenied
        case ENOENT: .destinationMissing
        default: .fileSystem(errno: code)
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) { return true }
        return ns.underlyingErrors.contains(where: isPermissionError)
    }
}

/// Monotonic time for the Undo window, injectable so tests need no waiting.
///
/// The sleep takes an absolute deadline, not a duration. With a duration the
/// deadline is fixed only when the sleep starts, after the caller has read
/// `now`; if the clock moves in between, the deadline moves with it. Under
/// the tests' manual clock, an advance meant to end the window landed in
/// that gap, the sleeper waited for a time no test reached, and the suite
/// hung (card #100).
protocol ShelfUndoClock: Sendable {
    /// Time since an arbitrary, fixed origin.
    var now: Duration { get }
    /// Returns once `now >= deadline`, at once if it already is. Throws
    /// `CancellationError` if the task is cancelled first.
    func sleep(until deadline: Duration) async throws
}

struct ShelfUndoSystemClock: ShelfUndoClock {
    private let origin = ContinuousClock.now
    var now: Duration { ContinuousClock.now - origin }
    func sleep(until deadline: Duration) async throws {
        try await Task.sleep(until: origin + deadline, clock: .continuous)
    }
}

/// A shelf item that was moved out of the shelf a moment ago, shown with
/// "Taşındı: <name> · Geri al" until its window runs out (card #101).
struct ShelfMoveGhost: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Moments after the move, while the destination is looked up
        /// (usually well under 100 ms). Undo is not available yet.
        case locating
        /// Undo is available.
        case ready
        /// The destination could not be told for certain (not on a watched
        /// volume, or several look-alikes). The chip says the file moved;
        /// there is no Undo.
        case undoUnavailable
        /// Undo is running. A cross-volume Undo copies the file back, which
        /// takes as long as the move did.
        case undoing
        /// Undo failed; nothing was changed. Stays until `dismiss`, so the
        /// user can sort it out by hand (`destination` says where the file is).
        case failed(ShelfUndoFailure)
        /// Undo put the file back and the item is on the shelf again, but the
        /// copy at `destination` could not be moved to the Trash.
        case restoredLeavingCopy
    }

    /// The shelf item's ID. A restored item keeps it.
    let id: UUID
    /// The file's name when it was dragged, for "Taşındı: <name>".
    let name: String
    /// Where the item was on the shelf, so Undo puts it back in place.
    let index: Int
    /// Where the file was before the drag.
    let originalPath: String
    /// Where the file is now, once known.
    var destination: URL?
    var status: Status

    var canUndo: Bool { status == .ready }

    /// The file went to a Trash (the Dock's Trash, AC-3.21), not a folder.
    var wentToTrash: Bool {
        guard let components = destination?.pathComponents else { return false }
        return components.contains(".Trash") || components.contains(".Trashes")
    }
}

/// The ghosts of items moved out of the shelf, their Undo, and their expiry
/// (Can B2 fix 2, card #100; the chip UI is card #101).
///
/// Lifecycle: `recordMove` adds a ghost as `.locating` and starts its window;
/// the destination lookup turns it `.ready` or `.undoUnavailable`. `undo`
/// moves the file back and, on success, hands the item to `onRestore` and
/// drops the ghost. The window ends a ghost in any state but `.undoing` and
/// `.failed`; a failed ghost waits for `dismiss`. When a ghost ends without
/// Undo the item stays off the shelf, as after any move (BR-3.5).
///
/// Ghosts are not persisted: quitting umbar inside the window ends them.
@MainActor
final class ShelfMoveUndoModel: ObservableObject {
    /// How long Undo stays offered. The approved range is 6–8 s.
    nonisolated static let defaultWindow: Duration = .seconds(8)

    @Published private(set) var ghosts: [ShelfMoveGhost] = []

    /// Puts a restored item back on the shelf at the given index (clamped by
    /// the receiver). Set by the shelf's view model.
    var onRestore: ((ShelfItem, Int) -> Void)?

    let window: Duration
    private let clock: any ShelfUndoClock
    private let undoer: ShelfMoveUndoer

    private struct Record {
        let item: ShelfItem
        var identity: ShelfFileIdentity?
        /// Clock time at which the ghost expires; nil while paused or not
        /// expiring.
        var deadline: Duration?
        /// Window left when paused.
        var remainingWhenPaused: Duration?
        var expiry: Task<Void, Never>?
        var locate: Task<Void, Never>?
    }
    private var records: [UUID: Record] = [:]

    init(window: Duration = ShelfMoveUndoModel.defaultWindow, clock: any ShelfUndoClock = ShelfUndoSystemClock(), undoer: ShelfMoveUndoer = ShelfMoveUndoer()) {
        self.window = window
        self.clock = clock
        self.undoer = undoer
    }

    func ghost(_ id: UUID) -> ShelfMoveGhost? { ghosts.first { $0.id == id } }

    /// Adds a ghost for `item`, which has just left the shelf because its file
    /// was moved away.
    ///
    /// - Parameters:
    ///   - index: the item's position on the shelf before it left.
    ///   - source: the file at drag start.
    ///   - locate: finds the destination; runs off the main actor.
    /// - Returns: the lookup task, so callers (and tests) can await it.
    @discardableResult
    func recordMove(of item: ShelfItem, at index: Int, source: ShelfDragSource, locate: @escaping @Sendable () async -> ShelfMoveDestination) -> Task<Void, Never> {
        // An item that is off the shelf cannot be dragged again, so a second
        // ghost for one ID only happens if a caller gets this wrong.
        guard ghost(item.id)?.status != .undoing else { return Task {} }
        drop(item.id)
        ghosts.append(ShelfMoveGhost(id: item.id, name: source.name, index: index, originalPath: source.path, destination: nil, status: .locating))
        records[item.id] = Record(item: item)
        startExpiry(item.id, after: window)
        let id = item.id
        let task = Task { [weak self] in
            let found = await Task.detached(operation: locate).value
            self?.located(id, found)
        }
        records[id]?.locate = task
        return task
    }

    /// Moves the ghost's file back to its original path and, on success, puts
    /// the item back on the shelf.
    ///
    /// - Returns: nil when the ghost is unknown or Undo is not available
    ///   (`canUndo` is false), otherwise the result. A failure leaves the file
    ///   untouched and the ghost `.failed`.
    @discardableResult
    func undo(_ id: UUID) async -> Result<ShelfUndoOutcome, ShelfUndoFailure>? {
        guard let i = index(id), ghosts[i].canUndo,
              let destination = ghosts[i].destination,
              let identity = records[id]?.identity else { return nil }
        stopExpiry(id)
        ghosts[i].status = .undoing
        let undoer = self.undoer, originalPath = ghosts[i].originalPath
        let result = await Task.detached { undoer.undo(from: destination, expecting: identity, to: originalPath) }.value

        // `dismiss` and `end` leave an undoing ghost alone, so it is still here.
        guard let j = index(id), let record = records[id] else { return result }
        switch result {
        case .success(let outcome):
            onRestore?(Self.restoredItem(record.item, at: originalPath), ghosts[j].index)
            if case .restoredLeavingCopy = outcome {
                ghosts[j].status = .restoredLeavingCopy
                startExpiry(id, after: window)
            } else {
                drop(id)
            }
        case .failure(let failure):
            ghosts[j].status = .failed(failure)
        }
        return result
    }

    /// Ends a ghost without Undo (the chip's close button, or done handling a
    /// failure by hand). Ignored while Undo runs.
    func dismiss(_ id: UUID) {
        guard ghost(id)?.status != .undoing else { return }
        end(id)
    }

    /// Holds the window while the pointer or VoiceOver focus is on the chip,
    /// so reading it cannot run the time out (WCAG 2.2 SC 2.2.1). Resuming
    /// gives back the time that was left.
    func setExpiryPaused(_ paused: Bool, for id: UUID) {
        guard var record = records[id], let ghost = ghost(id), Self.expires(ghost.status) else { return }
        if paused {
            guard let deadline = record.deadline else { return }
            record.expiry?.cancel()
            record.expiry = nil
            record.deadline = nil
            record.remainingWhenPaused = max(deadline - clock.now, .zero)
            records[id] = record
        } else if let remaining = record.remainingWhenPaused {
            record.remainingWhenPaused = nil
            records[id] = record
            startExpiry(id, after: remaining)
        }
    }

    /// The pending expiry, for tests.
    func expiryTask(for id: UUID) -> Task<Void, Never>? { records[id]?.expiry }

    /// The pending destination lookup, for tests and for the shelf, which
    /// keeps the FSEvents recording alive until it is done.
    func locateTask(for id: UUID) -> Task<Void, Never>? { records[id]?.locate }

    // MARK: Private

    private func located(_ id: UUID, _ found: ShelfMoveDestination) {
        records[id]?.locate = nil
        guard let i = index(id), ghosts[i].status == .locating else { return }
        if case .found(let url, let identity) = found {
            ghosts[i].destination = url
            ghosts[i].status = .ready
            records[id]?.identity = identity
        } else {
            ghosts[i].status = .undoUnavailable
        }
    }

    private static func expires(_ status: ShelfMoveGhost.Status) -> Bool {
        switch status {
        case .undoing, .failed: false
        case .locating, .ready, .undoUnavailable, .restoredLeavingCopy: true
        }
    }

    private func startExpiry(_ id: UUID, after duration: Duration) {
        stopExpiry(id)
        let deadline = clock.now + duration
        records[id]?.deadline = deadline
        let clock = self.clock
        records[id]?.expiry = Task { [weak self] in
            // Loop: a clock may wake early; the deadline decides.
            while clock.now < deadline {
                do { try await clock.sleep(until: deadline) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.expire(id, deadline: deadline)
        }
    }

    private func stopExpiry(_ id: UUID) {
        records[id]?.expiry?.cancel()
        records[id]?.expiry = nil
        records[id]?.deadline = nil
        records[id]?.remainingWhenPaused = nil
    }

    private func expire(_ id: UUID, deadline: Duration) {
        guard records[id]?.deadline == deadline, let ghost = ghost(id), Self.expires(ghost.status) else { return }
        end(id)
    }

    /// Ends a ghost unless its Undo is running.
    private func end(_ id: UUID) {
        guard ghost(id)?.status != .undoing else { return }
        drop(id)
    }

    private func drop(_ id: UUID) {
        records[id]?.expiry?.cancel()
        records[id] = nil
        ghosts.removeAll { $0.id == id }
    }

    private func index(_ id: UUID) -> Int? { ghosts.firstIndex { $0.id == id } }

    /// The item as it goes back on the shelf: same ID, a fresh bookmark for
    /// the original path (after a cross-volume Undo the file is a new file,
    /// which the old bookmark cannot find).
    private static func restoredItem(_ item: ShelfItem, at path: String) -> ShelfItem {
        guard let bookmark = try? Bookmark(url: URL(fileURLWithPath: path)) else { return item }
        return ShelfItem(id: item.id, kind: .file(bookmark: bookmark.data), isTemporary: item.isTemporary)
    }
}
