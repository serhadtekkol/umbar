//
//  SysMonitorDefaults.swift
//  boringNotch
//
//  Defaults key for F22 system status. Kept out of Constants.swift like
//  NetMonitorDefaults.swift.
//

import Defaults

extension Defaults.Keys {
    /// Shows CPU, memory, thermal state and the busiest apps on the Ağ page.
    /// On by default: it costs nothing until the page is open.
    static let sysMonitorEnabled = Key<Bool>("sysMonitorEnabled", default: true)
}
