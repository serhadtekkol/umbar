//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import SwiftUI
import Defaults

import QuickLook
import os

/// Paths are never logged here (#72): a file name can be personal data.
private let shelfDragLog = Logger(subsystem: "umbar", category: "ShelfDrag")

struct ShelfItemView: View {
    let item: ShelfItem
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var selection = ShelfSelectionModel.shared
    @StateObject private var viewModel: ShelfItemViewModel
    @EnvironmentObject private var quickLookService: QuickLookService
    @State private var showStack = false
    @State private var cachedPreviewImage: NSImage?
    @State private var debouncedDropTarget = false

    private var isSelected: Bool { viewModel.isSelected }
    private var shouldHideDuringDrag: Bool { selection.isDragging && selection.isSelected(item.id) && false }
    
    init(item: ShelfItem) {
        self.item = item
        _viewModel = StateObject(wrappedValue: ShelfItemViewModel(item: item))
    }

    var body: some View {
        ZStack {
            if !shouldHideDuringDrag {
                VStack(alignment: .center, spacing: 2) {
                    iconView
                    textView
                }
                .frame(width: 105)
                .padding(.vertical, 10)
                .padding(.horizontal, 5)
                .background(backgroundView)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.1), value: debouncedDropTarget)
                .animation(.easeInOut(duration: 0.1), value: isSelected)

                DraggableClickHandler(
                    item: item,
                    viewModel: viewModel,
                    cachedPreviewImage: $cachedPreviewImage,
                    dragPreviewContent: {
                        DragPreviewView(thumbnail: viewModel.thumbnail ?? item.icon, displayName: item.displayName)
                    },
                    onRightClick: viewModel.handleRightClick,
                    onClick: { event, nsview in
                        viewModel.handleClick(event: event, view: nsview)
                    }
                )
            } else {
                Color.clear
                    .frame(width: 105)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 5)
            }
        }
        .onChange(of: viewModel.isDropTargeted) { _, targeted in
            vm.dragDetectorTargeting = targeted
            // Debounce drop target state changes
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                debouncedDropTarget = targeted
            }
        }
        .onAppear {
            Task { 
                await viewModel.loadThumbnail()
                // Pre-render drag preview once on appear
                if cachedPreviewImage == nil {
                    cachedPreviewImage = await renderDragPreview()
                }
            }
            viewModel.onQuickLookRequest = { urls in
                quickLookService.show(urls: urls, selectFirst: true)
            }
        }
        .onChange(of: viewModel.thumbnail) { _, _ in
            // Invalidate cached preview when thumbnail changes
            Task {
                cachedPreviewImage = await renderDragPreview()
            }
        }
        .quickLookPresenter(using: quickLookService)
    }

    // MARK: - View Components

    private var iconView: some View {
        Image(nsImage: viewModel.thumbnail ?? item.icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
    }

    private var textView: some View {
        Text(item.displayName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .frame(height: 30, alignment: .top)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        strokeColor,
                        lineWidth: strokeWidth
                    )
            )
    }

    private var backgroundColor: Color {
        if debouncedDropTarget {
            return Color.accentColor.opacity(0.25)
        } else if isSelected {
            return Color.accentColor.opacity(0.15)
        } else {
            return Color.clear
        }
    }

    private var strokeColor: Color {
        if debouncedDropTarget {
            return Color.accentColor.opacity(0.9)
        } else if isSelected {
            return Color.accentColor.opacity(0.8)
        } else {
            return Color.clear
        }
    }

    private var strokeWidth: CGFloat {
        if debouncedDropTarget {
            return 3
        } else if isSelected {
            return 2
        } else {
            return 1
        }
    }
    
    // MARK: - Drag Preview Rendering
    
    @MainActor
    private func renderDragPreview() async -> NSImage {
        let content = DragPreviewView(thumbnail: viewModel.thumbnail ?? item.icon, displayName: item.displayName)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return renderer.nsImage ?? (viewModel.thumbnail ?? item.icon)
    }

    
}

// MARK: - Draggable Click Handler with NSDraggingSource
private struct DraggableClickHandler<Content: View>: NSViewRepresentable {
    let item: ShelfItem
    let viewModel: ShelfItemViewModel
    @Binding var cachedPreviewImage: NSImage?
    @ViewBuilder let dragPreviewContent: () -> Content
    let onRightClick: (NSEvent, NSView) -> Void
    let onClick: (NSEvent, NSView) -> Void
    
    func makeNSView(context: Context) -> DraggableClickView {
        let view = DraggableClickView()
        view.item = item
        view.viewModel = viewModel
        view.dragPreviewImage = cachedPreviewImage ?? renderDragPreview()
        view.onRightClick = onRightClick
        view.onClick = onClick
        return view
    }
    
    func updateNSView(_ nsView: DraggableClickView, context: Context) {
        nsView.item = item
        nsView.viewModel = viewModel
        // Only update preview if cached version is available
        if let cached = cachedPreviewImage {
            nsView.dragPreviewImage = cached
        }
        nsView.onRightClick = onRightClick
        nsView.onClick = onClick
    }
    
    private func renderDragPreview() -> NSImage {
        let content = dragPreviewContent()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        if let nsImage = renderer.nsImage {
            return nsImage
        }
        
        // Fallback to icon if rendering fails
        return viewModel.thumbnail ?? item.icon
    }
    
    final class DraggableClickView: NSView, NSDraggingSource {
        var item: ShelfItem!
        weak var viewModel: ShelfItemViewModel?
        var dragPreviewImage: NSImage?
        var onRightClick: ((NSEvent, NSView) -> Void)?
        var onClick: ((NSEvent, NSView) -> Void)?

        private var mouseDownEvent: NSEvent?
        private let dragThreshold: CGFloat = 3.0
        private var draggedURLs: [URL] = []
        private var draggedItems: [ShelfItem] = []
        /// Path and identity of each dragged file at drag start, to confirm a
        /// move before the item leaves the shelf.
        private var draggedSources: [ShelfItem.ID: ShelfDragSource] = [:]
        private var draggedSourcesDeletable = true
        /// Where the pointer was at the last mask query, i.e. at the drop.
        private var lastDestination: ShelfDragDestination = .ownApp
        
        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(event, self)
        }
        
        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            onClick?(event, self)
        }
        
        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownEvent = mouseDownEvent else {
                super.mouseDragged(with: event)
                return
            }
            
            let dragDistance = hypot(
                event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                event.locationInWindow.y - mouseDownEvent.locationInWindow.y
            )
            
            if dragDistance > dragThreshold {
                startDragSession(with: event)
                self.mouseDownEvent = nil
            } else {
                super.mouseDragged(with: event)
            }
        }
        
        private func startDragSession(with event: NSEvent) {
            // Prepare dragging items
            let selectedItems = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            let itemsToDrag: [ShelfItem]

            if selectedItems.count > 1 && selectedItems.contains(where: { $0.id == item.id }) {
                itemsToDrag = selectedItems
            } else {
                itemsToDrag = [item]
            }

            draggedItems = []
            draggedSources = [:]
            draggedSourcesDeletable = true
            lastDestination = .ownApp

            // Create dragging items for AppKit
            var draggingItems: [NSDraggingItem] = []

            for dragItem in itemsToDrag {
                if let pasteboardItem = createPasteboardItem(for: dragItem) {
                    draggedItems.append(dragItem)
                    let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

                    // Use the drag preview image
                    let image = dragPreviewImage ?? dragItem.icon
                    let imageFrame = NSRect(
                        x: 0,
                        y: 0,
                        width: image.size.width,
                        height: image.size.height
                    )
                    draggingItem.setDraggingFrame(imageFrame, contents: image)

                    draggingItems.append(draggingItem)
                }
            }

            guard !draggingItems.isEmpty else { return }

            beginDraggingSession(with: draggingItems, event: event, source: self)
        }
        
        /// Builds the pasteboard item for one shelf item and records what the
        /// drag-end handling needs to know about its file. Returns nil for an
        /// item whose file cannot be found: it is not draggable (AC-3.8).
        private func createPasteboardItem(for item: ShelfItem) -> NSPasteboardItem? {
            switch item.kind {
            case .file:
                guard let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item),
                      let source = ShelfDragSource(url: url) else {
                    return nil
                }

                // Balanced in draggingSession(_:endedAt:operation:), which
                // AppKit calls exactly once per session, also on cancel.
                if url.startAccessingSecurityScopedResource() {
                    draggedURLs.append(url)
                }

                draggedSources[item.id] = source
                if !FileManager.default.isDeletableFile(atPath: url.path) {
                    draggedSourcesDeletable = false
                }

                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                pasteboardItem.setString(url.path, forType: .string)
                return pasteboardItem
            }
        }
        
        // MARK: - NSDraggingSource
        
        // The Finder-only move relies on AppKit asking for the mask again as
        // the pointer moves between destinations, not once per context. If
        // it asked only once, a drag that leaves umbar over another app and
        // then reaches Finder would keep that app's copy-or-move mask, and
        // Finder would copy across volumes: a missed move, never a lost file.
        // The debug line below is how a hand test on a real drag confirms it
        // (`log stream --level debug --predicate 'category == "ShelfDrag"'`).
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            switch context {
            case .outsideApplication:
                lastDestination = ShelfDragDestinationProbe.destinationUnderPointer()
            case .withinApplication:
                lastDestination = .ownApp
            @unknown default:
                // Per NSDragging.h, unknown contexts are more specific kinds
                // of "within the application".
                lastDestination = .ownApp
            }
            let mask = ShelfDragOutPolicy.operationMask(
                destination: lastDestination,
                optionKeyHeld: NSEvent.modifierFlags.contains(.option),
                copyOnDrag: Defaults[.copyOnDrag],
                sourcesDeletable: draggedSourcesDeletable
            )
            shelfDragLog.debug("mask query: destination=\(String(describing: self.lastDestination), privacy: .public) mask=\(mask.rawValue, privacy: .public)")
            return mask
        }
        
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            ShelfSelectionModel.shared.beginDrag()
        }
        
        
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ShelfSelectionModel.shared.endDrag()

            // Ends the access begun in createPasteboardItem. The move watcher
            // that may run after this needs none: it only calls lstat.
            for url in draggedURLs {
                url.stopAccessingSecurityScopedResource()
            }
            draggedURLs.removeAll()

            let action = ShelfDragOutPolicy.endAction(
                operation: operation,
                lastDestination: lastDestination,
                autoRemove: Defaults[.autoRemoveShelfItems]
            )
            shelfDragLog.debug("drag ended: operation=\(operation.rawValue, privacy: .public) destination=\(String(describing: self.lastDestination), privacy: .public) action=\(String(describing: action), privacy: .public) items=\(self.draggedItems.count, privacy: .public)")
            ShelfStateViewModel.shared.handleDragEnd(action, for: draggedItems, sources: draggedSources)
            draggedItems.removeAll()
            draggedSources.removeAll()
        }
        
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            return false
        }
    }
}
