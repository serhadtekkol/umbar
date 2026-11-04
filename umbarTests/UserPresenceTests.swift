//
//  UserPresenceTests.swift
//  umbarTests
//
//  Which system states count as "nobody in front of the screen". The
//  critter waits and the mirror's camera stops while any of them holds.
//

import Testing

@Suite("UserPresence", .timeLimit(.minutes(1)))
struct UserPresenceTests {
    @Test func presentByDefault() {
        #expect(!UserPresence().away)
    }

    @Test(arguments: [
        \UserPresence.asleep, \.displaysAsleep, \.locked, \.sessionInactive, \.screenSaverRunning,
    ] as [WritableKeyPath<UserPresence, Bool> & Sendable])
    func eachStateAloneIsAway(_ flag: WritableKeyPath<UserPresence, Bool> & Sendable) {
        var presence = UserPresence()
        presence[keyPath: flag] = true
        #expect(presence.away)
        presence[keyPath: flag] = false
        #expect(!presence.away)
    }
}
