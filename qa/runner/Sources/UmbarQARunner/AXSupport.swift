import ApplicationServices
import Foundation
import QARunnerCore

/// Thin, read-only wrappers over the Accessibility C API.
///
/// Scope rule (§3.5 `ax.tree`): this file is only ever called with an
/// application element for umbar's PID or Finder's PID, and Finder reads are
/// limited to the runner-opened window. The callers enforce it; nothing here
/// enumerates other applications.
enum AX {
    /// AX calls block on the target app. A hung umbar must not hang the
    /// runner (and with it remote disarm), so every element gets a short
    /// messaging timeout.
    static let messagingTimeout: Float = 0.5

    static func application(pid: Int32) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// Frame in Quartz global coordinates (top-left origin), as AX reports.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let posRef = attribute(element, kAXPositionAttribute),
              let sizeRef = attribute(element, kAXSizeAttribute),
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func pid(_ element: AXUIElement) -> Int32? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// Value as display text, or nil. Never called for a secure text field:
    /// `AXValuePolicy.shouldReadValue` is checked first by the caller, so the
    /// secret is not even copied into this process.
    static func displayValue(_ element: AXUIElement) -> String? {
        switch attribute(element, kAXValueAttribute) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Builds the `ax.tree` model: role, subrole, identifier, title, value,
    /// frame, enabled (§3.5). Depth- and node-bounded.
    static func tree(of root: AXUIElement, depth: Int) -> AXNode {
        var budget = CommandLimits.axMaxNodes
        return node(root, remainingDepth: depth, budget: &budget)
    }

    private static func node(_ e: AXUIElement, remainingDepth: Int, budget: inout Int) -> AXNode {
        budget -= 1
        let role = string(e, kAXRoleAttribute)
        let subrole = string(e, kAXSubroleAttribute)
        let value = AXValuePolicy.shouldReadValue(role: role, subrole: subrole) ? displayValue(e) : nil
        var kids: [AXNode] = []
        if remainingDepth > 0 {
            for child in children(e) {
                guard budget > 0 else { break }
                kids.append(node(child, remainingDepth: remainingDepth - 1, budget: &budget))
            }
        }
        return AXNode(role: role, subrole: subrole, identifier: string(e, kAXIdentifierAttribute),
                      title: string(e, kAXTitleAttribute), value: value, frame: frame(e),
                      enabled: bool(e, kAXEnabledAttribute), children: kids)
    }

    /// Breadth-first search for elements with the given `AXIdentifier`
    /// under one application, up to depth 12.
    static func find(identifier: String, in app: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        var visited = 0
        while !queue.isEmpty, visited < CommandLimits.axMaxNodes {
            let (e, d) = queue.removeFirst()
            visited += 1
            if string(e, kAXIdentifierAttribute) == identifier { found.append(e) }
            if d < CommandLimits.axDepth.upperBound {
                queue.append(contentsOf: children(e).map { ($0, d + 1) })
            }
        }
        return found
    }

    /// What is under a screen point, with the facts `HitTestPolicy` needs.
    static func hitTest(_ point: CGPoint) -> HitResult {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return HitResult(pid: nil) }
        var document: String?
        if let window = attribute(element, kAXWindowAttribute) {
            document = string(window as! AXUIElement, kAXDocumentAttribute)
        } else if string(element, kAXRoleAttribute) == kAXWindowRole {
            document = string(element, kAXDocumentAttribute)
        }
        return HitResult(pid: pid(element), windowDocument: document,
                         role: string(element, kAXRoleAttribute), subrole: string(element, kAXSubroleAttribute))
    }

    /// PID that keyboard events would reach: the focused element's owner,
    /// else the focused application.
    static func focusedPID() -> Int32? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        if let focused = attribute(system, kAXFocusedUIElementAttribute) {
            return pid(focused as! AXUIElement)
        }
        if let app = attribute(system, kAXFocusedApplicationAttribute) {
            return pid(app as! AXUIElement)
        }
        return nil
    }
}
