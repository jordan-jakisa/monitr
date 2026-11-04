import Foundation

/// How Monitr names processes and finds the app that owns them.
public enum Naming {
    /// "com.apple.WebKit.WebContent" reads as "Web Content"; the app it belongs to is shown
    /// beside it, so the reverse-DNS prefix adds nothing but noise.
    public static func friendlyName(_ raw: String) -> String {
        let parts = raw.split(separator: ".")
        guard parts.count >= 3, let first = parts.first, first.first?.isLowercase == true,
              let last = parts.last, last.count > 1 else { return raw }
        var out = ""
        let chars = Array(last)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase {
                let prev = chars[i - 1]
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || (prev.isUppercase && nextLower) { out.append(" ") }
            }
            out.append(c)
        }
        return out
    }


    public static func outermostBundle(in path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

}
