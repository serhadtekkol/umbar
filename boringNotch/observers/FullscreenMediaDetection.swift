//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import AppKit
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    
    @Published var fullscreenStatus: [String: Bool] = [:]
    
    private var monitorTask: Task<Void, Never>?
    
    private init() {
        startMonitoring()
    }
    
    deinit {
        monitorTask?.cancel()
    }
    
    private var lastSpaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo] = []
    private var recheck: DispatchWorkItem?

    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                lastSpaces = spaces
                updateStatus(with: spaces)
            }
        }
        // A fullscreen space existing on a screen is not the same as it
        // being the one shown: re-evaluate whenever the shown space changes,
        // and again once the switch animation has settled.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRecheck() }
        }
    }

    private func scheduleRecheck() {
        updateStatus(with: lastSpaces)
        recheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateStatus(with: self.lastSpaces)
            }
        }
        recheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Screens whose currently shown space is a fullscreen app: another
    /// process's window covers the whole screen (ScreenEdgeGlowPolicy).
    private func screensShowingFullscreen() -> Set<String> {
        let windows = ScreenEdgeGlowController.onScreenWindows()
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let pid = ProcessInfo.processInfo.processIdentifier
        var result: Set<String> = []
        for screen in NSScreen.screens {
            guard let id = screen.displayUUID else { continue }
            let rect = ScreenEdgeGlowPolicy.displayRect(fromAppKit: screen.frame, mainScreenHeight: mainHeight)
            if ScreenEdgeGlowPolicy.isFullscreen(screen: rect, windows: windows, ownPID: pid) {
                result.insert(id)
            }
        }
        return result
    }
    
    private func updateStatus(with spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo]) {
        var newStatus: [String: Bool] = [:]
        let showing = screensShowingFullscreen()
        
        for space in spaces {
            if let uuid = space.screenUUID {
                let shouldDetect: Bool
                if Defaults[.hideNotchOption] == .nowPlayingOnly, let musicSourceBundle = MusicManager.shared.bundleIdentifier  {
                    shouldDetect = space.runningApps.contains(musicSourceBundle)
                } else {
                    shouldDetect = true
                }
                newStatus[uuid] = shouldDetect && showing.contains(uuid)
            }
        }
        
        self.fullscreenStatus = newStatus
    }
}

