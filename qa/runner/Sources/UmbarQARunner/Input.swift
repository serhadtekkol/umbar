import AppKit
import CoreGraphics
import QARunnerCore

/// A screen point whose owner was verified by `HitTestPolicy` immediately
/// before. Pointer events can only be posted to a `VerifiedPoint`, and the
/// only way to get one is `Input.verify`, so "post an event to an unchecked
/// coordinate" does not compile.
struct VerifiedPoint {
    let point: CGPoint
    fileprivate init(_ point: CGPoint) { self.point = point }
}

/// Synthesizes HID events. Every event is created from a private event
/// source and has its flags set to empty explicitly: a private source does
/// not inherit modifier keys the person at the Air may be holding, and the
/// explicit `[]` makes "no Cmd/Ctrl/Opt/Shift" true by construction (§3.5).
enum Input {
    static func verify(_ point: CGPoint, expect: HitExpectation, dropArea: DropArea) -> Result<VerifiedPoint, Refusal> {
        let hit = AX.hitTest(point)
        if let refusal = HitTestPolicy.verify(hit, expect: expect, runnerPID: getpid(), dropArea: dropArea) {
            return .failure(refusal)
        }
        return .success(VerifiedPoint(point))
    }

    private static func source() -> CGEventSource? {
        CGEventSource(stateID: .privateState)
    }

    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    static func move(to target: VerifiedPoint) {
        post(CGEvent(mouseEventSource: source(), mouseType: .mouseMoved,
                     mouseCursorPosition: target.point, mouseButton: .left))
    }

    /// One left click (§3.5 `pointer.click`; double/right click are not in v1).
    static func click(at target: VerifiedPoint) {
        let src = source()
        post(CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: target.point, mouseButton: .left))
        post(CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: target.point, mouseButton: .left))
    }

    static func mouseDown(at target: VerifiedPoint) {
        post(CGEvent(mouseEventSource: source(), mouseType: .leftMouseDown, mouseCursorPosition: target.point, mouseButton: .left))
    }

    /// Intermediate drag positions are interpolated between two verified
    /// endpoints; they are not themselves targets (nothing is released there).
    static func dragStep(from a: VerifiedPoint, to b: VerifiedPoint, fraction: CGFloat) {
        let p = CGPoint(x: a.point.x + (b.point.x - a.point.x) * fraction,
                        y: a.point.y + (b.point.y - a.point.y) * fraction)
        post(CGEvent(mouseEventSource: source(), mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
    }

    static func mouseUp(at target: VerifiedPoint) {
        post(CGEvent(mouseEventSource: source(), mouseType: .leftMouseUp, mouseCursorPosition: target.point, mouseButton: .left))
    }

    /// One key, no modifiers. The key code comes from the closed `KeyName`
    /// enum; there is no API here that takes a raw key code or text.
    static func press(_ key: KeyName) {
        let src = source()
        post(CGEvent(keyboardEventSource: src, virtualKey: key.virtualKeyCode, keyDown: true))
        post(CGEvent(keyboardEventSource: src, virtualKey: key.virtualKeyCode, keyDown: false))
    }

    /// Media keys are system-defined events of subtype 8 (`NX_SUBTYPE_AUX_
    /// CONTROL_BUTTONS`). data1 = key type << 16 | state << 8, where state
    /// 0xA is key down and 0xB key up. The 0xA00/0xB00 in `modifierFlags`
    /// mirrors the state for consumers that read it from there; it is not a
    /// modifier key (no Cmd/Ctrl/Opt/Shift bit is set).
    static func press(_ key: MediaKeyName) {
        for state in [0xA, 0xB] {
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: (key.nxKeyType << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
