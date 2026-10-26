import SwiftUI

// The phone's dial: the web dial's touch rules on the TV's RotaryEncoder
// (`specs/ios-touch-app.md`, "Dials on the phone"). The TV never draws the touch
// surface; only the state type is shared so the struct has one shape.

/// What a finger is doing to an unlocked dial, and the LED taps waiting to send.
struct RotaryTouchState {
    enum Grab: Equatable {
        case none
        /// Turning the knob: the last sampled angle and the unsnapped value.
        case knob(channel: String, lastAngle: Double, value: Double)
        /// Dragging a ring's thumb, holding the press-to-thumb angle; `pinned`
        /// is -1 or 1 while the finger is in the gap past that end.
        case ring(channel: String, offset: Double, pinned: Int)
        case toggle(channel: String)
    }
    var grab = Grab.none
    var moved = false
    /// The gesture in hand, by where it started: a new start is a new press,
    /// so a gesture the system cancelled (no end) never leaks into the next.
    var start: CGPoint?
    var last: CGPoint = .zero
    /// Total path travelled, in screen points, as the web measures a tap.
    var travel: CGFloat = 0
    /// Where the first LED tap of a run started; nil when nothing is pending.
    var ledStart: Double?
    var ledBeat = 0

    var grabbedRing: String? {
        if case .ring(let id, _, _) = grab { return id }
        return nil
    }
}

/// The geometry and the value maths, kept free of SwiftUI so it reads on its own.
enum RotaryTouch {
    /// One ring pitch: the TV draws ring `i` 15 points outside the one inside it.
    static let ringPitch: CGFloat = 15
    /// A tap is under 5 points of travel (the web's `TAP_MOVE_THRESHOLD_PX`).
    static let tapSlop: CGFloat = 5
    /// The thumb's own half-length on its arc, and the fingertip pad past it.
    static let thumbHalfDegrees = 0.012 * 360
    static let thumbPad: CGFloat = 22
    static let ledSettleSeconds = 1.5
    static let outsideTap = Notification.Name("nova.rotary.outsideTap")

    /// Clockwise from 12 o'clock, in (-180, 180].
    static func clockAngle(_ point: CGPoint, centre: CGPoint) -> Double {
        atan2(Double(point.x - centre.x), Double(centre.y - point.y)) * 180 / .pi
    }
    static func shortest(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }
    static func ringRadius(_ index: Int, size: CGFloat) -> CGFloat {
        size / 2 + ringPitch * CGFloat(index + 1)
    }
    /// Which ring a distance from the centre falls on: the innermost owns
    /// everything from the knob's edge out to half a pitch past its track.
    static func ringIndex(distance: CGFloat, size: CGFloat, count: Int) -> Int? {
        guard distance > size / 2, count > 0 else { return nil }
        let first = ringRadius(0, size: size) + ringPitch / 2
        let index = distance <= first ? 0 : 1 + Int(((distance - first) / ringPitch).rounded(.down))
        return index < count ? index : nil
    }
    static func thumbAngle(_ channel: RotaryChannel, value: Double) -> Double {
        -135 + 270 * channel.fraction(value)
    }
    static func onThumb(_ channel: RotaryChannel, value: Double, angle: Double, radius: CGFloat) -> Bool {
        let pad = Double(thumbPad / radius) * 180 / .pi
        return abs(shortest(angle - thumbAngle(channel, value: value))) <= thumbHalfDegrees + pad
    }
    /// The stepped value nearest a fraction of the arc, honouring a ring that
    /// draws its values off a curve (the timer's duration).
    static func value(_ channel: RotaryChannel, atFraction fraction: Double) -> Double {
        let f = min(1, max(0, fraction))
        if channel.valueFraction != nil {
            var best = channel.minimum, distance = Double.infinity
            var candidate = channel.minimum
            while candidate <= channel.maximum + 0.0001 {
                let gap = abs(channel.fraction(candidate) - f)
                if gap < distance { best = candidate; distance = gap }
                candidate += max(0.0001, channel.step)
            }
            return best
        }
        return snapped(channel, channel.minimum + f * (channel.maximum - channel.minimum))
    }
    static func snapped(_ channel: RotaryChannel, _ raw: Double) -> Double {
        let step = max(0.0001, channel.step)
        let value = channel.minimum + ((raw - channel.minimum) / step).rounded() * step
        if channel.wraps {
            let span = wrapSpan(channel)
            let wrapped = (value - channel.minimum).truncatingRemainder(dividingBy: span)
            return channel.minimum + (wrapped < 0 ? wrapped + span : wrapped)
        }
        return min(channel.maximum, max(channel.minimum, value))
    }
    /// One trip round a wrapping domain: hue's 0...359 is 360 units.
    static func wrapSpan(_ channel: RotaryChannel) -> Double {
        channel.maximum - channel.minimum + 1
    }
    /// Value units per degree turned: the index's own rate.
    static func sensitivity(_ channel: RotaryChannel) -> Double {
        channel.wraps ? wrapSpan(channel) / 360
            : (channel.maximum - channel.minimum) / 270
    }
}

#if os(iOS)
extension RotaryEncoder {
    var ringChannels: [RotaryChannel] { channels.filter(\.ring) }
    private var footprint: CGFloat {
        size + 2 * (RotaryTouch.ringPitch * CGFloat(ringChannels.count) + RotaryTouch.thumbPad)
    }
    /// The channel the knob turns: the face channel, else the lit one.
    private var turnChannel: RotaryChannel? {
        if let faceChannel, let channel = available.first(where: { $0.id == faceChannel }) { return channel }
        return selected.flatMap { $0.ring ? nil : $0 }
    }
    private var faceChannels: [RotaryChannel] { available.filter { !$0.ring } }

    /// Laid over the knob only while it is unlocked, so a locked dial takes no
    /// drag and the band scrolls across it.
    var touchSurface: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .updating($touchHeld) { _, held, _ in held = true }
                        .onChanged { drag in
                            // The canvas is drawn scaled; a tap is judged in real points.
                            let scale = geometry.frame(in: .global).width / max(1, geometry.size.width)
                            touchMoved(drag, centre: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2), scale: scale)
                        }
                        .onEnded { drag in touchEnded(drag) }
                )
                .onReceive(NotificationCenter.default.publisher(for: RotaryTouch.outsideTap)) { note in
                    guard let point = note.object as? CGPoint else { return }
                    let frame = geometry.frame(in: .global)
                    let reach = frame.width / 2
                    if hypot(point.x - frame.midX, point.y - frame.midY) > reach {
                        finish(commit: true, via: "outside-tap+commit")
                    }
                }
        }
        .frame(width: footprint, height: footprint)
        .task(id: touch.ledBeat) { await settleLEDs() }
    }

    private func touchMoved(_ drag: DragGesture.Value, centre: CGPoint, scale: CGFloat) {
        let point = drag.location
        let distance = hypot(point.x - centre.x, point.y - centre.y)
        let angle = RotaryTouch.clockAngle(point, centre: centre)
        if touch.start != drag.startLocation {
            // A new press: it alone decides what the gesture owns.
            touch.grab = .none
            touch.moved = false
            touch.travel = 0
            touch.start = drag.startLocation
            touch.last = point
            begin(at: angle, distance: distance)
            publishDial()
            return
        }
        touch.travel += hypot(point.x - touch.last.x, point.y - touch.last.y) * scale
        touch.last = point
        if touch.travel >= RotaryTouch.tapSlop { touch.moved = true }
        switch touch.grab {
        case .none:
            break
        case .knob(let id, let last, let raw):
            guard let channel = available.first(where: { $0.id == id }),
                  distance >= size / 2 * 0.15 else { return }
            // A press in the dead centre has no angle yet: adopt the first
            // sample outside it rather than turning by the jump to it.
            guard !last.isNaN else {
                touch.grab = .knob(channel: id, lastAngle: angle, value: raw)
                return
            }
            var next = raw + RotaryTouch.shortest(angle - last) * RotaryTouch.sensitivity(channel)
            if !channel.wraps { next = min(channel.maximum, max(channel.minimum, next)) }
            touch.grab = .knob(channel: id, lastAngle: angle, value: next)
            draft[id] = RotaryTouch.snapped(channel, next)
        case .ring(let id, let offset, var pinned):
            guard let channel = available.first(where: { $0.id == id }) else { return }
            let along = RotaryTouch.shortest(angle + offset)
            if abs(along) > 135 {
                if pinned == 0 { pinned = along > 0 ? 1 : -1 }
            } else if pinned != 0, (pinned > 0) == (along >= 0) {
                pinned = 0
            }
            touch.grab = .ring(channel: id, offset: offset, pinned: pinned)
            let fraction = pinned != 0 ? (pinned > 0 ? 1 : 0) : (along + 135) / 270
            draft[id] = RotaryTouch.value(channel, atFraction: fraction)
        case .toggle:
            break
        }
        publishDial()
    }

    /// The press decides what the gesture owns: the knob disc, a ring's thumb,
    /// a toggle ring's band, or nothing.
    private func begin(at angle: Double, distance: CGFloat) {
        if distance <= size / 2 {
            if let channel = turnChannel {
                let live = distance >= size / 2 * 0.15
                touch.grab = .knob(channel: channel.id, lastAngle: live ? angle : .nan, value: value(channel))
            }
            return
        }
        let rings = ringChannels
        guard let index = RotaryTouch.ringIndex(distance: distance, size: size, count: rings.count) else { return }
        let ring = rings[index]
        guard !ring.hidden, !ring.disabled else { return }
        if ring.kind == .toggle {
            touch.grab = .toggle(channel: ring.id)
        } else if RotaryTouch.onThumb(ring, value: value(ring), angle: angle,
                                      radius: RotaryTouch.ringRadius(index, size: size)) {
            let offset = RotaryTouch.shortest(RotaryTouch.thumbAngle(ring, value: value(ring)) - angle)
            touch.grab = .ring(channel: ring.id, offset: offset, pinned: 0)
        }
    }

    private func touchEnded(_ drag: DragGesture.Value) {
        let grab = touch.grab
        let tapped = !touch.moved
        touch.grab = .none
        touch.moved = false
        touch.start = nil
        activityBeat &+= 1
        switch grab {
        case .knob(let id, _, _):
            if tapped { tapKnob() } else { commitNow(id) }
        case .ring(let id, _, _):
            commitNow(id)
        case .toggle(let id):
            guard tapped, let ring = available.first(where: { $0.id == id }) else { return }
            draft[id] = value(ring) >= ring.maximum ? ring.minimum : ring.maximum
            commitNow(id)
        case .none:
            break
        }
        publishDial()
    }

    /// A tap on the knob cycles the LEDs: a dial whose LEDs are a value steps it
    /// and sends it once the taps settle; otherwise it lights the next channel.
    private func tapKnob() {
        if let ledChannel, let channel = available.first(where: { $0.id == ledChannel }) {
            let current = value(channel)
            if touch.ledStart == nil { touch.ledStart = current }
            draft[channel.id] = current + channel.step > channel.maximum ? channel.minimum : current + channel.step
            touch.ledBeat &+= 1
            return
        }
        let faces = faceChannels
        guard faces.count > 1 else { return }
        let index = faces.firstIndex { $0.id == selected?.id } ?? -1
        channelID = faces[(index + 1) % faces.count].id
    }

    private func settleLEDs() async {
        guard touch.ledStart != nil else { return }
        try? await Task.sleep(for: .seconds(RotaryTouch.ledSettleSeconds))
        guard !Task.isCancelled, editing, let start = touch.ledStart, let ledChannel else { return }
        touch.ledStart = nil
        if draft[ledChannel] != start { commitNow(ledChannel) }
    }

    /// The web's preview-and-commit boundary: a gesture's value is sent on
    /// release. A dial that commits on lock (the timer) keeps it for `finish`.
    private func commitNow(_ id: String) {
        guard commitsOnRelease, let next = draft[id], original[id] != next else { return }
        original[id] = next
        onCommit([id: next])
    }

    /// Sends whatever this dial still holds when another control took the unlock
    /// from it before `finish` could run (a tap straight onto another dial).
    func flushPending() {
        touch.ledStart = nil
        touch.grab = .none
        let changes = draft.filter { original[$0.key] != $0.value }
        original.merge(changes) { $1 }
        if !changes.isEmpty { onCommit(changes) }
    }

    /// The channel lit on unlock: the dial's own first channel, never a ring.
    var unlockChannel: String {
        initialChannel ?? faceChannels.first?.id ?? available.first?.id ?? ""
    }
}
#endif
