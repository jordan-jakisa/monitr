import SwiftUI

/// One spacing scale, one corner radius, one set of motion curves. Use these, not literals.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let row: CGFloat = 8
    static let notice: CGFloat = 12
}

enum Motion {
    /// Data moving (charts gliding, bars resizing). Ease-out, no overshoot.
    static let data = Animation.easeOut(duration: 0.45)
    /// Lists re-ordering, rows arriving or leaving.
    static let list = Animation.smooth(duration: 0.35)
    /// Hover and press feedback: fast enough to feel attached to the pointer.
    static let feedback = Animation.easeOut(duration: 0.12)
    /// Panes and notices appearing.
    static let reveal = Animation.smooth(duration: 0.25)
}

extension View {
    /// Applies `animation` only when Reduce Motion is off.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Pointer feedback for a whole row that acts as a button: a soft highlight on hover,
/// a slightly stronger one while pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs)
                .background(
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : hovering ? 0.05 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .onHover { hovering = $0 }
                .motion(Motion.feedback, value: hovering)
                .motion(Motion.feedback, value: configuration.isPressed)
        }
    }
}

/// Explanatory text under a form section. Grouped forms on macOS align footers to the trailing
/// edge, which reads as broken for more than a few words; this keeps notes leading-aligned.
struct FormNote: View {
    let text: String
    var icon: String? = nil

    init(_ text: String, icon: String? = nil) {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            if let icon { Image(systemName: icon).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, Space.s)   // line up with the section title above the box
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
