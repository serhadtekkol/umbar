import AppKit
import Carbon.HIToolbox
import CoreGraphics
import QARunnerCore

/// Reads the facts the gates decide on. Nothing here changes system state.
enum SystemState {
    /// §3.2 rule 6. The two dictionary keys are the string values of the
    /// `kCGSessionOnConsoleKey` macro and the undocumented-but-stable
    /// `CGSSessionScreenIsLocked` key (present only while locked).
    static func session() -> SessionSnapshot {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        let onConsole = dict?["kCGSSessionOnConsoleKey"] as? Bool
        let locked = (dict?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        return SessionSnapshot(onConsole: dict == nil ? nil : (onConsole ?? false),
                               screenLocked: locked,
                               secureInput: IsSecureEventInputEnabled())
    }

    static func killFilePresent(paths: RunnerPaths) -> Bool {
        var st = stat()
        // lstat: a KILL symlink (even a dangling one) also counts.
        return lstat(paths.killFile, &st) == 0
    }

    /// `defaults read -g com.apple.sound.beep.feedback`, via CFPreferences
    /// (no subprocess).
    static func beepFeedback() -> Int? {
        let v = CFPreferencesCopyAppValue("com.apple.sound.beep.feedback" as CFString, kCFPreferencesAnyApplication)
        return (v as? NSNumber)?.intValue
    }

    /// Reads `~/umbar-qa/silent-precondition` (§3.7 rule 2).
    static func silentAssertion(paths: RunnerPaths, armedSince: Date?) -> Bool {
        let path = paths.silentAssertion
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size < 256 else { return false }
        let contents = try? String(contentsOfFile: path, encoding: .utf8)
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        return AudioPolicy.isSilentAssertionValid(contents: contents, modifiedAt: mtime, armedSince: armedSince)
    }

    /// The built-in display with the notch, in Quartz global coordinates.
    static func notchDisplay() -> (geometry: DisplayGeometry, displayID: CGDirectDisplayID, scale: CGFloat)? {
        for screen in NSScreen.screens {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            let notchWidth = screen.frame.width - left.width - right.width
            return (DisplayGeometry(bounds: CGDisplayBounds(id), notchWidth: notchWidth), id, screen.backingScaleFactor)
        }
        return nil
    }
}
