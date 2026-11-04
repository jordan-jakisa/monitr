import Foundation
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac awake with a macOS power assertion, the same mechanism `caffeinate` uses.
/// The assertion ends when the time runs out, when turned off, or when Monitr quits.
@MainActor
@Observable
final class SleepGuard {
    static let shared = SleepGuard()

    enum Length: Hashable, Identifiable {
        case minutes(Int)
        case indefinitely
        var id: String { if case .minutes(let m) = self { return "\(m)" }; return "forever" }
        var title: String {
            switch self {
            case .indefinitely: "Until turned off"
            case .minutes(let m) where m < 60: "For \(m) minutes"
            case .minutes(let m) where m == 60: "For 1 hour"
            case .minutes(let m): "For \(m / 60) hours"
            }
        }
        static let choices: [Length] = [.indefinitely, .minutes(30), .minutes(60), .minutes(120), .minutes(240)]
    }

    private(set) var isOn = false
    private(set) var until: Date?            // nil while on means until turned off
    var keepDisplayOn: Bool {
        didSet {
            UserDefaults.standard.set(keepDisplayOn, forKey: "sleepKeepDisplay")
            if isOn { restart() }
        }
    }
    var lastLength: Length = .indefinitely

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var timer: Timer?

    private init() {
        keepDisplayOn = UserDefaults.standard.bool(forKey: "sleepKeepDisplay")
    }

    func turnOn(_ length: Length) {
        lastLength = length
        if case .minutes(let m) = length { until = Date().addingTimeInterval(Double(m) * 60) } else { until = nil }
        restart()
    }

    func turnOff() {
        release()
        timer?.invalidate()
        timer = nil
        isOn = false
        until = nil
        onChange?()
    }

    func toggle() { isOn ? turnOff() : turnOn(lastLength) }

    /// "Until 3:40 AM", "Until turned off".
    var detail: String {
        guard isOn else { return keepDisplayOn ? "Off. Display stays on when turned on" : "Off" }
        let display = keepDisplayOn ? ", display on" : ""
        guard let until else { return "Until turned off" + display }
        return "Until \(until.formatted(date: .omitted, time: .shortened))" + display
    }

    private func restart() {
        release()
        // Display sleep prevention also keeps the system awake; system-only lets the screen dim.
        let type = (keepDisplayOn ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep) as CFString
        let ok = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Monitr: Prevent sleep" as CFString, &assertion) == kIOReturnSuccess
        isOn = ok
        timer?.invalidate()
        timer = nil
        if ok, let until {
            let t = Timer(fire: until, interval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { SleepGuard.shared.turnOff() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        onChange?()
    }

    private func release() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
