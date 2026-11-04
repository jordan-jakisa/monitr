import Foundation

/// Human-friendly numbers: bytes, rates, percentages, durations, watts, temperatures.
public enum Fmt {
    public static func bytes(_ b: UInt64) -> String { bytes(Double(b)) }

    public static func bytes(_ v: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var x = v, i = 0
        while x >= 1000 && i < units.count - 1 { x /= 1024; i += 1 }
        if i == 0 { return "\(Int(x)) B" }
        return x >= 100 ? "\(Int(x.rounded())) \(units[i])" : String(format: "%.1f %@", x, units[i])
    }

    /// "↓1.2 MB/s ↑40 KB/s", leaving out a direction that is idle; "–" when both are.
    public static func traffic(down: Double, up: Double) -> String {
        var parts: [String] = []
        if down >= 1 { parts.append("↓" + rate(down)) }
        if up >= 1 { parts.append("↑" + rate(up)) }
        return parts.isEmpty ? "–" : parts.joined(separator: "  ")
    }

    /// Table-width form: "↓4.8M ↑110K", idle directions left out.
    public static func trafficShort(down: Double, up: Double) -> String {
        var parts: [String] = []
        if down >= 1 { parts.append("↓" + shortRate(down)) }
        if up >= 1 { parts.append("↑" + shortRate(up)) }
        return parts.isEmpty ? "–" : parts.joined(separator: " ")
    }

    public static func rate(_ v: Double) -> String { v < 1 ? "0 KB/s" : bytes(v) + "/s" }

    /// Very short form for the menu bar: "1.2M", "340K".
    public static func shortRate(_ v: Double) -> String {
        let units = ["K", "M", "G"]
        var x = v / 1024, i = 0
        while x >= 1000 && i < units.count - 1 { x /= 1024; i += 1 }
        return x >= 10 ? "\(Int(x.rounded()))\(units[i])" : String(format: "%.1f%@", x, units[i])
    }

    public static func percent(_ v: Double) -> String {
        v < 10 && v > 0 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%"
    }

    public static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(max(m, 1))m" }
        let h = m / 60
        return h < 24 ? "\(h)h \(m % 60)m" : "\(h / 24)d \(h % 24)h"
    }

    public static func watts(_ w: Double) -> String {
        if w < 1 { return "\(Int((w * 1000).rounded())) mW" }
        return w < 10 ? String(format: "%.1f W", w) : "\(Int(w.rounded())) W"
    }

    public static func temp(_ t: Double) -> String { "\(Int(t.rounded()))°C" }
}

