import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QARunnerCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// ScreenCaptureKit, in-process (§3.2 rule 1: the `screencapture` CLI is
/// never called). Every capture starts from a `CapturePlan` that
/// `CapturePlanner` already validated; this file only turns a plan into an
/// `SCContentFilter`.
enum Capture {
    enum Failure: Error { case refused(Refusal) }

    static func filter(for plan: CapturePlan, displayID: CGDirectDisplayID) async throws -> (SCContentFilter, CGRect?) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw Failure.refused(Refusal(.permissionMissing, "screen"))
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.refused(Refusal(.noNotchDisplay))
        }
        switch plan {
        case .appWindows(let pid):
            // Including only umbar's application: other apps' windows are
            // excluded from composition, not merely cropped out.
            guard let app = content.applications.first(where: { $0.processID == pid }) else {
                throw Failure.refused(Refusal(.umbarNotRunning, "sck"))
            }
            return (SCContentFilter(display: display, including: [app], exceptingWindows: []), nil)
        case .displayRect(let rect):
            let bounds = CGDisplayBounds(displayID)
            let local = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            return (SCContentFilter(display: display, excludingWindows: []), local)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw Failure.refused(Refusal(.noFinderDropWindow, "sck"))
            }
            return (SCContentFilter(desktopIndependentWindow: window), nil)
        }
    }

    static func configuration(sourceRect: CGRect?, filter: SCContentFilter, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let size = sourceRect?.size ?? filter.contentRect.size
        if let sourceRect { config.sourceRect = sourceRect }
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.showsCursor = false
        // Silent by construction (§3.5 record.*): neither system audio nor
        // the microphone is captured.
        config.capturesAudio = false
        config.captureMicrophone = false
        return config
    }

    static func screenshotPNG(plan: CapturePlan, displayID: CGDirectDisplayID, scale: CGFloat) async throws -> Data {
        let (filter, rect) = try await filter(for: plan, displayID: displayID)
        let config = configuration(sourceRect: rect, filter: filter, scale: scale)
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw Failure.refused(Refusal(.ioError, "capture"))
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.refused(Refusal(.ioError, "png"))
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.refused(Refusal(.ioError, "png")) }
        return data as Data
    }
}

/// One silent screen recording at a time, at most 30 s (§3.5 record.*).
@MainActor
final class Recorder: NSObject, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var stopTask: Task<Void, Never>?
    private(set) var file: String?
    private var startedAt: Date?

    var isRecording: Bool { stream != nil }

    func start(plan: CapturePlan, displayID: CGDirectDisplayID, scale: CGFloat, path: String, maxSeconds: Int) async throws {
        guard stream == nil else { throw Capture.Failure.refused(Refusal(.recordingActive)) }
        // SCRecordingOutput creates the file itself, so O_EXCL is not
        // available; the caller checked the path against WritePolicy and
        // this check refuses to replace anything that already exists.
        guard !FileManager.default.fileExists(atPath: path) else {
            throw Capture.Failure.refused(Refusal(.ioError, "exists"))
        }
        let (filter, rect) = try await Capture.filter(for: plan, displayID: displayID)
        let config = Capture.configuration(sourceRect: rect, filter: filter, scale: scale)
        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = URL(fileURLWithPath: path)
        recConfig.outputFileType = .mov
        let output = SCRecordingOutput(configuration: recConfig, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            throw Capture.Failure.refused(Refusal(.ioError, "record"))
        }
        self.stream = stream
        self.output = output
        self.file = path
        self.startedAt = Date()
        let limit = UInt64(min(maxSeconds, CommandLimits.recordMaxSeconds.upperBound))
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: limit * 1_000_000_000)
            guard !Task.isCancelled else { return }
            _ = await self?.stop()
        }
    }

    /// Returns the file and duration, or nil when nothing was recording.
    func stop() async -> (file: String, seconds: Double)? {
        guard let stream, let file else { return nil }
        stopTask?.cancel()
        stopTask = nil
        try? await stream.stopCapture()
        let seconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        self.stream = nil
        self.output = nil
        self.file = nil
        self.startedAt = nil
        return (file, seconds)
    }
}
