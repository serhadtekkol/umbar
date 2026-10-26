import AudioToolbox
import CoreAudio
import Foundation

/// Default output device volume (§3.7 rule 3): read before a volume key,
/// written back on disarm.
enum Audio {
    private static var mainVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func volume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &mainVolumeAddress, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func setVolume(_ level: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var value = Float32(min(max(level, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &mainVolumeAddress, 0, nil, size, &value) == noErr
    }
}
