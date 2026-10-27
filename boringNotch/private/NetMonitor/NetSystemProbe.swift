//
//  NetSystemProbe.swift
//  boringNotch
//
//  F17: the two system reads behind the network monitor. Neither spawns a
//  process, needs privileges or an entitlement.
//
//  1. Byte counters: the interface MIB sysctl (IFMIB_IFDATA/IFDATA_GENERAL).
//     `getifaddrs` and NET_RT_IFLIST2 were rejected: measured on macOS 27.0
//     (Mac mini, 2026-10-27) both hand an unentitled process counters
//     truncated to 32 bits and rounded to 1 KiB, even in the `if_data64` of
//     `if_msghdr2` (en0 read 888,523,776 while `netstat -ib` printed
//     164,097,538,660). That wraps every 4 GiB, which a fast download
//     crosses in seconds. The MIB returns the exact 64-bit values
//     `netstat -ib` prints, so the monitor can be checked against it byte
//     for byte.
//
//  2. Network identity: the `NetworkSignature` configd publishes for each
//     IPv4 service ("IPv4.Router=…;IPv4.RouterHardwareAddress=…"), the
//     same signature macOS uses to recognise a network. Reading the router
//     MAC ourselves was tried and rejected: on macOS 27 the ARP table
//     (NET_RT_FLAGS + RTF_LLINFO) comes back empty to an unentitled
//     process; only NET_RT_FLAGS_PRIV with the neighbour-cache entitlement
//     sees it.
//

import Darwin
import Foundation
import SystemConfiguration

enum NetSystemProbe {
    // MARK: Counters

    /// Cumulative received/sent bytes of the interface with `index`, or nil
    /// if the interface is gone. One fixed-size sysctl for that interface
    /// only, so the cost does not grow with the number of interfaces.
    static func counters(interfaceIndex index: Int32, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NetCounterSnapshot? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
        var data = ifmibdata()
        var length = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, u_int(mib.count), &data, &length, nil, 0) == 0,
              length == MemoryLayout<ifmibdata>.size
        else { return nil }
        return NetCounterSnapshot(rx: data.ifmd_data.ifi_ibytes, tx: data.ifmd_data.ifi_obytes, time: now)
    }

    // MARK: Identity

    /// What configd knows about the IPv4 service on one interface.
    struct ServiceInfo: Equatable {
        /// "IPv4.Router=…;IPv4.RouterHardwareAddress=…". Missing until the
        /// router's ARP entry resolves, usually within a second of joining.
        var signature: String?
        /// The default gateway's address, when the service has one.
        var router: String?
    }

    /// The IPv4 service bound to `interfaceName`, or nil when the interface
    /// has no IPv4 configuration (IPv6-only, link-local only, not up yet).
    ///
    /// The store is created per call: this runs on a network change and
    /// for at most a few seconds afterwards, so holding a session open
    /// would cost more than it saves.
    static func serviceInfo(interfaceName: String) -> ServiceInfo? {
        guard let store = SCDynamicStoreCreate(nil, "umbar.NetMonitor" as CFString, nil, nil) else { return nil }
        let pattern = "State:/Network/Service/[^/]+/IPv4" as CFString
        guard let values = SCDynamicStoreCopyMultiple(store, nil, [pattern] as CFArray) as? [String: Any] else { return nil }
        for case let dictionary as [String: Any] in values.values {
            guard dictionary["InterfaceName"] as? String == interfaceName else { continue }
            return ServiceInfo(
                signature: (dictionary["NetworkSignature"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                router: dictionary["Router"] as? String)
        }
        return nil
    }
}
