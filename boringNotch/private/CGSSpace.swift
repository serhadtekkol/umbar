//
//  CGSSpace.swift
//  boringNotch
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Original source: https://github.com/avaidyam/Parrot/
// Modified by Alexander on 2024-10-27
// Modified 2026-10-26: symbols resolved with dlsym instead of @_silgen_name (card #42)

import AppKit

/// Small Spaces API wrapper.
///
/// Puts the notch windows into a private, always-on-top CGS space so they
/// stay above full-screen apps. Every private symbol is resolved at runtime
/// (`PrivateCGS`). If any is missing, e.g. after an OS update, this type does
/// nothing and the windows keep their public behavior (`level` +
/// `collectionBehavior` set on the panel). Upstream linked the symbols with
/// `@_silgen_name`, which makes dyld abort before `main()` when one is gone.
public final class CGSSpace {
    private let identifier: CGSSpaceID?

    public var windows: Set<NSWindow> = [] {
        didSet {
            guard let identifier, let api = PrivateCGS.api else { return }
            let remove = oldValue.subtracting(self.windows)
            let add = self.windows.subtracting(oldValue)
            let cid = api.defaultConnection()

            api.removeWindowsFromSpaces(cid, remove.map { $0.windowNumber } as NSArray, [identifier] as NSArray)
            api.addWindowsToSpaces(cid, add.map { $0.windowNumber } as NSArray, [identifier] as NSArray)
        }
    }

    /// `true` when the private space exists; `false` means the public fallback
    /// is in effect.
    public var isActive: Bool { identifier != nil }

    /// Initialized `CGSSpace`s *MUST* be de-initialized upon app exit!
    public init(level: Int = 0) {
        guard let api = PrivateCGS.api else {
            NSLog("CGSSpace: private CGS symbols unavailable; using public window level only")
            identifier = nil
            return
        }
        let cid = api.defaultConnection()
        let flag = 0x1 // this value MUST be 1, otherwise, Finder decides to draw desktop icons
        let space = api.spaceCreate(cid, flag, nil)
        api.spaceSetAbsoluteLevel(cid, space, level)
        api.showSpaces(cid, [space] as NSArray)
        identifier = space
    }

    deinit {
        guard let identifier, let api = PrivateCGS.api else { return }
        let cid = api.defaultConnection()
        api.hideSpaces(cid, [identifier] as NSArray)
        api.spaceDestroy(cid, identifier)
    }
}

// MARK: - Private CGS symbols

fileprivate typealias CGSConnectionID = UInt
fileprivate typealias CGSSpaceID = UInt64

/// The private SkyLight/CoreGraphics functions `CGSSpace` needs, resolved with
/// `dlsym`. `api` is `nil` unless **all** of them resolve, so callers never
/// mix private and fallback behavior.
fileprivate struct PrivateCGS {
    let defaultConnection: @convention(c) () -> CGSConnectionID
    let spaceCreate: @convention(c) (CGSConnectionID, Int, NSDictionary?) -> CGSSpaceID
    let spaceDestroy: @convention(c) (CGSConnectionID, CGSSpaceID) -> Void
    let spaceSetAbsoluteLevel: @convention(c) (CGSConnectionID, CGSSpaceID, Int) -> Void
    let addWindowsToSpaces: @convention(c) (CGSConnectionID, NSArray, NSArray) -> Void
    let removeWindowsFromSpaces: @convention(c) (CGSConnectionID, NSArray, NSArray) -> Void
    let hideSpaces: @convention(c) (CGSConnectionID, NSArray) -> Void
    let showSpaces: @convention(c) (CGSConnectionID, NSArray) -> Void

    static let api: PrivateCGS? = {
        #if DEBUG
        // Lets QA exercise the fallback path without an OS that lacks the symbols.
        if ProcessInfo.processInfo.environment["NOTCH_DISABLE_PRIVATE_CGS"] == "1" { return nil }
        #endif
        // The CGS symbols are exported by SkyLight and re-exported through
        // CoreGraphics, which the app already links; RTLD_DEFAULT finds them
        // in either.
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let defaultConnection = sym("_CGSDefaultConnection", (@convention(c) () -> CGSConnectionID).self),
            let spaceCreate = sym("CGSSpaceCreate", (@convention(c) (CGSConnectionID, Int, NSDictionary?) -> CGSSpaceID).self),
            let spaceDestroy = sym("CGSSpaceDestroy", (@convention(c) (CGSConnectionID, CGSSpaceID) -> Void).self),
            let spaceSetAbsoluteLevel = sym("CGSSpaceSetAbsoluteLevel", (@convention(c) (CGSConnectionID, CGSSpaceID, Int) -> Void).self),
            let addWindowsToSpaces = sym("CGSAddWindowsToSpaces", (@convention(c) (CGSConnectionID, NSArray, NSArray) -> Void).self),
            let removeWindowsFromSpaces = sym("CGSRemoveWindowsFromSpaces", (@convention(c) (CGSConnectionID, NSArray, NSArray) -> Void).self),
            let hideSpaces = sym("CGSHideSpaces", (@convention(c) (CGSConnectionID, NSArray) -> Void).self),
            let showSpaces = sym("CGSShowSpaces", (@convention(c) (CGSConnectionID, NSArray) -> Void).self)
        else { return nil }
        return PrivateCGS(
            defaultConnection: defaultConnection, spaceCreate: spaceCreate, spaceDestroy: spaceDestroy,
            spaceSetAbsoluteLevel: spaceSetAbsoluteLevel, addWindowsToSpaces: addWindowsToSpaces,
            removeWindowsFromSpaces: removeWindowsFromSpaces, hideSpaces: hideSpaces, showSpaces: showSpaces
        )
    }()
}
