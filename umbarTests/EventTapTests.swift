//
//  EventTapTests.swift
//  umbarTests
//
//  Card #45: a passed-through event must go back at +0. Upstream returned
//  it with passRetained, which leaked one CGEvent per system-defined event.
//

import CoreGraphics
import Testing

@Suite("EventTap", .timeLimit(.minutes(1)))
struct EventTapTests {
    @Test func passThroughReturnsTheSameEventWithoutRetainingIt() throws {
        let event = try #require(CGEvent(source: nil))
        let before = CFGetRetainCount(event)
        for _ in 0..<200 {
            let returned = EventTap.passThrough(event)
            #expect(returned.takeUnretainedValue() === event)
        }
        #expect(CFGetRetainCount(event) == before)
    }
}
