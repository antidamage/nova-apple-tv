import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Reports one indirect touch on the remote's surface, start to finish, without
/// ever recognising a gesture of its own, so it never takes touches from anything.
final class RemoteTouchRecognizer: UIGestureRecognizer {
    var onBegan: (CGPoint) -> Void = { _ in }
    var onMoved: (CGPoint) -> Void = { _ in }
    var onEnded: (Bool) -> Void = { _ in }
    private var tracked: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let touch = touches.first else { return }
        tracked = touch
        onBegan(touch.location(in: view))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        onMoved(tracked.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        guard let tracked, touches.contains(tracked) else { return }
        onMoved(tracked.location(in: view))
        self.tracked = nil
        onEnded(cancelled)
        state = .failed
    }

    override func reset() {
        super.reset()
        if tracked != nil { tracked = nil; onEnded(true) }
    }

    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ prevented: UIGestureRecognizer) -> Bool { false }
}

// MARK: - Lean

private struct SwipeLean<Value: Hashable>: ViewModifier {
    @EnvironmentObject private var input: RemoteSwipeInput
    let focus: FocusState<Value?>.Binding
    let value: Value

    func body(content: Content) -> some View {
        let offset = focus.wrappedValue == value ? input.lean : .zero
        content
            .offset(offset)
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: offset)
    }
}

extension View {
    /// The focused control leans toward the swipe that is pushing on it, and
    /// springs back when it lets go.
    func swipeLean<Value: Hashable>(_ focus: FocusState<Value?>.Binding, equals value: Value) -> some View {
        modifier(SwipeLean(focus: focus, value: value))
    }
}
