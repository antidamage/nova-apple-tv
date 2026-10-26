import SwiftUI

// The phone's input and sizing (`specs/ios-touch-app.md`). The TV app compiles
// this file too, but everything in it is the phone's.

#if os(iOS)
/// What a finger does while a control is unlocked: the whole screen becomes the
/// remote's touch surface for it. A vertical drag steps the value, a horizontal
/// one changes channel, and a tap commits, as Select does on the TV. Nothing
/// else can be touched until it is committed or the five-second lease runs out.
struct TouchEditPad: View {
    let onStep: (RemoteDirection) -> Void
    let onTap: () -> Void
    /// Canvas points of drag per step of the value, and per channel.
    static let valueStep: CGFloat = 14
    static let channelStep: CGFloat = 44
    @State private var consumed = CGSize.zero
    @State private var moved = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { drag in
                        let dx = drag.translation.width - consumed.width
                        let dy = drag.translation.height - consumed.height
                        if abs(drag.translation.width) > 6 || abs(drag.translation.height) > 6 { moved = true }
                        if abs(dy) >= Self.valueStep && abs(dy) >= abs(dx) {
                            let steps = Int(abs(dy) / Self.valueStep)
                            for _ in 0..<steps { onStep(dy < 0 ? .up : .down) }
                            consumed.height += CGFloat(steps) * Self.valueStep * (dy < 0 ? -1 : 1)
                        } else if abs(dx) >= Self.channelStep {
                            onStep(dx < 0 ? .left : .right)
                            consumed.width += Self.channelStep * (dx < 0 ? -1 : 1)
                        }
                    }
                    .onEnded { _ in
                        if !moved { onTap() }
                        consumed = .zero
                        moved = false
                    }
            )
            .accessibilityHidden(true)
    }
}

/// The TV's band drawn at one scale for the phone: the dashboard is laid out on
/// a canvas the phone's height divided by `scale`, then drawn at `scale`, so
/// every width, font and gap keeps its proportion and the band scrolls sideways.
struct PhoneCanvas<Content: View>: View {
    /// The canvas height a phone's screen stands for, in TV points.
    static var referenceHeight: CGFloat { 700 }
    static func scale(forHeight height: CGFloat) -> CGFloat {
        min(1, max(0.4, height / referenceHeight))
    }
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = Self.scale(forHeight: size.height)
            content()
                .frame(width: size.width / scale, height: size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }
}
#endif
