import Foundation

/// Fixed-size history for sparklines. No allocation after init.
public struct Ring: Equatable {
    public private(set) var values: [Double]
    private var head = 0
    public private(set) var count = 0
    /// Total values ever pushed; changes on every push, so views can animate each new point.
    public private(set) var pushes = 0
    public var capacity: Int { values.count }

    public init(capacity: Int) { values = Array(repeating: 0, count: capacity) }

    public mutating func push(_ v: Double) {
        values[head] = v
        head = (head + 1) % values.count
        count = min(count + 1, values.count)
        pushes &+= 1
    }

    /// Oldest to newest.
    public var ordered: [Double] {
        guard count > 0 else { return [] }
        let start = (head - count + values.count) % values.count
        return (0..<count).map { values[(start + $0) % values.count] }
    }

    public var max: Double { values.max() ?? 0 }
}

