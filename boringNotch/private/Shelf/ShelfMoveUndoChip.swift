//
//  ShelfMoveUndoChip.swift
//  boringNotch
//
//  "Taşındı: <ad> · Geri al" after a confirmed move out of the shelf
//  (design-language §5.3, card #101). The window, the Undo and its failures
//  live in ShelfMoveUndoModel (card #100); this only shows them.
//
//  One chip, never a stack: the page is 800 pt wide and a multi-item drag
//  makes one ghost per item. Several ghosts read as "Taşındı: 3 öğe", and
//  Undo puts back every one that can be put back.
//

import AppKit
import SwiftUI

/// What the chip says for a set of ghosts. Pure, so the copy rules are in
/// one place.
struct ShelfMoveChipContent: Equatable {
    enum Kind: Equatable {
        /// Moved; `canUndo` says whether Undo is offered yet.
        case moved(canUndo: Bool, toTrash: Bool)
        case undoing
        case failed(ShelfUndoFailure)
        /// Back on the shelf, but a copy stayed at `destination`.
        case restoredLeavingCopy(URL?)
    }

    let kind: Kind
    /// The file name, or nil when the chip stands for several ghosts.
    let name: String?
    let count: Int
    /// The ghosts the chip's buttons act on.
    let ids: [UUID]

    /// Failures first (they wait for the user), then a running Undo, then the
    /// moves. Nil when there is nothing to show.
    init?(ghosts: [ShelfMoveGhost]) {
        guard !ghosts.isEmpty else { return nil }
        if let failed = ghosts.last(where: { if case .failed = $0.status { true } else { false } }),
           case .failed(let failure) = failed.status {
            self.init(kind: .failed(failure), name: failed.name, count: 1, ids: [failed.id])
            return
        }
        if let left = ghosts.last(where: { $0.status == .restoredLeavingCopy }) {
            self.init(kind: .restoredLeavingCopy(left.destination), name: left.name, count: 1, ids: [left.id])
            return
        }
        let ids = ghosts.map(\.id)
        let name = ghosts.count == 1 ? ghosts[0].name : nil
        if ghosts.contains(where: { $0.status == .undoing }) {
            self.init(kind: .undoing, name: name, count: ghosts.count, ids: ids)
            return
        }
        let toTrash = ghosts.allSatisfy(\.wentToTrash)
        self.init(kind: .moved(canUndo: ghosts.contains(where: \.canUndo), toTrash: toTrash),
                  name: name, count: ghosts.count, ids: ids)
    }

    private init(kind: Kind, name: String?, count: Int, ids: [UUID]) {
        self.kind = kind
        self.name = name
        self.count = count
        self.ids = ids
    }

    /// "teklif.pdf", or "3 öğe".
    var subject: String {
        name ?? String(localized: "shelf.undo.items", defaultValue: "\(count) items")
    }

    var message: String {
        switch kind {
        case .moved(_, let toTrash):
            toTrash
                ? String(localized: "shelf.undo.movedToTrash", defaultValue: "Moved to Trash: \(subject)")
                : String(localized: "shelf.undo.moved", defaultValue: "Moved: \(subject)")
        case .undoing:
            String(localized: "shelf.undo.undoing", defaultValue: "Putting back: \(subject)")
        case .failed(let failure):
            String(localized: "shelf.undo.failed", defaultValue: "Couldn’t undo: \(Self.reason(failure))")
        case .restoredLeavingCopy:
            String(localized: "shelf.undo.leftCopy", defaultValue: "Put back. A copy stayed where it was moved.")
        }
    }

    /// What went wrong, as the end of "Geri alınamadı: …". Each says where the
    /// file is, because nothing was changed.
    static func reason(_ failure: ShelfUndoFailure) -> String {
        switch failure {
        case .destinationMissing:
            String(localized: "shelf.undo.reason.destinationMissing", defaultValue: "the file is no longer where it was moved")
        case .destinationChanged:
            String(localized: "shelf.undo.reason.destinationChanged", defaultValue: "the file was changed after the move")
        case .originalOccupied:
            String(localized: "shelf.undo.reason.originalOccupied", defaultValue: "another file is in its old place")
        case .originalFolderMissing:
            String(localized: "shelf.undo.reason.originalFolderMissing", defaultValue: "its old folder no longer exists")
        case .permissionDenied:
            String(localized: "shelf.undo.reason.permissionDenied", defaultValue: "macOS didn’t allow access")
        case .copyFailed:
            String(localized: "shelf.undo.reason.copyFailed", defaultValue: "copying it back failed")
        case .fileSystem:
            String(localized: "shelf.undo.reason.fileSystem", defaultValue: "a file system error")
        }
    }
}

struct ShelfMoveUndoChip: View {
    @ObservedObject var model: ShelfMoveUndoModel
    /// Ghosts to show instead of the model's, for the page renderer.
    var fixture: [ShelfMoveGhost]? = nil
    @AccessibilityFocusState private var voiceOverFocused: Bool
    @State private var hovering = false

    /// Fixed so the chip never changes height between states (no layout
    /// shift when Undo becomes available or the spinner appears).
    static let height: CGFloat = 28

    private var ghosts: [ShelfMoveGhost] { fixture ?? model.ghosts }

    var body: some View {
        ZStack {
            if let content = ShelfMoveChipContent(ghosts: ghosts) {
                chip(content)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(UmbarMotion.reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18),
                   value: ShelfMoveChipContent(ghosts: ghosts))
        .onChange(of: hovering || voiceOverFocused) { _, held in hold(held) }
    }

    private func chip(_ content: ShelfMoveChipContent) -> some View {
        HStack(spacing: PageTokens.s) {
            glyph(content.kind)
                .frame(width: 14)
                .accessibilityHidden(true)

            Text(content.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PageTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            actions(content)
        }
        .padding(.leading, PageTokens.m)
        // Buttons bring their own inset; plain text needs the leading one.
        .padding(.trailing, content.kind == .undoing ? PageTokens.m : 4)
        .frame(height: Self.height)
        .background(Capsule().fill(PageTokens.raisedStrong))
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.message)
        .accessibilityFocused($voiceOverFocused)
    }

    @ViewBuilder
    private func glyph(_ kind: ShelfMoveChipContent.Kind) -> some View {
        switch kind {
        case .moved(_, let toTrash):
            Image(systemName: toTrash ? "trash" : "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PageTokens.textSecondary)
        case .undoing:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(ShelfChipTokens.danger)
        case .restoredLeavingCopy:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PageTokens.textSecondary)
        }
    }

    @ViewBuilder
    private func actions(_ content: ShelfMoveChipContent) -> some View {
        switch content.kind {
        case .moved(let canUndo, _):
            // Shown, disabled, while the destination is looked up (well under
            // 100 ms), so the common case never grows a button. When the
            // destination cannot be told for certain there is no Undo at all.
            if canUndo || isLocating(content) {
                Text(verbatim: "·").foregroundStyle(PageTokens.textSecondary).accessibilityHidden(true)
                Button(String(localized: "shelf.undo.action", defaultValue: "Undo")) { undo(content.ids) }
                    .buttonStyle(ShelfChipButtonStyle(prominent: true))
                    .disabled(!canUndo)
            }
            closeButton(content.ids)
        case .undoing:
            EmptyView()
        case .failed:
            closeButton(content.ids)
        case .restoredLeavingCopy(let destination):
            if let destination {
                Button(String(localized: "shelf.undo.showCopy", defaultValue: "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
                .buttonStyle(ShelfChipButtonStyle(prominent: false))
            }
            closeButton(content.ids)
        }
    }

    private func closeButton(_ ids: [UUID]) -> some View {
        Button {
            ids.forEach(model.dismiss)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(ShelfChipButtonStyle(prominent: false))
        .accessibilityLabel(String(localized: "shelf.undo.dismiss", defaultValue: "Dismiss"))
    }

    private func isLocating(_ content: ShelfMoveChipContent) -> Bool {
        ghosts.contains { content.ids.contains($0.id) && $0.status == .locating }
    }

    private func hold(_ held: Bool) {
        for ghost in ghosts { model.setExpiryPaused(held, for: ghost.id) }
    }

    /// Puts back every ghost that can be, one after the other, and says how
    /// it went.
    private func undo(_ ids: [UUID]) {
        let names = Dictionary(uniqueKeysWithValues: model.ghosts.map { ($0.id, $0.name) })
        Task { @MainActor in
            var restored: [String] = []
            var failure: ShelfUndoFailure?
            for id in ids where model.ghost(id)?.canUndo == true {
                switch await model.undo(id) {
                case .success: if let name = names[id] { restored.append(name) }
                case .failure(let f): failure = failure ?? f
                case nil: break
                }
            }
            let announcement: String
            if let failure {
                announcement = String(localized: "shelf.undo.failed", defaultValue: "Couldn’t undo: \(ShelfMoveChipContent.reason(failure))")
            } else if restored.count == 1 {
                announcement = String(localized: "shelf.undo.restored", defaultValue: "Put back: \(restored[0])")
            } else if !restored.isEmpty {
                let subject = String(localized: "shelf.undo.items", defaultValue: "\(restored.count) items")
                announcement = String(localized: "shelf.undo.restored", defaultValue: "Put back: \(subject)")
            } else {
                return
            }
            AccessibilityNotification.Announcement(announcement).post()
        }
    }
}

/// Chip-local tokens until UmbarTokens lands (like PageTokens).
enum ShelfChipTokens {
    /// Danger on `raisedStrong`; paired with a glyph and the word
    /// "Geri alınamadı", never alone.
    static let danger = Color(red: 0xFF / 255, green: 0x7B / 255, blue: 0x72 / 255)
}

/// Text buttons inside the chip: Undo in `textPrimary` on a lighter pill,
/// the rest quiet. Focus ring is the system's.
private struct ShelfChipButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? PageTokens.textPrimary : PageTokens.textSecondary)
            .padding(.horizontal, prominent ? 10 : 6)
            .frame(minHeight: 20)
            .background {
                if prominent {
                    Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.14))
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            // A long file name gives way, never the button.
            .fixedSize()
    }
}
