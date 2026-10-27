//
//  PowerSourceParsing.swift
//  boringNotch
//
//  F19 live activities: reads one IOPowerSources description dictionary
//  (IOPSGetPowerSourceDescription) into "charging, n %, m minutes to full".
//
//  Foundation-only so umbarTests can compile it without IOKit. The key
//  strings are the values of the IOKit constants (IOPSKeys.h), spelled out
//  here for that reason: kIOPSPowerSourceStateKey, kIOPSACPowerValue,
//  kIOPSIsChargingKey, kIOPSIsChargedKey, kIOPSCurrentCapacityKey,
//  kIOPSMaxCapacityKey, kIOPSTimeToFullChargeKey, kIOPSTypeKey,
//  kIOPSInternalBatteryType.
//

import Foundation

/// The battery while it is charging on external power.
struct ChargingStatus: Equatable, Sendable {
    /// 0...100.
    let percent: Int
    /// Minutes until full, or nil while macOS is still estimating (it reports
    /// -1 for the first minute or two after the charger is connected).
    let minutesToFull: Int?
}

enum PowerSourceParser {
    static let stateKey = "Power Source State"
    static let acPowerValue = "AC Power"
    static let isChargingKey = "Is Charging"
    static let isChargedKey = "Is Charged"
    static let currentCapacityKey = "Current Capacity"
    static let maxCapacityKey = "Max Capacity"
    static let timeToFullKey = "Time to Full Charge"
    static let typeKey = "Type"
    static let internalBatteryType = "InternalBattery"

    /// Returns a status only while the internal battery is on external power
    /// and actually charging. Nil when on battery, when charging is paused
    /// (Optimized Battery Charging holding at 80 %, or a full battery), and for
    /// a UPS or other external source.
    static func chargingStatus(from description: [String: Any]) -> ChargingStatus? {
        if let type = description[typeKey] as? String, type != internalBatteryType { return nil }
        guard description[stateKey] as? String == acPowerValue,
              bool(description[isChargingKey]) == true,
              bool(description[isChargedKey]) != true,
              let current = int(description[currentCapacityKey]),
              let maxCap = int(description[maxCapacityKey]), maxCap > 0
        else { return nil }

        // Apple laptops report Max Capacity = 100, so this is the identity
        // there; the division covers sources that report raw mAh.
        let percent = min(100, max(0, Int((Double(current) / Double(maxCap) * 100).rounded())))
        let minutes = int(description[timeToFullKey]).flatMap { $0 > 0 ? $0 : nil }
        return ChargingStatus(percent: percent, minutesToFull: minutes)
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let i as Int: return i
        default: return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return nil
        }
    }
}
