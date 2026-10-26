import GameController
import SwiftUI
import UIKit

/// The band's link to the Siri Remote. `RemoteInputController` owns the raw input
/// and the engine; the band registers what a step does and how a step is
/// classified, and reads the lean to draw. See `specs/remote-swipe.md`.
final class RemoteSwipeInput: ObservableObject {
    /// The focused control's lean while a swipe is pushing, in points.
    @Published var lean = CGSize.zero
    /// An unlocked dial owns the remote: see `RemoteSwipeEngine.adjusting`.
    var adjusting = false
    /// False while something presented over the band (the camera player) has the remote.
    var enabled = true
    var onStep: (RemoteDirection) -> Void = { _ in }
    var classify: (RemoteDirection) -> SwipeStepKind = { _ in .move }
    /// A long horizontal swipe switching panels, and whether it would go anywhere.
    var onPanel: (RemoteDirection) -> Void = { _ in }
    var classifyPanel: (RemoteDirection) -> SwipeStepKind = { _ in .move }
    /// A touch has begun: the band notes which panel it began in.
    var onTouchBegan: () -> Void = {}
    /// A coasting flick may take the next step only if it stays in its column and panel.
    var canCoast: (RemoteDirection) -> Bool = { _ in true }
}

/// Hosts the band so that focus only ever moves where the band's own navigation
/// puts it. tvOS's focus engine moves focus itself on every swipe, picking a
/// neighbour by geometry; letting it, and then correcting it, is what made the
/// old swiping flicker and drop moves. Here an update with a heading, which is
/// the engine acting on its own, is refused, and the remote is read directly.
struct RemoteInputHost: UIViewControllerRepresentable {
    let input: RemoteSwipeInput
    let content: AnyView

    init<Content: View>(input: RemoteSwipeInput, @ViewBuilder content: () -> Content) {
        self.input = input
        self.content = AnyView(content())
    }

    func makeUIViewController(context: Context) -> RemoteInputController {
        RemoteInputController(input: input, rootView: content)
    }

    func updateUIViewController(_ controller: RemoteInputController, context: Context) {
        controller.hosting.rootView = content
    }
}

/// Reads the remote two ways and settles between them:
///
/// - **Touches** on the touch surface arrive as UIKit indirect touches, the path
///   every remote (first and second generation Siri Remote, the iOS Remote app)
///   uses for swipes everywhere in tvOS. `RemoteTouchRecognizer` reports them.
/// - **Arrow presses** come from clicking (and, on the first remote, tapping) the
///   edges of the surface. `PressArbiter` decides what each one does when a
///   thumb may also be on the surface.
final class RemoteInputController: UIViewController, UIGestureRecognizerDelegate {
    let hosting: UIHostingController<AnyView>
    private let input: RemoteSwipeInput
    private var engine = RemoteSwipeEngine()
    private var arbiter = PressArbiter()
    private let recognizer = RemoteTouchRecognizer()
    private var touchOrigin: CGPoint?
    /// Where the thumb was when it last counted as moving.
    private var touchMark: CGPoint?
    private var coastTask: Task<Void, Never>?
    private var repeatTask: Task<Void, Never>?
    /// Set the first time a UIKit touch arrives. Until then the GameController
    /// reading drives the engine instead, in case a remote's touches never reach
    /// the band as UIKit touches.
    private var uikitTouchesSeen = false
    private var fallbackTouching = false
    private var fallbackMark: (x: Double, y: Double)?
    private var fallbackLift: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    /// How many points of indirect-touch travel count as the width of the touch
    /// surface. The learned swipe range (`SwipeRangeStore`) adapts the distances
    /// to the person's own swipes, so this only sets where they start.
    static let padPoints: CGFloat = 1600
    /// Thumb travel, in points, that counts as moving rather than resting.
    private static let restingWobble: CGFloat = 16

    init(input: RemoteSwipeInput, rootView: AnyView) {
        self.input = input
        hosting = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
        engine.classify = { [input] direction in input.classify(direction) }
        engine.didStep = { [weak self, input] direction in
            // Input off (the camera player is up): a flick judged at lift moves nothing.
            guard input.enabled, let self else { return }
            self.perform(self.arbiter.swipeStepped(at: self.now))
            InputTrace.shared.note("step \(direction)")
            input.onStep(direction)
        }
        engine.classifyPanel = { [input] direction in input.classifyPanel(direction) }
        engine.didPanel = { [weak self, input] direction in
            guard input.enabled, let self else { return }
            self.perform(self.arbiter.swipeStepped(at: self.now))
            InputTrace.shared.note("panel \(direction)")
            input.onPanel(direction)
        }
        engine.canCoast = { [input] direction in input.canCoast(direction) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.view.backgroundColor = .clear
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        recognizer.onBegan = { [weak self] point in self?.touchBegan(at: point) }
        recognizer.onMoved = { [weak self] point in self?.touchMoved(to: point) }
        recognizer.onEnded = { [weak self] cancelled in self?.touchEnded(cancelled: cancelled) }
        view.addGestureRecognizer(recognizer)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        for controller in GCController.controllers() { bindFallback(controller) }
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            if let controller = note.object as? GCController { self?.bindFallback(controller) }
        })
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        coastTask?.cancel()
        perform(arbiter.reset())
        repeatTask?.cancel()
        touchOrigin = nil
        fallbackTouching = false
        fallbackLift?.cancel()
        input.lean = .zero
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for controller in GCController.controllers() { controller.microGamepad?.dpad.valueChangedHandler = nil }
        InputTrace.shared.flush()
    }

    /// The focus engine may not move focus on a swipe or press by itself; the
    /// band's writes carry no heading and pass.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        context.focusHeading.isEmpty
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Carries out what the press arbiter decided.
    private func perform(_ actions: [PressArbiter.Action]) {
        for action in actions {
            switch action {
            case .step(let direction):
                guard input.enabled else { continue }
                InputTrace.shared.note("press step \(direction)")
                input.onStep(direction)
            case .startRepeat(_, let direction, let delay):
                startRepeat(direction, after: delay)
            case .stopRepeat:
                repeatTask?.cancel()
                repeatTask = nil
            }
        }
    }

    // MARK: Touches

    private func touchBegan(at point: CGPoint) {
        uikitTouchesSeen = true
        if fallbackTouching {
            fallbackTouching = false
            fallbackLift?.cancel()
            InputTrace.shared.note("fallback touch superseded by a UIKit touch")
        }
        InputTrace.shared.note("touch began enabled=\(input.enabled) adjusting=\(input.adjusting)")
        guard input.enabled else { perform(arbiter.reset()); return }
        coastTask?.cancel()
        touchOrigin = point
        touchMark = point
        arbiter.touchBegan(at: now)
        engine.profile = SwipeRangeStore.shared.profile
        engine.adjusting = input.adjusting
        input.onTouchBegan()
        engine.begin(x: 0, y: 0, at: now)
    }

    private func touchMoved(to point: CGPoint) {
        // Input turned off mid-touch (the camera player opened): the touch is
        // followed to its end but moves nothing.
        guard let origin = touchOrigin, input.enabled else { return }
        if let mark = touchMark, hypot(point.x - mark.x, point.y - mark.y) > Self.restingWobble {
            touchMark = point
            arbiter.thumbMoved(at: now)
        }
        // Pad units, as the engine reads them: the surface is 2 wide, and y grows upward.
        let x = Double((point.x - origin.x) / Self.padPoints * 2)
        let y = Double((origin.y - point.y) / Self.padPoints * 2)
        InputTrace.shared.note(String(format: "move %.3f %.3f", x, y))
        apply(engine.sample(x: x, y: y, at: now))
    }

    private func touchEnded(cancelled: Bool) {
        guard touchOrigin != nil else { return }
        touchOrigin = nil
        // Ending the touch can itself take a step (a flick), which the arbiter
        // hears about before the touch's end is reported to it.
        let outputs = engine.end(at: now)
        if input.enabled { apply(outputs) } else { input.lean = .zero }
        InputTrace.shared.note("touch \(cancelled ? "cancelled" : "ended") axis=\(engine.hasLockedAxis)")
        if input.enabled { perform(arbiter.touchEnded(at: now)) } else { perform(arbiter.reset()) }
        InputTrace.shared.flush()
    }

    // MARK: Fallback: the GameController reading

    /// Relative mode, the documented default: the first touch point is the origin,
    /// in the same pad units the engine reads.
    private func bindFallback(_ controller: GCController) {
        guard let micro = controller.microGamepad else { return }
        micro.reportsAbsoluteDpadValues = false
        micro.allowsRotation = false
        micro.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.fallbackSample(x: Double(x), y: Double(y)) }
        }
    }

    private func fallbackSample(x: Double, y: Double) {
        guard !uikitTouchesSeen, input.enabled else { return }
        let lifted = x == 0 && y == 0
        if lifted { finishFallback(); return }
        if !fallbackTouching {
            fallbackTouching = true
            fallbackMark = (x, y)
            InputTrace.shared.note("fallback touch began")
            coastTask?.cancel()
            arbiter.touchBegan(at: now)
            engine.profile = SwipeRangeStore.shared.profile
            engine.adjusting = input.adjusting
            input.onTouchBegan()
            engine.begin(x: x, y: y, at: now)
        }
        if let mark = fallbackMark, hypot(x - mark.x, y - mark.y) * Double(Self.padPoints) / 2 > Double(Self.restingWobble) {
            fallbackMark = (x, y)
            arbiter.thumbMoved(at: now)
        }
        fallbackLift?.cancel()
        let lift = DispatchWorkItem { [weak self] in self?.finishFallback() }
        fallbackLift = lift
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: lift)
        InputTrace.shared.note(String(format: "fallback move %.3f %.3f", x, y))
        apply(engine.sample(x: x, y: y, at: now))
    }

    private func finishFallback() {
        guard fallbackTouching, !uikitTouchesSeen else { fallbackTouching = false; return }
        fallbackTouching = false
        fallbackLift?.cancel()
        InputTrace.shared.note("fallback touch ended")
        let outputs = engine.end(at: now)
        if input.enabled { apply(outputs) } else { input.lean = .zero }
        if input.enabled { perform(arbiter.touchEnded(at: now)) } else { perform(arbiter.reset()) }
        InputTrace.shared.flush()
    }

    private func apply(_ outputs: [SwipeOutput]) {
        for output in outputs {
            switch output {
            case .step, .panel:
                break   // already taken, when the engine called `didStep` or `didPanel`
            case .measured(let reach):
                SwipeRangeStore.shared.record(reach)
                InputTrace.shared.note(String(format: "reach %.1f", reach))
            case .lean(let dx, let dy):
                input.lean = CGSize(width: dx, height: dy)
            case .coast(let direction, let delays):
                coast(direction, delays: delays)
            }
        }
    }

    /// A flick carries on, each item later than the last. It follows a row or a
    /// list and stops at its end, so a flick never changes column or panel.
    private func coast(_ direction: RemoteDirection, delays: [TimeInterval]) {
        coastTask?.cancel()
        coastTask = Task { @MainActor [weak self] in
            for delay in delays {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.input.enabled,
                      self.input.classify(direction) == .move, self.input.canCoast(direction) else { return }
                InputTrace.shared.note("coast \(direction)")
                self.input.onStep(direction)
            }
        }
    }

    // MARK: Clickpad edges and arrows

    private static func direction(of type: UIPress.PressType) -> RemoteDirection? {
        switch type {
        case .upArrow: return .up
        case .downArrow: return .down
        case .leftArrow: return .left
        case .rightArrow: return .right
        default: return nil
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = presses
        for press in presses {
            guard let direction = Self.direction(of: press.type) else { continue }
            unhandled.remove(press)
            let touching = touchOrigin != nil || fallbackTouching
            InputTrace.shared.note("press began \(direction) touching=\(touching)")
            guard input.enabled else { perform(arbiter.reset()); continue }
            coastTask?.cancel()
            let type = press.type.rawValue, began = now
            perform(arbiter.pressBegan(type: type, direction, at: began))
            if touching {
                DispatchQueue.main.asyncAfter(deadline: .now() + SwipeFeel.holdDelay) { [weak self] in
                    guard let self, self.input.enabled else { return }
                    self.perform(self.arbiter.holdElapsed(type: type, began: began, at: self.now))
                }
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private func startRepeat(_ direction: RemoteDirection, after delay: TimeInterval) {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            while !Task.isCancelled, let self, self.input.enabled {
                self.input.onStep(direction)
                try? await Task.sleep(for: .seconds(SwipeFeel.repeatInterval))
            }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = release(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = release(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// Reports the release of any direction press in `presses` and returns the
    /// presses that were not ours.
    private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
        var rest = presses
        for press in presses where Self.direction(of: press.type) != nil {
            rest.remove(press)
            InputTrace.shared.note("press ended \(press.type.rawValue)")
            perform(arbiter.pressEnded(type: press.type.rawValue, at: now))
        }
        return rest
    }
}
