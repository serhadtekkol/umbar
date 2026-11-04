//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import os
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @ObservedObject var eyeBreak = EyeBreakManager.shared
    @ObservedObject var focusTimer = FocusTimerService.shared
    @ObservedObject var hudAccessCard = HUDAccessCard.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    /// Folds a hover-opened panel once the pointer has left it (AC-1.4 (R1.2)).
    /// Runs only while the panel is open; see startPointerWatch().
    @State private var pointerWatch: Task<Void, Never>?
    @State private var hoverTracker = NotchHoverTracker()
    /// The closed island's hit area in the window's SwiftUI global space,
    /// recorded whenever the notch is closed. Live activities and badges
    /// change it, so it is measured rather than computed.
    @State private var closedHoverFrame: CGRect = .zero
    @State private var clickThrough = NotchClickThrough()
    @State private var approachMonitor = NotchApproachMonitor()
    /// The pointer's nearness to the closed island, 0...1 (NotchApproachPolicy).
    @State private var pointerApproach: CGFloat = 0
    /// The pointer's pull on the drip (NotchDripPolicy), straight from the
    /// monitor to DripLayer; ContentView never reads it.
    @State private var dripPointer = DripPointer()
    /// The hover hint's progress on each axis, 0...1. Two values so width
    /// and depth can run on their own springs (UmbarMotion.hoverHintWiden /
    /// hoverHintDeepen); see animateHoverHint(to:).
    @State private var hintWidth: CGFloat = 0
    @State private var hintDepth: CGFloat = 0
    /// When the last close finishes moving (system uptime); the hint waits
    /// for it, see animateHoverHint(to:).
    @State private var closeSettlesAt: TimeInterval = 0
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    @Default(.dripEffectEnabled) private var dripEffectEnabled

    @Default(.closedSongTitleEnabled) private var closedSongTitleEnabled

    /// The closed island's music ears (ClosedMusicPresence): a pause folds
    /// them `hideDelay` later instead of after the media inactivity
    /// timeout, which still governs the open panel through `isPlayerIdle`.
    @State private var musicPresence = ClosedMusicPresence(playing: MusicManager.shared.isPlaying)
    /// Whether the ears are in the layout; stays true while they fold.
    @State private var musicEarsActive = MusicManager.shared.isPlaying
    /// The ears' content (opacity, album art scale) and width, 0...1. Two
    /// values so Reduce Motion can fade the content without moving the shape.
    @State private var musicContent: CGFloat = MusicManager.shared.isPlaying ? 1 : 0
    @State private var musicWidth: CGFloat = MusicManager.shared.isPlaying ? 1 : 0
    /// True while the ears come back after a pause: they grow out of the
    /// notch on their own values, so the closed-content transition (made
    /// for the panel folding) stays out of the way.
    @State private var musicEarsArriving = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    #if DEBUG
    /// Reduce Motion is read-only in the environment; a render run can force it.
    private var reduceMotion: Bool { systemReduceMotion || MotionFrameRenderer.forceReduceMotion }
    #else
    private var reduceMotion: Bool { systemReduceMotion }
    #endif

    /// Whether the closed island shows the live strip; a key for the ear
    /// spring so the island grows with the strip instead of snapping.
    @State private var liveStripShown = false

    // Shared interactive spring for the swipe gestures (gestureProgress).
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    /// The hover hint (design-language §3.7 `motion.hoverHint`) the island
    /// is heading for: the full hint with the pointer on it, a share of it
    /// as the pointer nears, none once open or under Reduce Motion (the
    /// shadow fade is the hint then).
    private var hoverHintTarget: CGFloat {
        guard vm.notchState == .closed, !reduceMotion, !coordinator.helloAnimationRunning else { return 0 }
        return max(isHovering ? 1 : 0, pointerApproach * UmbarMotion.hoverApproachShare)
    }

    /// The hint's growth is zero whenever the island is not closed, inside
    /// the same expression: an open turns it to zero in the open
    /// transaction, so the hint flows into the morph on the open spring
    /// instead of shrinking back first. Drawn by the black shape only, so
    /// the measured hover frame does not move.
    private var hintIsDrawn: CGFloat { vm.notchState == .closed && !reduceMotion ? 1 : 0 }
    private var hintSide: CGFloat { UmbarMotion.hoverHintSide * hintWidth * hintIsDrawn }
    private var hintDown: CGFloat { UmbarMotion.hoverHintDown * hintDepth * hintIsDrawn }
    private var hintRadius: CGFloat { UmbarMotion.hoverHintRadius * hintDepth * hintIsDrawn }

    private func animateHoverHint(to target: CGFloat) {
        guard vm.notchState == .closed else {
            // Masked by hintIsDrawn already, so the reset is invisible; with
            // animations off it cannot touch the open morph, and the next
            // hover starts from the notch.
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { hintWidth = 0; hintDepth = 0 }
            return
        }
        // Not while a close is still moving: an animated transaction landing
        // mid-close hands the island's height the hint's bouncy spring, and
        // it dips below the notch before settling. The island folds first,
        // then leans toward a pointer that is still near.
        let wait = max(0, closeSettlesAt - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard vm.notchState == .closed, target == hoverHintTarget else { return }
            if target >= hintDepth {
                withAnimation(UmbarMotion.hoverHintWiden) { hintWidth = target }
                withAnimation(UmbarMotion.hoverHintDeepen) { hintDepth = target }
            } else {
                withAnimation(UmbarMotion.hoverHintRelease) {
                    hintWidth = target
                    hintDepth = target
                }
            }
        }
    }

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private let hoverLog = Logger(subsystem: "umbar", category: "Hover")

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && musicEarsActive
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += ClosedMusicLayout.earsWidth(
                notchHeight: vm.effectiveClosedNotchHeight, showsTitle: showsClosedTitle, presence: musicWidth)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && !musicEarsActive && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding(.horizontal, vm.notchState == .open ? PanelLayout.sideInset : 0)
                    .padding(.bottom, vm.notchState == .open ? PanelLayout.bottomInset : 0)
                    // Content is clipped by the shape as it grows, so the
                    // panel is revealed by the island rather than faded over it.
                    .clipShape(currentNotchShape)
                    .background(alignment: .top) {
                        NotchShape(
                            topCornerRadius: topCornerRadius,
                            bottomCornerRadius: bottomCornerRadius + hintRadius
                        )
                        .fill(.black)
                        .padding(.horizontal, -hintSide)
                        .padding(.bottom, -hintDown)
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                    // Behind the island, so a badge slides out from under the
                    // notch edge instead of fading in on top of it.
                    .background(alignment: .topTrailing) {
                        PrivacyClosedBadge(isClosed: vm.notchState == .closed, height: vm.effectiveClosedNotchHeight)
                        CaffeinateClosedBadge(isClosed: vm.notchState == .closed, height: vm.effectiveClosedNotchHeight)
                    }
                    .background(alignment: .topLeading) {
                        // An explicit leading stack: the builder's implicit one
                        // centres its children, which moves a narrower ear in
                        // under the island when a wider one is out.
                        ZStack(alignment: .topLeading) {
                            // Drawn first: its black runs under the time ear it sits beyond.
                            NetMonitorClosedBadge(isClosed: vm.notchState == .closed, height: vm.effectiveClosedNotchHeight)
                            // One time slot: LeadingTimeEarPolicy lets only one of these two draw.
                            FocusTimerClosedBadge(isClosed: vm.notchState == .closed, height: vm.effectiveClosedNotchHeight)
                            TimerClosedBadge(isClosed: vm.notchState == .closed, height: vm.effectiveClosedNotchHeight)
                        }
                    }
                    // Over the island and its ears for a few seconds when
                    // headphones connect; draws nothing otherwise.
                    .overlay(alignment: .top) {
                        HeadphoneGlanceOverlay(
                            isClosed: vm.notchState == .closed && !vm.hideOnClosed,
                            notchWidth: vm.closedNotchSize.width, height: vm.effectiveClosedNotchHeight)
                    }
                    // After the ears, so it lights their silhouette too; visual only.
                    .modifier(NotchOutline())
                    .modifier(EdgeGlow(isOpen: vm.notchState == .open, islandHeight: vm.effectiveClosedNotchHeight))
                    // After the glow, so the glow stays the island's silhouette
                    // and the drip's black sits in front of it. Pinned to the
                    // closed edge (and the hint's depth): when the panel opens
                    // it stays there and fades inside the growing shape.
                    .overlay(alignment: .top) {
                        if dripEffectEnabled && !reduceMotion && vm.effectiveClosedNotchHeight > 0 {
                            DripLayer(width: closedHoverFrame.width,
                                      isClosed: vm.notchState == .closed && !coordinator.helloAnimationRunning,
                                      pointer: dripPointer)
                                .offset(y: vm.effectiveClosedNotchHeight - DripArt.top + hintDown)
                        }
                    }
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        if vm.notchState == .closed { closedHoverFrame = frame }
                    }
                    .onChange(of: closedHoverFrame, initial: true) { updateClickThrough() }
                    .onChange(of: vm.notchState) { updateClickThrough() }
                    .onChange(of: dripEffectEnabled) { updateClickThrough() }
                    .onChange(of: hoverHintTarget) { _, target in animateHoverHint(to: target) }
                    .onDisappear {
                        clickThrough.stop()
                        approachMonitor.stop()
                    }
                    // Innermost wins: an open/close always uses motion.open /
                    // motion.close; the ear spring covers closed-island changes
                    // (music starts, a live strip, a HUD) in a transaction
                    // where the state did not change.
                    .animation(vm.notchState == .open ? UmbarMotion.open(reduce: reduceMotion) : UmbarMotion.close(reduce: reduceMotion), value: vm.notchState)
                    .animation(.smooth, value: gestureProgress)
                    .animation(UmbarMotion.ear(reduce: reduceMotion), value: computedChinWidth)
                    .animation(UmbarMotion.ear(reduce: reduceMotion), value: liveStripShown)
                    .animation(UmbarMotion.ear(reduce: reduceMotion), value: coordinator.sneakPeek.show)
                    .animation(UmbarMotion.ear(reduce: reduceMotion), value: coordinator.expandingView.show)
                    .onReceive(LiveActivityCenter.shared.$stripItems.map { !$0.isEmpty }.removeDuplicates()) { shown in
                        liveStripShown = shown
                    }
                    .onReceive(musicManager.$isPlaying.removeDuplicates()) { playing in
                        musicPlaybackChanged(playing)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive && pointerMayClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose && self.pointerMayClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .open {
                            hudAccessCard.notchDidOpen()
                            startPointerWatch()
                        } else {
                            hudAccessCard.notchDidClose()
                            stopPointerWatch()
                            closeSettlesAt = ProcessInfo.processInfo.systemUptime + UmbarMotion.closeSettle
                        }
                        if newState == .closed && isHovering {
                            withAnimation(UmbarMotion.hoverHint(reduce: reduceMotion)) {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose && pointerMayClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose && self.pointerMayClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    #if DEBUG
                    .onReceive(MotionFrameRenderer.HoverFixture.shared.$hovering.dropFirst()) { hovering in
                        withAnimation(UmbarMotion.hoverHint(reduce: reduceMotion)) { isHovering = hovering }
                    }
                    .onReceive(MotionFrameRenderer.HoverFixture.shared.$approach.dropFirst()) { pointerApproach = $0 }
                    #endif
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        // C7-H: the eye-break reminder hangs from the closed island as a
        // banner; it does not open the panel or take the keyboard. Behind
        // the island, so the island's ears and hover stay on top.
        .background(alignment: .top) { EyeBreakBannerSlot(neckWidth: computedChinWidth) }
        .background(alignment: .top) { CritterLayer(islandWidth: computedChinWidth, pointerNear: isHovering || pointerApproach > 0) }
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .umbarTypefaceFromDefaults()
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading, spacing: PanelLayout.headerSpacing) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                        .transition(.closedContent(reduce: reduceMotion))
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && musicEarsActive && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                              .transition(musicEarsArriving ? .identity : .closedContent(reduce: reduceMotion))
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && !musicEarsActive && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                              .transition(.closedContent(reduce: reduceMotion))
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: PanelLayout.headerHeight(notchHeight: vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                               .transition(.islandContent(delay: UmbarMotion.headerDelay, reduce: reduceMotion))
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                              .umbarFont(.display, size: 13)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }

                      // F19: live activities grow the closed island downward.
                      if vm.notchState == .closed && !coordinator.sneakPeek.show && !vm.hideOnClosed {
                          LiveActivityClosedStrip(notchWidth: vm.closedNotchSize.width, notchHeight: vm.effectiveClosedNotchHeight)
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    if eyeBreak.isPromptingInPanel {
                        EyeBreakPromptView()
                    } else if focusTimer.isShowingBanner {
                        FocusTimerBannerView()
                    } else if hudAccessCard.isShowing {
                        HUDAccessCardView()
                    } else {
                        PanelPageView(albumArtNamespace: albumArtNamespace)
                    }
                }
                // minHeight 0: the page takes what the header leaves and no
                // more. Without it a frame reports its content's height, a
                // tall page grows the island past its fixed size, and the
                // island is centred in that size: the header moves up.
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .transition(.islandContent(delay: UmbarMotion.pageDelay, reduce: reduceMotion))
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
        .onChange(of: focusTimer.isShowingBanner) { _, showing in
            // F18: same as the eye-break reminder; pop open for the banner, fold after.
            if showing { doOpen() } else if !isHovering && pointerMayClose { vm.close() }
        }
        .onChange(of: hudAccessCard.isShowing) { _, showing in
            // K13: a volume change can bring the card up while the notch is
            // closed; it folds again when the card goes unless hovered.
            if showing { doOpen() } else if !isHovering && pointerMayClose { vm.close() }
        }
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    /// The inline sneak peek: the song name and artist over the notch itself.
    private var inlineMusicPeekShowing: Bool {
        coordinator.expandingView.show && coordinator.expandingView.type == .music
            && Defaults[.sneakPeekStyles] == .inline
    }

    private var showsClosedTitle: Bool {
        ClosedMusicLayout.showsTitle(
            enabled: closedSongTitleEnabled, title: musicManager.songTitle,
            notchHeight: vm.effectiveClosedNotchHeight, inlinePeekShowing: inlineMusicPeekShowing)
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        let art = ClosedMusicLayout.artSide(notchHeight: vm.effectiveClosedNotchHeight)
        let titled = showsClosedTitle
        // Folds toward the notch with the ears; under Reduce Motion only
        // the opacity changes.
        let artScale = reduceMotion ? 1 : 0.5 + 0.5 * musicContent
        HStack(spacing: 0) {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(width: art, height: art)
                .scaleEffect(artScale, anchor: .center)
                .opacity(musicContent)
                .frame(width: art * musicWidth)

            if titled {
                // Folds from its trailing end, so it stays beside the art
                // instead of sliding over it.
                ClosedSongTitle(title: musicManager.songTitle, reduceMotion: reduceMotion)
                    .frame(width: ClosedMusicLayout.titleWidth, alignment: .leading)
                    .padding(.leading, ClosedMusicLayout.titleGap)
                    .opacity(musicContent)
                    .frame(width: ClosedMusicLayout.titleExtra(showsTitle: true) * musicWidth, alignment: .leading)
                    .clipped()
                    .transition(.opacity)
            }

            Color.clear.frame(width: ClosedMusicLayout.earGap * musicWidth)

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .umbarFont(.display, size: 13)
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .umbarFont(.display, size: 13)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    // Folded, the black is as wide as the empty closed
                    // island's, so taking the ears out of the layout after
                    // they fold does not move the shape.
                    width: inlineMusicPeekShowing
                        ? 380
                        : vm.closedNotchSize.width - 20
                            + (20 - cornerRadiusInsets.closed.top) * musicWidth
                )

            Color.clear.frame(width: ClosedMusicLayout.earGap * musicWidth)

            // The right ear mirrors the name's width, so the island stays
            // centred on the camera; the spectrum keeps the outer edge.
            if titled {
                Color.clear
                    .frame(width: ClosedMusicLayout.titleExtra(showsTitle: true) * musicWidth)
                    .transition(.opacity)
            }

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(0, art + gestureProgress / 2),
                height: art,
                alignment: .center
            )
            .opacity(musicContent)
            .frame(width: max(0, art + gestureProgress / 2) * musicWidth)
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    // MARK: - Closed music presence

    private var noAnimation: Transaction {
        var t = Transaction()
        t.disablesAnimations = true
        return t
    }

    /// Called with each new `isPlaying`, inside MusicManager's own
    /// `withAnimation(.smooth)`: every change here names its animation, so
    /// the ears never ride that one.
    private func musicPlaybackChanged(_ playing: Bool) {
        switch musicPresence.playbackChanged(isPlaying: playing) {
        case .none:
            break
        case .enter:
            showMusicEars()
        case .scheduleHide(let token):
            DispatchQueue.main.asyncAfter(deadline: .now() + ClosedMusicPresence.hideDelay) {
                if musicPresence.hideDue(token: token) { hideMusicEars() }
            }
        }
    }

    private func showMusicEars() {
        if !musicEarsActive {
            // In at nothing, out of the notch on the next pass. With the face
            // on, the face's ears are already out: only the content fades in.
            withTransaction(noAnimation) {
                musicContent = 0
                musicWidth = Defaults[.showNotHumanFace] ? 1 : 0
                musicEarsArriving = true
                musicEarsActive = true
            }
        }
        DispatchQueue.main.async {
            guard musicPresence.shown else { return }
            let arrived = { musicEarsArriving = false }
            if reduceMotion || vm.notchState != .closed {
                withTransaction(noAnimation) { musicWidth = 1 }
                withAnimation(UmbarMotion.ear(reduce: true)) { musicContent = 1 } completion: { arrived() }
            } else {
                withAnimation(UmbarMotion.ear()) {
                    musicContent = 1
                    musicWidth = 1
                } completion: { arrived() }
            }
        }
    }

    private func hideMusicEars() {
        let face = Defaults[.showNotHumanFace]
        guard vm.notchState == .closed else {
            withTransaction(noAnimation) {
                musicContent = 0
                musicWidth = 0
                musicEarsActive = false
            }
            return
        }
        let finish = {
            guard !musicPresence.shown else { return }
            if face {
                // Hand over to the face with the closed-content transitions.
                withAnimation(UmbarMotion.ear(reduce: reduceMotion)) { musicEarsActive = false }
            } else {
                // Folded to the empty island's width: nothing left to see move.
                withTransaction(noAnimation) {
                    musicWidth = 0
                    musicEarsActive = false
                }
            }
        }
        if reduceMotion {
            withAnimation(UmbarMotion.ear(reduce: true)) {
                musicContent = 0
            } completion: { finish() }
        } else {
            withAnimation(UmbarMotion.ear()) {
                musicContent = 0
                if !face { musicWidth = 0 }
            } completion: { finish() }
        }
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        withAnimation(UmbarMotion.open(reduce: reduceMotion)) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    /// The pointer-driven closes (pointer exit, a popover or share sheet
    /// ending while the pointer is away) apply only while this panel does not
    /// hold the keyboard (AC-1.4 R1.2, Can B1/C3).
    private var pointerMayClose: Bool {
        PanelKeyPolicy.closesOnPointerExit(isKey: PanelKeyController.shared.isKey(vm))
    }

    private func handleHover(_ hovering: Bool) {
        // SwiftUI reports exits with the pointer standing still on the
        // notch (NotchHoverPolicy.swift), so neither event decides anything
        // on its own: the pending open checks the pointer when it fires, and
        // an open panel folds only through the pointer watch.
        hoverLog.debug("onHover \(hovering, privacy: .public) state=\(String(describing: vm.notchState), privacy: .public)")
        if coordinator.firstLaunch { return }

        if hovering {
            let wasHovering = isHovering
            withAnimation(UmbarMotion.hoverHint(reduce: reduceMotion)) {
                isHovering = true
            }
            guard vm.notchState == .closed else { return }

            if !wasHovering && Defaults[.enableHaptics] {
                haptics.toggle()
            }

            guard !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }

            hoverTask?.cancel()
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          !self.coordinator.sneakPeek.show,
                          self.pointerIsOnClosedNotch() else { return }
                    self.hoverLog.debug("open: pointer rested on the closed notch")
                    self.doOpen()
                }
            }
        } else if vm.notchState == .closed, !pointerIsOnClosedNotch() {
            // A real exit before the open delay ran out: a pass-over, not a rest.
            hoverTask?.cancel()
            withAnimation(UmbarMotion.hoverHint(reduce: reduceMotion)) {
                isHovering = false
            }
        }
    }

    // MARK: - Pointer geometry

    private var notchWindow: NSWindow? {
        NSApp.windows.first { ($0 as? BoringNotchSkyLightWindow)?.viewModel === vm }
    }

    private var closedNotchScreenRect: CGRect? {
        guard let window = notchWindow, !closedHoverFrame.isEmpty else { return nil }
        return NotchHoverGeometry.screenRect(ofViewFrame: closedHoverFrame, inWindowFrame: window.frame)
    }

    private func updateClickThrough() {
        clickThrough.update(window: notchWindow, isOpen: vm.notchState == .open, closedRect: closedNotchScreenRect)
        // The approach lean is the closed island's alone, and only when there
        // is an island to see (not hidden for a fullscreen app).
        let leans = vm.notchState == .closed && !reduceMotion && vm.effectiveClosedNotchHeight > 0
        let pointer = dripPointer
        approachMonitor.update(
            closedRect: leans ? closedNotchScreenRect : nil,
            onChange: { pointerApproach = $0 },
            onDrip: dripEffectEnabled ? { pointer.reading = $0 } : nil
        )
    }

    private func pointerIsOnClosedNotch() -> Bool {
        guard let rect = closedNotchScreenRect else { return vm.isMouseHovering() }
        return NotchHoverGeometry.contains(rect, NSEvent.mouseLocation)
    }

    private func pointerIsOnOpenPanel() -> Bool {
        guard let window = notchWindow else { return vm.isMouseHovering() }
        let rect = NotchHoverGeometry.openRect(
            windowFrame: window.frame,
            closedRect: closedNotchScreenRect ?? .null
        )
        return NotchHoverGeometry.contains(rect, NSEvent.mouseLocation)
    }

    /// Everything that holds a pointer-exit fold back. The tracker keeps
    /// asking, so the fold happens once the hold is gone and the pointer is
    /// still away.
    private var pointerExitMayClose: Bool {
        !vm.isBatteryPopoverActive
            && !SharingStateManager.shared.preventNotchClose
            && !focusTimer.isShowingBanner
            // A key panel ignores the pointer leaving (AC-1.4 R1.2
            // exception): it closes on Esc, an outside click or the
            // shortcut again, through PanelKeyController.
            && pointerMayClose
    }

    /// Samples the pointer while the panel is open and folds it after
    /// NotchHoverTracker.closeDelay outside the open rect.
    ///
    /// Polling instead of tracking-area events is the point of the fix: the
    /// events are what lie (NotchHoverPolicy.swift). 20 Hz keeps the fold
    /// within 50 ms of the 500 ms deadline; the loop exists only while the
    /// panel is open and reads two values per turn.
    private func startPointerWatch() {
        pointerWatch?.cancel()
        hoverTracker.reset()
        pointerWatch = Task { @MainActor in
            while !Task.isCancelled, vm.notchState == .open {
                let inside = pointerIsOnOpenPanel()
                if inside != isHovering {
                    withAnimation(UmbarMotion.hoverHint(reduce: reduceMotion)) { isHovering = inside }
                }
                let due = hoverTracker.sample(isInside: inside, at: ProcessInfo.processInfo.systemUptime)
                if due && pointerExitMayClose {
                    hoverLog.debug("close: pointer outside the open panel for \(NotchHoverTracker.closeDelay, privacy: .public)s")
                    vm.close()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopPointerWatch() {
        pointerWatch?.cancel()
        pointerWatch = nil
        hoverTracker.reset()
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
