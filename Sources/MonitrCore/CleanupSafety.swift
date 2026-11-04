import Foundation

/// Which folders Disk clean may never empty. Everything inside an added folder goes to the
/// Trash, so personal folders, their parents and macOS itself are refused.
public enum CleanupSafety {
    /// Nil when `path` may be a cleanup target; otherwise the reason it may not.
    public static func refusal(for path: String, home h: String) -> String? {
        let p = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let blocked = ["/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin", "/sbin", "/private", "/Volumes",
                       "/etc", "/var", "/opt", "/cores",
                       h, h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Pictures", h + "/Movies", h + "/Music",
                       h + "/Library", h + "/Library/Mobile Documents", h + "/Library/CloudStorage", h + "/Applications",
                       h + "/Public", h + "/Sites"]
        if blocked.contains(p) || h.hasPrefix(p + "/") {
            return "\(tilde(p, home: h)) holds personal files or parts of macOS, so it can't be a cleanup target."
        }
        for root in ["/System/", "/usr/", "/bin/", "/sbin/", "/private/etc/", "/private/var/db/"] where p.hasPrefix(root) {
            return "Folders inside macOS can't be cleanup targets."
        }
        // Inside a personal folder (a project in Documents, say) is still personal.
        for personal in ["/Desktop/", "/Documents/", "/Pictures/", "/Movies/", "/Music/", "/Library/Mobile Documents/",
                         "/Library/CloudStorage/"] where p.hasPrefix(h + personal) {
            return "\(tilde(p, home: h)) is inside a personal folder, so it can't be a cleanup target."
        }
        return nil
    }

    public static func tilde(_ p: String, home: String) -> String {
        p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
