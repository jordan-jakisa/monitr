import Foundation

public enum ChartScale {
    /// Rounds the scale up to 1, 2 or 5 times a power of ten, so it rarely jumps.
    public static func niceCeiling(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let mag = pow(10, floor(log10(v)))
        for m in [1.0, 2, 5, 10] where v <= m * mag { return m * mag }
        return 10 * mag
    }
}
