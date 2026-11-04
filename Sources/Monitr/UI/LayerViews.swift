import AppKit
import QuartzCore
import SwiftUI

/// Charts and bars drawn with Core Animation layers. Their motion runs in the system's render
/// server, so a gliding chart costs Monitr nothing per frame; SwiftUI animations would
/// re-run the view graph on every frame instead.

private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

private func resolved(_ color: NSColor, in view: NSView) -> CGColor {
    var cg = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
    return cg
}

// MARK: Sparkline

final class SparklineLayerView: NSView {
    private let content = CALayer()
    private let line = CAShapeLayer()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private var values: [Double] = []
    private var capacity = 90
    private var ceiling: Double?
    private var pushes = -1
    var tint: NSColor = .systemBlue { didSet { applyColors() } }
    /// When set, hovering shows the value under the pointer and how long ago it was.
    var hoverFormat: ((Double) -> String)?
    var secondsPerPoint: Double = 2
    private let guide = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let label = CATextLayer()
    private var hoverX: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        line.fillColor = nil
        line.lineWidth = 1.5
        line.lineCap = .round
        line.lineJoin = .round
        fill.mask = fillMask
        content.addSublayer(fill)
        content.addSublayer(line)
        layer?.addSublayer(content)
        guide.lineWidth = 1
        guide.lineDashPattern = [2, 3]
        dot.lineWidth = 2
        label.fontSize = 11
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.alignmentMode = .center
        label.cornerRadius = 5
        label.cornerCurve = .continuous
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        for l in [guide, dot, label] as [CALayer] { l.isHidden = true; layer?.addSublayer(l) }
        applyColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard hoverFormat != nil else { return }
        hoverX = convert(event.locationInWindow, from: nil).x
        showHover()
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [guide, dot, label] as [CALayer] { l.isHidden = true }
        CATransaction.commit()
    }

    private func showHover() {
        guard let x = hoverX, let fmt = hoverFormat, values.count > 1, bounds.width > 0 else { return }
        let w = bounds.width, h = bounds.height, step = stepWidth
        let fromEnd = Int(((w - x) / step).rounded())
        let i = max(0, min(values.count - 1, values.count - 1 - fromEnd))
        let v = values[i]
        let top = ceiling ?? ChartScale.niceCeiling(values.max() ?? 0)
        let px = w - CGFloat(values.count - 1 - i) * step
        let py = h - CGFloat(min(v / top, 1)) * (h - 2) - 1
        let ago = Int(Double(values.count - 1 - i) * secondsPerPoint)
        let when = ago < 2 ? "now" : ago < 60 ? "\(ago) s ago" : "\(ago / 60) min ago"
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let g = CGMutablePath(); g.move(to: CGPoint(x: px, y: 0)); g.addLine(to: CGPoint(x: px, y: h))
        guide.path = g
        dot.path = CGPath(ellipseIn: CGRect(x: px - 4, y: py - 4, width: 8, height: 8), transform: nil)
        let text = "\(fmt(v)), \(when)"
        label.string = text
        let tw = (text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]).width + 14
        let lx = min(max(px - tw / 2, 0), w - tw)
        label.frame = CGRect(x: lx, y: 2, width: tw, height: 18)
        for l in [guide, dot, label] as [CALayer] { l.isHidden = false }
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() { applyColors() }

    private func applyColors() {
        let c = resolved(tint, in: self)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.strokeColor = c
        fill.colors = [c.copy(alpha: 0.20) ?? c, c.copy(alpha: 0) ?? c]
        guide.strokeColor = c.copy(alpha: 0.6)
        dot.strokeColor = c
        dot.fillColor = resolved(.windowBackgroundColor, in: self)
        label.backgroundColor = resolved(NSColor.windowBackgroundColor.withAlphaComponent(0.92), in: self)
        label.foregroundColor = resolved(.labelColor, in: self)
        CATransaction.commit()
    }

    func update(ring: Ring, ceiling: Double?) {
        let isNew = ring.pushes != pushes
        values = ring.ordered
        capacity = ring.capacity
        self.ceiling = ceiling
        let full = ring.count >= ring.capacity
        let glide = isNew && pushes >= 0 && full && !reduceMotion && window != nil
        pushes = ring.pushes
        redraw()
        if hoverX != nil { showHover() }
        guard glide else { return }
        // Slide the freshly drawn chart in from one step to the right; the old frame lines up exactly.
        let step = stepWidth
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = step
        a.toValue = 0
        a.duration = 0.45
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.add(a, forKey: "glide")
    }

    private var stepWidth: CGFloat {
        let full = values.count >= capacity
        return bounds.width / CGFloat(max((full ? capacity - 1 : values.count) - 1, 1))
    }

    private var drawnSize: CGSize = .zero

    override func layout() {
        super.layout()
        // Layout passes run on every SwiftUI update; redraw only when the size really changed.
        guard bounds.size != drawnSize else { return }
        redraw()
    }

    private func redraw() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        drawnSize = bounds.size
        content.frame = bounds
        fill.frame = bounds
        fillMask.frame = bounds
        line.frame = bounds
        guard values.count > 1, bounds.width > 0 else { line.path = nil; fillMask.path = nil; return }
        let w = bounds.width, h = bounds.height, step = stepWidth
        let top = ceiling ?? ChartScale.niceCeiling(values.max() ?? 0)
        let pts = values.enumerated().map { i, v in
            CGPoint(x: w - CGFloat(values.count - 1 - i) * step, y: h - CGFloat(min(v / top, 1)) * (h - 2) - 1)
        }
        let path = CGMutablePath()
        path.move(to: pts[0])
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i - 1])
        }
        path.addLine(to: pts[pts.count - 1])
        line.path = path
        let area = path.mutableCopy()!
        area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: h))
        area.addLine(to: CGPoint(x: pts[0].x, y: h))
        area.closeSubpath()
        fillMask.path = area
    }
}

/// A history chart that glides left as each new value arrives.
struct Sparkline: NSViewRepresentable {
    let ring: Ring
    var ceiling: Double? = nil
    var tint: Color = .accentColor
    var hoverFormat: ((Double) -> String)? = nil

    func makeNSView(context: Context) -> SparklineLayerView {
        let v = SparklineLayerView(frame: .zero)
        v.setAccessibilityElement(false)
        return v
    }

    func updateNSView(_ v: SparklineLayerView, context: Context) {
        let c = NSColor(tint)
        if v.tint != c { v.tint = c }
        v.hoverFormat = hoverFormat
        v.secondsPerPoint = Double(Store.shared.interval)
        v.update(ring: ring, ceiling: ceiling)
    }
}

// MARK: Bars

final class BarLayerView: NSView {
    private let track = CALayer()
    private let bar = CALayer()
    var vertical = false
    var tint: NSColor = .systemBlue { didSet { applyColors() } }
    private var fraction: CGFloat = 0
    private var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.cornerCurve = .continuous
        bar.cornerCurve = .continuous
        layer?.addSublayer(track)
        layer?.addSublayer(bar)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() { applyColors() }

    private func applyColors() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.06), in: self)
        bar.backgroundColor = resolved(tint.withAlphaComponent(0.85), in: self)
        CATransaction.commit()
    }

    func set(fraction f: Double) {
        let new = CGFloat(min(max(f, 0), 1))
        let animate = shown && !reduceMotion && abs(new - fraction) > 0.001
        fraction = new
        layoutBar(animated: animate)
        shown = true
    }

    private var laidOutSize: CGSize = .zero

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        layoutBar(animated: false)
    }

    private func layoutBar(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.45)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        let b = bounds
        let r = min(b.width, b.height) / 2
        track.frame = b
        track.cornerRadius = vertical ? 3 : r
        bar.cornerRadius = vertical ? 3 : r
        if vertical {
            let h = max(2, b.height * fraction)
            bar.frame = CGRect(x: 0, y: b.height - h, width: b.width, height: h)
        } else {
            bar.frame = CGRect(x: 0, y: 0, width: max(b.height, b.width * fraction), height: b.height)
        }
        CATransaction.commit()
    }
}

/// A thin track with a fill that eases to its new length (Core Animation, no per-frame work).
struct UsageBar: NSViewRepresentable {
    let fraction: Double
    let tint: Color
    var vertical = false

    func makeNSView(context: Context) -> BarLayerView {
        let v = BarLayerView(frame: .zero)
        v.vertical = vertical
        v.setAccessibilityElement(false)
        return v
    }

    func updateNSView(_ v: BarLayerView, context: Context) {
        let c = NSColor(tint)
        if v.tint != c { v.tint = c }
        v.set(fraction: fraction)
    }
}
