//
//  MediaRemoteAdapterBundle.swift
//  boringNotch
//

import Foundation

/// Locates the MediaRemote adapter resources inside the app bundle.
///
/// The adapter is a framework that `/usr/bin/perl` loads with DynaLoader; it is
/// embedded in `Contents/Frameworks` but deliberately **not linked** into the
/// app, so it never loads into the app process. It backs the default
/// `.nowPlaying` source; see `NowPlayingAdapterProcess` for its lifetime.
enum MediaRemoteAdapterBundle {
    /// Perl driver script, shipped as an app resource.
    static var scriptURL: URL? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    }

    /// Path of the embedded adapter framework, whether or not it exists.
    static var frameworkPath: String? {
        Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
    }

    /// `true` when both the script and the framework are present in this build.
    static var isAvailable: Bool {
        guard let scriptURL, let frameworkPath else { return false }
        return FileManager.default.fileExists(atPath: scriptURL.path)
            && FileManager.default.fileExists(atPath: frameworkPath)
    }
}
