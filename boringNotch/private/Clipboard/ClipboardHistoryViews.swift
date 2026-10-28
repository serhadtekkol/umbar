//
//  ClipboardHistoryViews.swift
//  umbar
//
//  F21: the Raf page's two sides ("Dosyalar | Pano") and the clipboard
//  history strip. Pano lives on Raf instead of its own tab because the tab
//  bar has no room left beside a 254 pt notch, and both sides hold "things
//  to put somewhere else".
//

import Defaults
import SwiftUI

/// The Raf page. With the shelf on it shows a two-way switch above the
/// content; the Pano side then holds either the history or, while the
/// history is off (the default), a short explainer with a "Turn on" button.
/// With the shelf off only the history is shown (the tab is hidden when
/// both are off, PanelTabs).
struct ShelfPage: View {
    @EnvironmentObject private var vm: BoringViewModel
    @Default(.boringShelf) private var shelfOn
    @Default(.clipboardHistoryEnabled) private var clipboardOn
    @Default(.shelfPageSection) private var storedSection
    @ObservedObject var clipboard: ClipboardHistoryModel
    /// Set only by the page renderer.
    var undoChipFixture: [ShelfMoveGhost]? = nil
    /// Set only by the page renderer, which cannot write the user's defaults.
    var sectionOverride: ShelfPageSection? = nil
    /// Set only by the page renderer, for the same reason.
    var clipboardEnabledOverride: Bool? = nil

    init(clipboard: ClipboardHistoryModel = .shared, undoChipFixture: [ShelfMoveGhost]? = nil,
         section: ShelfPageSection? = nil, clipboardEnabled: Bool? = nil) {
        self.clipboard = clipboard
        self.undoChipFixture = undoChipFixture
        self.sectionOverride = section
        self.clipboardEnabledOverride = clipboardEnabled
    }

    private var clipboardEnabled: Bool { clipboardEnabledOverride ?? clipboardOn }

    /// Height of the switch row; the content gets the rest of the page.
    static let switchRowHeight: CGFloat = 22

    private var section: ShelfPageSection {
        if !shelfOn { return .clipboard }
        return sectionOverride ?? storedSection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PageTokens.s) {
            HStack(spacing: PageTokens.s) {
                if shelfOn {
                    ShelfSectionSwitch(selection: section) { storedSection = $0 }
                }
                Spacer(minLength: 0)
                if section == .clipboard, clipboardEnabled, !clipboard.items.isEmpty {
                    ClipboardClearAllButton { clipboard.clearAll() }
                }
            }
            .frame(height: Self.switchRowHeight)
            switch section {
            case .files: ShelfView(undoChipFixture: undoChipFixture)
            case .clipboard:
                if clipboardEnabled {
                    ClipboardHistoryStrip(model: clipboard)
                } else {
                    ClipboardHistoryOffCard { Defaults[.clipboardHistoryEnabled] = true }
                }
            }
        }
        // A file dragged onto the notch means "put it on the shelf"; show
        // the side that takes it.
        .onChange(of: vm.dragDetectorTargeting) { _, targeting in
            if targeting, storedSection != .files { storedSection = .files }
        }
    }
}

/// "Dosyalar | Pano". Not a system segmented Picker: that one is drawn for a
/// light or dark window background, and the island is always black.
struct ShelfSectionSwitch: View {
    let selection: ShelfPageSection
    let select: (ShelfPageSection) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ShelfPageSection.allCases, id: \.self) { section in
                let isOn = section == selection
                Button { select(section) } label: {
                    Label(Self.title(section), systemImage: Self.icon(section))
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isOn ? PageTokens.textPrimary : PageTokens.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: ShelfPage.switchRowHeight - 4)
                        .background(isOn ? PageTokens.raisedStrong : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(PageTokens.raised, in: Capsule())
        .accessibilityElement(children: .contain)
    }

    static func title(_ section: ShelfPageSection) -> String {
        switch section {
        case .files: String(localized: "shelf.section.files", defaultValue: "Files")
        case .clipboard: String(localized: "shelf.section.clipboard", defaultValue: "Clipboard")
        }
    }

    private static func icon(_ section: ShelfPageSection) -> String {
        switch section {
        case .files: "tray"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

/// "Clear all", which asks once more before it acts: the history cannot be
/// brought back.
struct ClipboardClearAllButton: View {
    let clear: () -> Void
    @State private var confirming = false

    var body: some View {
        Button {
            if confirming {
                confirming = false
                clear()
            } else {
                confirming = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirming = false }
            }
        } label: {
            Text(confirming
                 ? String(localized: "clipboard.clearAll.confirm", defaultValue: "Clear all?")
                 : String(localized: "clipboard.clearAll", defaultValue: "Clear all"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(confirming ? Color.black : PageTokens.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: ShelfPage.switchRowHeight)
                .background(confirming ? PageTokens.live : PageTokens.raised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The history as a horizontal strip of cards, newest on the left, like the
/// shelf's files.
struct ClipboardHistoryStrip: View {
    @ObservedObject var model: ClipboardHistoryModel

    var body: some View {
        Group {
            if model.items.isEmpty && !model.permissionRequired {
                empty
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: PageTokens.s) {
                        if model.permissionRequired {
                            ClipboardPermissionCard { model.openPasteboardPrivacySettings() }
                        }
                        ForEach(model.items) { item in
                            ClipboardItemCard(item: item, thumbnail: model.thumbnail(for: item),
                                              justCopied: model.justCopiedID == item.id,
                                              copy: { model.copy(item) }, delete: { model.delete(item) })
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // L5: the history must not reach a screen share or a recording.
        .excludedFromScreenCapture()
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PageTokens.textSecondary)
                .imageScale(.large)
            Text(String(localized: "clipboard.empty.title", defaultValue: "What you copy shows up here"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PageTokens.textPrimary)
            Text(String(localized: "clipboard.empty.detail", defaultValue: "Items apps mark as private and copies from known password managers are not saved."))
                .font(.system(size: 11))
                .foregroundStyle(PageTokens.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PageTokens.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: PageTokens.tileRadius, style: .continuous))
    }
}

/// The Pano side while the history is off: what it would do, and one
/// button that turns it on. Turning on starts recording from the next copy;
/// nothing copied before is read (BR-4.7).
struct ClipboardHistoryOffCard: View {
    let turnOn: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PageTokens.textSecondary)
                .imageScale(.large)
            Text(String(localized: "clipboard.off.title", defaultValue: "Clipboard history is off"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PageTokens.textPrimary)
            Text(String(localized: "clipboard.off.detail",
                        defaultValue: "Turn it on to keep what you copy here and copy it again with a click. It stays on this Mac."))
                .font(.system(size: 11))
                .foregroundStyle(PageTokens.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: turnOn) {
                Text(String(localized: "clipboard.off.turnOn", defaultValue: "Turn On"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PageTokens.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(PageTokens.raisedStrong, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.horizontal, PageTokens.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PageTokens.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: PageTokens.tileRadius, style: .continuous))
    }
}

/// One copy. Click puts it back on the pasteboard; × (on hover) or the
/// context menu removes it.
struct ClipboardItemCard: View {
    let item: ClipboardItem
    let thumbnail: NSImage?
    let justCopied: Bool
    let copy: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    static let width: CGFloat = 132

    var body: some View {
        Button(action: copy) {
            VStack(alignment: .leading, spacing: 4) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundStyle(PageTokens.textSecondary)
                    .lineLimit(1)
            }
            .padding(PageTokens.s)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .background(hovering ? PageTokens.raisedStrong : PageTokens.raised,
                        in: RoundedRectangle(cornerRadius: PageTokens.tileRadius, style: .continuous))
            .overlay { if justCopied { copiedBadge } }
            .contentShape(RoundedRectangle(cornerRadius: PageTokens.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering && !justCopied {
                Button(action: delete) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(PageTokens.textPrimary, Color.black.opacity(0.7))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel(String(localized: "clipboard.delete", defaultValue: "Delete"))
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: justCopied)
        .contextMenu {
            Button(String(localized: "clipboard.copy", defaultValue: "Copy"), action: copy)
            Button(String(localized: "clipboard.delete", defaultValue: "Delete"), role: .destructive, action: delete)
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(String(localized: "clipboard.copy.hint", defaultValue: "Copies it again"))
        .accessibilityAction(named: Text(String(localized: "clipboard.delete", defaultValue: "Delete")), delete)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let text):
            Text(Self.collapsed(text))
                .font(.system(size: 11))
                .foregroundStyle(PageTokens.textPrimary)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
        case .url(let link):
            let parts = Self.linkParts(link)
            VStack(alignment: .leading, spacing: 2) {
                Label(parts.host, systemImage: "link")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PageTokens.textPrimary)
                    .lineLimit(1)
                Text(parts.rest)
                    .font(.system(size: 11))
                    .foregroundStyle(PageTokens.textSecondary)
                    .lineLimit(4)
            }
        case .image:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(PageTokens.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var copiedBadge: some View {
        RoundedRectangle(cornerRadius: PageTokens.tileRadius, style: .continuous)
            .fill(PageTokens.raisedStrong.opacity(0.94))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(PageTokens.live)
                    Text(String(localized: "clipboard.copied", defaultValue: "Copied"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PageTokens.textPrimary)
                }
            }
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    private var footer: String {
        let when = item.copiedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        switch item.content {
        case .text, .url: return when
        case .image(let ref):
            // Size, not format: the card is too narrow for both, and the size
            // is what tells two similar screenshots apart.
            let size = ByteCountFormatter.string(fromByteCount: Int64(ref.byteCount), countStyle: .file)
            return "\(size) · \(when)"
        }
    }

    private var accessibilityText: String {
        switch item.content {
        case .text(let text): Self.collapsed(String(text.prefix(200)))
        case .url(let link): link
        case .image: String(localized: "clipboard.image", defaultValue: "Image")
        }
    }

    /// Runs of blank lines and indentation waste the card's few lines.
    static func collapsed(_ text: String) -> String {
        String(text.prefix(600))
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func linkParts(_ link: String) -> (host: String, rest: String) {
        guard let components = URLComponents(string: link), let host = components.host else { return (link, "") }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var rest = components.percentEncodedPath
        if let query = components.percentEncodedQuery { rest += "?" + query }
        return (bare, rest == "/" ? "" : (rest.removingPercentEncoding ?? rest))
    }
}

/// Shown first in the strip when macOS would ask before umbar reads the
/// pasteboard. umbar never triggers that alert from the background (spike
/// A2); the user grants "Allow" once in System Settings instead.
struct ClipboardPermissionCard: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "clipboard.permission.title", defaultValue: "Permission needed"),
                  systemImage: "lock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PageTokens.textPrimary)
            Text(String(localized: "clipboard.permission.detail",
                        defaultValue: "To save copies, set umbar to Allow under Paste from Other Apps."))
                .font(.system(size: 11))
                .foregroundStyle(PageTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: openSettings) {
                Text(String(localized: "clipboard.permission.open", defaultValue: "Open Settings"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PageTokens.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(PageTokens.raisedStrong, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(PageTokens.s)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(PageTokens.raised, in: RoundedRectangle(cornerRadius: PageTokens.tileRadius, style: .continuous))
    }
}
