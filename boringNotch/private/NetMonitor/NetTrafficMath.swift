//
//  NetTrafficMath.swift
//  boringNotch
//
//  F17 network traffic: the arithmetic between two counter reads (deltas,
//  resets, smoothing, the 60 s history) and the unit formatting. Foundation
//  only, so umbarTests can compile it without the app.
//

import Foundation

/// One read of an interface's cumulative byte counters.
struct NetCounterSnapshot: Equatable {
    /// Bytes received since the interface came up (64-bit `ifi_ibytes`).
    var rx: UInt64
    /// Bytes sent since the interface came up (64-bit `ifi_obytes`).
    var tx: UInt64
    /// Monotonic seconds (`ProcessInfo.systemUptime`), never wall clock:
    /// a clock change must not turn into a speed spike.
    var time: TimeInterval
}

/// Bytes moved between two snapshots and the time that took.
struct NetTrafficDelta: Equatable {
    var rx: UInt64
    var tx: UInt64
    var interval: TimeInterval

    var rxRate: Double { interval > 0 ? Double(rx) / interval : 0 }
    var txRate: Double { interval > 0 ? Double(tx) / interval : 0 }
}

enum NetCounterMath {
    /// Anything faster than this is not traffic but a bad read. 100 Gbit/s
    /// is well above any interface a Mac has today (the fastest is 10 GbE
    /// and Thunderbolt bridges), so a real reading is never discarded.
    static let maxPlausibleBytesPerSecond: Double = 12_500_000_000

    /// The traffic between `old` and `new`, or nil when there is nothing
    /// trustworthy to report (time did not advance, or the jump is
    /// physically impossible).
    ///
    /// A counter that went *down* means the interface was reset (driver
    /// reload, interface re-attached under the same index); the counter
    /// restarted at zero, so everything it shows now arrived since the reset
    /// and is counted. The counters are 64-bit (`if_data64`), so a genuine
    /// wrap would take decades at 10 Gbit/s and is not modelled separately.
    static func delta(from old: NetCounterSnapshot, to new: NetCounterSnapshot) -> NetTrafficDelta? {
        let interval = new.time - old.time
        guard interval > 0 else { return nil }
        let rx = new.rx >= old.rx ? new.rx - old.rx : new.rx
        let tx = new.tx >= old.tx ? new.tx - old.tx : new.tx
        let limit = maxPlausibleBytesPerSecond * interval
        guard Double(rx) <= limit, Double(tx) <= limit else { return nil }
        return NetTrafficDelta(rx: rx, tx: tx, interval: interval)
    }
}

/// Exponentially smoothed download/upload rate.
///
/// The time constant is in seconds rather than "per sample" so the 1 s
/// (visible) and 5 s (background) cadences settle at the same speed: a 5 s
/// sample moves the average much further than a 1 s one, as it should.
struct NetRateSmoother: Equatable {
    /// 1.5 s: a download that starts shows within ~2 samples, and one
    /// bursty second (a page load) does not make the number jump around.
    var timeConstant: TimeInterval = 1.5
    private(set) var rx: Double = 0
    private(set) var tx: Double = 0
    private(set) var hasValue = false

    /// Below 1 B/s the display would read "0 B/s" anyway; snapping to zero
    /// stops the exponential tail from never quite reaching it.
    private static let floor: Double = 1

    mutating func add(_ delta: NetTrafficDelta) {
        guard delta.interval > 0 else { return }
        if !hasValue {
            rx = delta.rxRate
            tx = delta.txRate
            hasValue = true
            return
        }
        let alpha = 1 - exp(-delta.interval / timeConstant)
        rx += alpha * (delta.rxRate - rx)
        tx += alpha * (delta.txRate - tx)
        if rx < Self.floor { rx = 0 }
        if tx < Self.floor { tx = 0 }
    }

    mutating func reset() {
        rx = 0
        tx = 0
        hasValue = false
    }
}

/// One point of the sparkline.
struct NetRatePoint: Equatable {
    /// Monotonic seconds, same clock as `NetCounterSnapshot.time`.
    var time: TimeInterval
    var rx: Double
    var tx: Double
}

/// The last `window` seconds of rates, by time rather than by count, so the
/// 5 s background points and the 1 s visible points share one axis.
struct NetRateHistory: Equatable {
    var window: TimeInterval = 60
    private(set) var points: [NetRatePoint] = []

    mutating func append(_ point: NetRatePoint) {
        // Out-of-order points cannot happen with one sampler, but a point
        // older than the last would draw the line backwards; drop it.
        if let last = points.last, point.time <= last.time { return }
        points.append(point)
        let cutoff = point.time - window
        if let firstKept = points.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            points.removeFirst(firstKept)
        }
    }

    mutating func removeAll() { points.removeAll() }

    /// The largest rate in the window (either direction), the sparkline's
    /// vertical scale. Never zero, so an idle line draws flat at the bottom.
    var peak: Double {
        max(1, points.reduce(0) { max($0, $1.rx, $1.tx) })
    }
}

/// Human units for rates and totals. Decimal (1 KB = 1000 B), the same
/// convention as Activity Monitor and Finder, so the numbers can be
/// compared with what macOS shows elsewhere.
enum NetByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    /// "0 B/s", "850 KB/s", "1.2 MB/s", "12 MB/s".
    static func rate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        scaled(bytesPerSecond, locale: locale) + "/s"
    }

    /// "0 B", "512 KB", "1.24 GB". Totals get one more digit than rates:
    /// a total is read, not glanced at.
    static func total(_ bytes: UInt64, locale: Locale = .current) -> String {
        scaled(Double(bytes), locale: locale, precise: true)
    }

    /// The closed-ear form, at most four characters plus the unit letter:
    /// "0", "850K", "1.2M", "12M".
    static func compactRate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let (value, index) = normalized(bytesPerSecond)
        if index == 0 { return String(Int(value.rounded())) }
        let letter = String(units[index].prefix(1))
        return number(value, locale: locale, precise: false) + letter
    }

    private static func scaled(_ value: Double, locale: Locale, precise: Bool = false) -> String {
        let (scaledValue, index) = normalized(value)
        if index == 0 { return "\(Int(scaledValue.rounded())) B" }
        return number(scaledValue, locale: locale, precise: precise) + " " + units[index]
    }

    /// Divides by 1000 until the value is below 1000. 999.95 KB rounds to
    /// "1000 KB" in one decimal, so the step happens at 999.5 instead and
    /// the display never shows a four-digit number.
    private static func normalized(_ value: Double) -> (Double, Int) {
        var v = max(0, value.isFinite ? value : 0)
        var index = 0
        while v >= 999.5, index < units.count - 1 {
            v /= 1000
            index += 1
        }
        return (v, index)
    }

    private static func number(_ value: Double, locale: Locale, precise: Bool) -> String {
        let decimals: Int
        if value < 10 {
            decimals = precise ? 2 : 1
        } else if value < 100 {
            decimals = precise ? 1 : 0
        } else {
            decimals = 0
        }
        return String(format: "%.\(decimals)f", locale: locale, value)
    }
}
