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
    @Test func showingTheTileNeverStartsTheCamera() {
        var session = MirrorSession()
        #expect(session.update(conditions()) == nil)
        #expect(!session.running)
        #expect(session.tileState(conditions()) == .idle)
    }

    @Test func tapStartsAndSecondTapStops() {
        var session = MirrorSession()
        #expect(session.tap(conditions()) == .start)
        #expect(session.tileState(conditions()) == .live)
        #expect(session.tap(conditions()) == .stop)
        #expect(!session.running)
    }

    @Test(arguments: [
        conditions(visible: false), // panel closed or another tab
        conditions(present: false), // locked, asleep, user switched
        conditions(enabled: false), // setting turned off
        conditions(available: false), // camera unplugged
        conditions(access: .denied), // revoked in System Settings
    ])
    func losingAnyConditionStops(_ lost: MirrorConditions) {
        var session = MirrorSession()
        _ = session.tap(conditions())
        #expect(session.update(lost) == .stop)
        #expect(!session.running)
    }

    @Test func reopeningAfterAStopDoesNotRestart() {
        var session = MirrorSession()
        _ = session.tap(conditions())
        _ = session.update(conditions(visible: false))
        // Next hover opens the panel on Şimdi again.
        #expect(session.update(conditions()) == nil)
        #expect(session.tileState(conditions()) == .idle)
    }

    @Test func tabAwayAndBackDoesNotRestart() {
        var session = MirrorSession()
        _ = session.tap(conditions())
        #expect(session.update(conditions(visible: false)) == .stop)
        #expect(session.update(conditions(visible: true)) == nil)
    }

    @Test func repeatedUpdatesAreIdempotent() {
        var session = MirrorSession()
        _ = session.tap(conditions())
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

    @Test func tapWithoutCameraDoesNothing() {
        var session = MirrorSession()
        #expect(session.tap(conditions(available: false)) == nil)
        #expect(session.tileState(conditions(available: false)) == .unavailable)
    }

    @Test func tapWhenDeniedOpensSettingsAndNeverStarts() {
        var session = MirrorSession()
        let denied = conditions(access: .denied)
        #expect(session.tap(denied) == .openPrivacySettings)
        #expect(session.update(denied) == nil)
        #expect(session.tileState(denied) == .denied)
    }

    @Test func tapWhenUndeterminedAsksThenStartsOnGrant() {
        var session = MirrorSession()
        let asking = conditions(access: .notDetermined)
        #expect(session.tileState(asking) == .needsAccess)
        #expect(session.tap(asking) == .requestAccess)
        #expect(session.update(asking) == nil)
        #expect(session.update(conditions(access: .granted)) == .start)
    }

    @Test func grantArrivingAfterThePanelClosedDoesNotStart() {
        var session = MirrorSession()
        _ = session.tap(conditions(access: .notDetermined))
        _ = session.update(conditions(access: .notDetermined, visible: false))
        #expect(session.update(conditions(access: .granted)) == nil)
    }

    @Test func denialAfterAskingStaysOff() {
        var session = MirrorSession()
        _ = session.tap(conditions(access: .notDetermined))
        #expect(session.update(conditions(access: .denied)) == nil)
        #expect(!session.running)
    }

    @Test func sessionEndedReturnsToIdleWithoutRetrying() {
        var session = MirrorSession()
        _ = session.tap(conditions())
        session.sessionEnded()
        #expect(session.update(conditions()) == nil)
        #expect(session.tileState(conditions()) == .idle)
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
        _ = session.tap(conditions())
        #expect(session.runTimeElapsed(generation: session.generation) == .stop)
        #expect(!session.running)
        // Back to idle: still in front, but it does not restart by itself.
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
