//
//  MirrorPolicyTests.swift
//  umbarTests
//
//  The mirror's start/stop policy and its permission rule. Pure values
//  only: no camera is opened, no AVFoundation is linked.
//

import Foundation
import Testing

private func conditions(enabled: Bool = true, access: MirrorAccess = .granted, available: Bool = true,
                        visible: Bool = true, present: Bool = true) -> MirrorConditions {
    MirrorConditions(enabled: enabled, access: access, cameraAvailable: available,
                     tileVisible: visible, userPresent: present)
}

@Suite("MirrorSession", .timeLimit(.minutes(1)))
struct MirrorSessionTests {
    @Test func showingTheTabStartsTheCamera() {
        var session = MirrorSession()
        #expect(session.update(conditions()) == .start)
        #expect(session.running)
        #expect(session.tileState(conditions()) == .live)
    }

    @Test func nothingStartsWhileTheTabIsNotShown() {
        var session = MirrorSession()
        #expect(session.update(conditions(visible: false)) == nil)
        #expect(session.update(conditions(enabled: false)) == nil)
        #expect(session.update(conditions(present: false)) == nil)
        #expect(!session.running)
    }

    @Test(arguments: [
        conditions(visible: false), // panel closed or another tab
        conditions(present: false), // locked, asleep, screen saver, user switched
        conditions(enabled: false), // setting turned off
        conditions(available: false), // camera unplugged
        conditions(access: .denied), // revoked in System Settings
    ])
    func losingAnyConditionStops(_ lost: MirrorConditions) {
        var session = MirrorSession()
        _ = session.update(conditions())
        #expect(session.update(lost) == .stop)
        #expect(!session.running)
    }

    @Test func tabAwayAndBackStartsAgain() {
        var session = MirrorSession()
        _ = session.update(conditions())
        #expect(session.update(conditions(visible: false)) == .stop)
        #expect(session.update(conditions()) == .start)
    }

    @Test func tapOnTheLivePreviewStopsUntilTheTabIsShownAgain() {
        var session = MirrorSession()
        _ = session.update(conditions())
        #expect(session.tap(conditions()) == .stop)
        #expect(session.held)
        // Still on the tab: it stays off.
        #expect(session.update(conditions()) == nil)
        #expect(session.tileState(conditions()) == .idle)
        // Leave and come back: on again.
        _ = session.update(conditions(visible: false))
        #expect(session.update(conditions()) == .start)
    }

    @Test func tapOnTheIdlePreviewStartsIt() {
        var session = MirrorSession()
        _ = session.update(conditions())
        _ = session.tap(conditions())
        #expect(session.tap(conditions()) == .start)
        #expect(session.running)
    }

    @Test func repeatedUpdatesAreIdempotent() {
        var session = MirrorSession()
        _ = session.update(conditions())
        #expect(session.update(conditions()) == nil)
        _ = session.update(conditions(visible: false))
        #expect(session.update(conditions(visible: false)) == nil)
    }

    @Test func tapWhileHiddenDoesNothing() {
        var session = MirrorSession()
        #expect(session.tap(conditions(visible: false)) == nil)
        #expect(session.tap(conditions(enabled: false)) == nil)
        #expect(session.tap(conditions(present: false)) == nil)
    }

    @Test func noCameraMeansNoStartAndNoTap() {
        var session = MirrorSession()
        #expect(session.update(conditions(available: false)) == nil)
        #expect(session.tap(conditions(available: false)) == nil)
        #expect(session.tileState(conditions(available: false)) == .unavailable)
    }

    @Test func deniedNeverStartsAndTapOpensSettings() {
        var session = MirrorSession()
        let denied = conditions(access: .denied)
        #expect(session.update(denied) == nil)
        #expect(session.tap(denied) == .openPrivacySettings)
        #expect(session.tileState(denied) == .denied)
    }

    /// Rule 2: showing the tab never raises the camera prompt by itself.
    @Test func showingTheTabNeverAsksForAccess() {
        var session = MirrorSession()
        let asking = conditions(access: .notDetermined)
        #expect(session.update(asking) == nil)
        #expect(session.tileState(asking) == .needsAccess)
    }

    @Test func tapWhenUndeterminedAsksThenStartsOnGrant() {
        var session = MirrorSession()
        let asking = conditions(access: .notDetermined)
        #expect(session.tap(asking) == .requestAccess)
        #expect(session.update(conditions(access: .granted)) == .start)
    }

    @Test func grantArrivingAfterThePanelClosedDoesNotStart() {
        var session = MirrorSession()
        _ = session.tap(conditions(access: .notDetermined))
        _ = session.update(conditions(access: .notDetermined, visible: false))
        #expect(session.update(conditions(access: .granted, visible: false)) == nil)
    }

    @Test func denialAfterAskingStaysOff() {
        var session = MirrorSession()
        _ = session.tap(conditions(access: .notDetermined))
        #expect(session.update(conditions(access: .denied)) == nil)
        #expect(!session.running)
    }

    @Test func sessionEndedDoesNotRetryWhileTheTabStays() {
        var session = MirrorSession()
        _ = session.update(conditions())
        session.sessionEnded()
        #expect(session.update(conditions()) == nil)
        #expect(session.tileState(conditions()) == .idle)
    }
}

@Suite("MirrorTabPolicy", .timeLimit(.minutes(1)))
struct MirrorTabPolicyTests {
    @Test func aPanelNeverReopensOnAyna() {
        // "Open last tab" on: hovering the notch must not light the camera.
        #expect(!MirrorTabPolicy.keepsPageAcrossClose(isMirror: true, openLastTab: true))
        #expect(!MirrorTabPolicy.keepsPageAcrossClose(isMirror: true, openLastTab: false))
    }

    @Test func otherPagesFollowOpenLastTab() {
        #expect(MirrorTabPolicy.keepsPageAcrossClose(isMirror: false, openLastTab: true))
        #expect(!MirrorTabPolicy.keepsPageAcrossClose(isMirror: false, openLastTab: false))
    }
}

@Suite("MirrorAccessPolicy", .timeLimit(.minutes(1)))
struct MirrorAccessPolicyTests {
    @Test func onlyTheUsersOffToOnFlipPrompts() {
        #expect(MirrorAccessPolicy.requestsOnEnable(wasEnabled: false, isEnabled: true, access: .notDetermined))
    }

    @Test func alreadyOnNeverPrompts() {
        // Launch with the setting on, or the toggle set to its current value.
        #expect(!MirrorAccessPolicy.requestsOnEnable(wasEnabled: true, isEnabled: true, access: .notDetermined))
    }

    @Test func turningOffNeverPrompts() {
        #expect(!MirrorAccessPolicy.requestsOnEnable(wasEnabled: true, isEnabled: false, access: .notDetermined))
        #expect(!MirrorAccessPolicy.requestsOnEnable(wasEnabled: false, isEnabled: false, access: .notDetermined))
    }

    @Test(arguments: [MirrorAccess.granted, .denied])
    func answeredAccessNeverPrompts(_ access: MirrorAccess) {
        #expect(!MirrorAccessPolicy.requestsOnEnable(wasEnabled: false, isEnabled: true, access: access))
    }
}

@Suite("MirrorTileState capture", .timeLimit(.minutes(1)))
struct MirrorTileCaptureTests {
    @Test func onlyTheLiveTileShowsTheCameraPicture() {
        #expect(MirrorTileState.live.showsCameraPicture)
        for state in [MirrorTileState.idle, .needsAccess, .denied, .unavailable] {
            #expect(!state.showsCameraPicture)
        }
    }

    @Test func aLiveTileKeepsTheWindowOutOfCaptureWhateverTheSetting() {
        // The tile reports itself as sensitive while it shows the picture;
        // the user's "hide from screen recording" being off must not matter.
        #expect(CapturePrivacyPolicy.excludesFromCapture(
            userHides: false, sensitiveOnScreen: MirrorTileState.live.showsCameraPicture))
        #expect(!CapturePrivacyPolicy.excludesFromCapture(
            userHides: false, sensitiveOnScreen: MirrorTileState.idle.showsCameraPicture))
    }
}

@Suite("MirrorSession run cap", .timeLimit(.minutes(1)))
struct MirrorRunCapTests {
    @Test func theCapStopsTheRunningPreview() {
        var session = MirrorSession()
        _ = session.update(conditions())
        #expect(session.runTimeElapsed(generation: session.generation) == .stop)
        #expect(!session.running)
        // Back to idle: still on the tab, but it does not restart by itself.
        #expect(session.update(conditions()) == nil)
        #expect(session.tileState(conditions()) == .idle)
    }

    @Test func anEarlierPreviewsCapDoesNotStopALaterOne() {
        var session = MirrorSession()
        _ = session.tap(conditions())
        let first = session.generation
        _ = session.tap(conditions()) // stop
        _ = session.tap(conditions()) // start again
        #expect(session.generation != first)
        #expect(session.runTimeElapsed(generation: first) == nil)
        #expect(session.running)
    }

    @Test func aCapAfterTheStopIsANoOp() {
        var session = MirrorSession()
        _ = session.tap(conditions())
        let generation = session.generation
        _ = session.update(conditions(visible: false))
        #expect(session.runTimeElapsed(generation: generation) == nil)
    }

    @Test func theCapIsFiveMinutes() {
        #expect(MirrorSession.maxRunDuration == 300)
    }
}

@Suite("MirrorTileOwners", .timeLimit(.minutes(1)))
struct MirrorTileOwnersTests {
    private final class Panel {}

    @Test func aRemovedOwnerStopsTheCamera() {
        // Muhittin L3: the external display's panel had the live tile and
        // its window was closed without onDisappear.
        let external = Panel()
        var owners = MirrorTileOwners()
        var session = MirrorSession()
        let added = owners.set(true, for: ObjectIdentifier(external))
        #expect(added)
        _ = session.tap(conditions(visible: owners.anyVisible))
        #expect(session.running)
        let removed = owners.remove(ObjectIdentifier(external))
        #expect(removed)
        #expect(session.update(conditions(visible: owners.anyVisible)) == .stop)
    }

    @Test func anotherScreensTileKeepsItVisible() {
        let builtIn = Panel(), external = Panel()
        var owners = MirrorTileOwners()
        _ = owners.set(true, for: ObjectIdentifier(builtIn))
        _ = owners.set(true, for: ObjectIdentifier(external))
        _ = owners.remove(ObjectIdentifier(external))
        #expect(owners.anyVisible)
    }

    @Test func repeatsAndUnknownOwnersChangeNothing() {
        let panel = Panel(), stranger = Panel()
        var owners = MirrorTileOwners()
        let added = owners.set(true, for: ObjectIdentifier(panel))
        #expect(added)
        let addedAgain = owners.set(true, for: ObjectIdentifier(panel))
        #expect(!addedAgain)
        let removedStranger = owners.remove(ObjectIdentifier(stranger))
        #expect(!removedStranger)
        let removed = owners.remove(ObjectIdentifier(panel))
        #expect(removed)
        let removedAgain = owners.remove(ObjectIdentifier(panel))
        #expect(!removedAgain)
        #expect(!owners.anyVisible)
    }
}

@Suite("MirrorRunReason", .timeLimit(.minutes(1)))
struct MirrorRunReasonTests {
    @Test(arguments: [
        (conditions(enabled: false, present: false), MirrorRunReason.disabled),
        (conditions(visible: false, present: false), .away),
        (conditions(visible: false), .hidden),
        (conditions(access: .denied), .denied),
        (conditions(available: false), .unplug),
        (conditions(), .tap),
    ])
    func stopNamesTheFirstFailingCondition(_ lost: MirrorConditions, _ reason: MirrorRunReason) {
        #expect(MirrorRunReason.stop(after: lost) == reason)
    }

    @Test func everyStopFromUpdateHasAReasonOtherThanTap() {
        // A stop from `update` is never the user's tap; that path passes
        // `.tap` itself. Guards the log against "tap" hiding a real cause.
        for lost in [conditions(enabled: false), conditions(present: false), conditions(visible: false),
                     conditions(access: .denied), conditions(available: false)] {
            var session = MirrorSession()
            _ = session.tap(conditions())
            #expect(session.update(lost) == .stop)
            #expect(MirrorRunReason.stop(after: lost) != .tap)
        }
    }

    @Test func aStartFromShowingTheTabIsLoggedAsTabShown() {
        var session = MirrorSession()
        #expect(session.update(conditions()) == .start)
        #expect(MirrorRunReason.start(afterAccessAnswer: false) == .tabShown)
        #expect(MirrorRunReason.tabShown.rawValue == "tabShown")
    }

    @Test func aStartAfterThePromptIsLoggedAsAccessGranted() {
        #expect(MirrorRunReason.start(afterAccessAnswer: true) == .accessGranted)
    }
}
