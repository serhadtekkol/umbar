//
//  AudioLevelProbe.swift
//  boringNotch
//
//  QA aid: with `-UmbarAudioLevelProbe YES` on the command line, a Debug
//  build turns the capture on for 15 seconds and logs what it hears twice a
//  second (category "AudioLevel"), then turns it off. Start music first;
//  the capture runs only while something is playing. Lets the tap be
//  checked on a real Mac with the glow UI out of the picture:
//
//    log stream --predicate 'subsystem == "umbar" && category == "AudioLevel"'
//
//  Only numbers are logged, never samples. Never compiled into Release.
//

#if DEBUG
import Foundation
import os

extension AudioLevelMonitor {
    static func runProbeIfRequested() {
        guard UserDefaults.standard.bool(forKey: "UmbarAudioLevelProbe") else { return }
        let log = Logger(subsystem: "umbar", category: "AudioLevel")
        Task { @MainActor in
            // Give MusicManager time to read the now-playing state first.
            try? await Task.sleep(for: .seconds(3))
            let monitor = AudioLevelMonitor.shared
            log.notice("probe: start, nowPlaying=\(MusicManager.shared.bundleIdentifier ?? "nil", privacy: .public) playing=\(MusicManager.shared.isPlaying, privacy: .public)")
            monitor.setActive(true)
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(500))
                let target: String = switch monitor.target {
                case .processes(let ids)?: "app(\(ids.map(String.init).joined(separator: ",")))"
                case .global?: "global"
                case nil: "none"
                }
                log.notice("""
                    probe: auth=\(String(describing: monitor.authorization), privacy: .public) \
                    running=\(monitor.isRunning, privacy: .public) target=\(target, privacy: .public) \
                    analyses=\(monitor.analysisCount, privacy: .public) \
                    level=\(monitor.level, format: .fixed(precision: 3), privacy: .public) \
                    bass=\(monitor.bass, format: .fixed(precision: 3), privacy: .public) \
                    mid=\(monitor.mid, format: .fixed(precision: 3), privacy: .public) \
                    treble=\(monitor.treble, format: .fixed(precision: 3), privacy: .public)
                    """)
            }
            monitor.setActive(false)
            log.notice("probe: stopped")
        }
    }
}
#endif
