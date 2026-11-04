import Foundation

/// Reads `nettop -P -L 1 -x -J bytes_in,bytes_out` output into lifetime bytes per pid.
public enum NettopParser {
    /// Lines look like "com.apple.WebKi.51604,750242664,17013390," after a header line.
    public static func parse(_ data: Data) -> [pid_t: (UInt64, UInt64)] {
        var out: [pid_t: (UInt64, UInt64)] = [:]
        guard let text = String(data: data, encoding: .utf8) else { return out }
        for line in text.split(separator: "\n") where !line.hasPrefix(",") {
            var parts = line.split(separator: ",", omittingEmptySubsequences: false)
            if parts.last == "" { parts.removeLast() }
            guard parts.count >= 3,
                  let tx = UInt64(parts[parts.count - 1]), let rx = UInt64(parts[parts.count - 2]) else { continue }
            let label = parts[0..<(parts.count - 2)].joined(separator: ",")
            guard let dot = label.lastIndex(of: "."), let pid = Int32(label[label.index(after: dot)...]) else { continue }
            out[pid] = (rx, tx)
        }
        return out
    }
}
