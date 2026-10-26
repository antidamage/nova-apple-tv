#if DEBUG
import Foundation

/// The band's navigation, checked the way a person would check it: by where
/// things are. Each case names a place on screen and where a swipe from it ought to
/// go; the properties then hold for every control in every arrangement the band
/// can take. `specs/band-navigation.md` has the picture.
enum BandMapSelfTests {
    private static let everySystem: [BandSpec.System] = [
        .init(zoneID: "climate", kind: .climate),
        .init(zoneID: "outside", kind: .outside(hasPower: true)),
        .init(zoneID: "network", kind: .network),
        .init(zoneID: "__timers", kind: .timers),
        .init(zoneID: phonoscopeZoneID, kind: .phonoscope)
    ]
    private static let rooms = ["everything", "conservatory", "kitchen", "lounge"].map { BandSpec.Room(id: $0, hasControls: true) }

    static func scene(home: String = "everything", system: String = "climate") -> BandSpec {
        var spec = BandSpec()
        spec.rooms = rooms
        spec.homeSelection = home
        spec.systems = everySystem
        spec.systemSelection = system
        return spec
    }

    private static func key(_ cursor: BandCursor) -> String {
        "\(cursor.focus.accessibilityID)|\(cursor.spec.homeSelection)|\(cursor.spec.systemSelection)"
    }

    private static func opposite(_ d: RemoteDirection) -> RemoteDirection {
        switch d { case .left: return .right; case .right: return .left; case .up: return .down; case .down: return .up }
    }

    static func run() {
        let orb = DashboardFocus.action("__orb", "dial")
        let lights = DashboardFocus.action("__quick", "lights")
        func quick(_ id: String) -> DashboardFocus { .action("__quick", id) }

        // Walks a route of presses from a place and reports where it ends.
        func walk(_ from: DashboardFocus, _ route: [RemoteDirection], in spec: BandSpec = scene()) -> DashboardFocus {
            var cursor = BandCursor(spec: spec, focus: from)
            for d in route { _ = cursor.press(d) }
            return cursor.focus
        }
        func jump(_ from: DashboardFocus, _ d: RemoteDirection, in spec: BandSpec = scene()) -> DashboardFocus? {
            var cursor = BandCursor(spec: spec, focus: from)
            let panel = cursor.panel
            return cursor.jump(d, fromPanel: panel) == .none ? nil : cursor.focus
        }

        // The orb is not a panel: one small swipe gets off it, and one back gets on.
        assert(walk(orb, [.right]) == lights, "One swipe right leaves the orb for the lights dial")
        assert(walk(orb, [.up]) == orb && walk(orb, [.down]) == orb, "Nothing is above or below the orb")
        assert(walk(lights, [.left]) == orb, "and one swipe left of the first panel is the orb again")

        // The theme and HOST buttons, off screen left of the orb (Adeline, 2026-10-23).
        let config = ThemeMode.cycleFocus
        let host = ThemeMode.hostFocus
        assert(walk(orb, [.left]) == config, "Left of the orb is the theme button")
        var dark = scene()
        dark.themeSelection = "dark"
        assert(walk(orb, [.left], in: dark) == config, "It is the same button whatever mode is in force")
        assert(walk(config, [.down]) == host && walk(host, [.down]) == host && walk(config, [.up]) == config,
               "The HOST button is under the theme button, and both ends hold")
        assert(walk(host, [.right]) == orb && walk(config, [.right]) == orb && walk(config, [.left]) == config,
               "Right from either is the orb again, and nothing is left of them")
        assert(jump(orb, .left) == config && jump(lights, .left) == orb, "A long swipe left reaches it from the orb only")

        // Quick access: a dial over its buttons over the climate dials.
        assert(walk(lights, [.down]) == quick("candle"), "Down from a dial is its button group (the middle two tie: the left one)")
        assert(walk(lights, [.down, .up]) == lights, "and up returns to the dial")
        assert(walk(lights, [.down, .right, .right]) == quick("off"), "Left and right walk the buttons one at a time")
        assert(walk(quick("on"), [.down]) == quick("aircon-dial") && walk(quick("off"), [.down]) == quick("heater-dial"),
               "Down from a button goes to the climate dial under it")
        assert(walk(lights, [.down, .down, .up]) == quick("candle"), "Back up from the climate dial returns to the button it came from")
        assert(walk(quick("aircon-dial"), [.right]) == quick("heater-dial"), "Two dials side by side are one swipe apart")

        // Leaving a panel sideways: at the end of a row, or from a lone control.
        assert(walk(lights, [.right]) == .child("everything"), "A lone dial's right swipe switches to the Home panel, at its list")
        assert(walk(quick("off"), [.right]) == .child("everything"), "The end of a button row does the same")
        assert(walk(quick("heater-dial"), [.right]) == .child("everything"), "and so does the end of the climate row")
        assert(walk(quick("on"), [.left]) == orb, "Left of the first panel is the orb")

        // Home: a list and the controls it selects. The title strip holds nothing.
        let conservatory = scene(home: "conservatory")
        assert(walk(.child("conservatory"), [.right], in: conservatory) == .brightness("conservatory"),
               "Right from a list row is that room's dial, and selects the room")
        var picking = BandCursor(spec: scene(), focus: .child("kitchen"))
        _ = picking.press(.right)
        assert(picking.focus == .brightness("kitchen") && picking.spec.homeSelection == "kitchen", "Picking a room by swiping into it")
        _ = picking.press(.left)
        assert(picking.focus == .child("kitchen"), "and left comes back to the same row")
        assert(walk(.brightness("everything"), [.down]) == .action("everything", "candle"), "Down from the room dial is its buttons")
        assert(walk(.brightness("everything"), [.left]) == .child("everything"), "Left of the controls is the list")
        assert(walk(.child("everything"), [.left]) == lights, "and left of the list leaves the panel")
        assert(walk(.action("everything", "off"), [.right]) == .section("climate"), "Right off the Home controls is the Systems list")
        assert(walk(.brightness("everything"), [.right]) == .section("climate"), "A lone dial there does the same")
        assert(walk(.action("everything", "on"), [.left]) == .child("everything"), "The first button's left is the list, not another panel")
        assert(walk(.child("everything"), [.up]) == .child("everything") && walk(.child("everything"), [.down]) == .child("conservatory"),
               "The list is walked row by row")

        assert(BandMap(scene()).element(.section("__home")) == nil && BandMap(scene()).element(.section("__systems")) == nil,
               "The group titles are labels, not stops")

        // Systems.
        assert(walk(.section("climate"), [.right]) == .action("climate", "aircon-dial"), "Right from a system is its controls")
        assert(walk(.section("climate"), [.right, .right]) == .action("climate", "heater-dial"), "Two climate dials side by side")
        assert(walk(.section("climate"), [.right, .right, .right]) == .action("climate", "heater-dial"),
               "Systems is the last panel, so the last control holds")
        assert(walk(.section("__timers"), [.right], in: scene(system: "climate")) == .action("__timers", "timer"),
               "Right from a system selects it, so its controls appear")
        assert(walk(.section(phonoscopeZoneID), [.right]) == .action("climate", "aircon-dial"),
               "Phonoscope is a row of the list and leaves the selection alone")
        let outside = scene(system: "outside")
        assert(walk(.section("outside"), [.right, .right, .right], in: outside) == .action("outside", "weather"), "Power, camera, weather in a row")
        assert(walk(.section("climate"), [.down, .down, .down, .down]) == .section(phonoscopeZoneID), "The list runs to Phonoscope")

        // Long swipes jump panels from where the swipe began.
        assert(jump(orb, .right) == lights && jump(lights, .right) == .child("everything"), "A long swipe right: orb, then panels in order")
        assert(jump(.child("everything"), .right) == .section("climate") && jump(.section("climate"), .right) == nil,
               "Home to Systems, and nothing beyond Systems")
        assert(jump(.brightness("everything"), .left) == lights && jump(.child("everything"), .left) == lights,
               "A long swipe left from Home lands on the first panel")
        assert(jump(.action("climate", "heater-dial"), .left) == .brightness("everything"),
               "From Systems the Home controls are what the swipe meets")

        // A flick coasts along a row or a list, never into the next column or panel.
        func stays(_ id: DashboardFocus, _ d: RemoteDirection) -> Bool { BandCursor(spec: scene(), focus: id).pressStaysInColumn(d) }
        assert(stays(quick("on"), .right) && stays(.child("everything"), .down) && stays(.section("climate"), .down),
               "Along a row or down a list a flick may go on")
        assert(!stays(quick("off"), .right) && !stays(lights, .right) && !stays(.child("everything"), .right)
               && !stays(.child("everything"), .left) && !stays(orb, .right) && !stays(orb, .left) && !stays(lights, .up),
               "At the end of a row, from a lone control, or into the next column it stops")

        // Properties, for every control in every arrangement.
        var arrangements: [BandSpec] = []
        let selectable = ["climate", "outside", "network", "__timers"]
        for room in rooms.map(\.id) {
            for system in selectable { arrangements.append(scene(home: room, system: system)) }
        }
        var movesChecked = 0
        for spec in arrangements {
            let map = BandMap(spec)
            for e in map.elements {
                for d in [RemoteDirection.left, .right, .up, .down] {
                    var cursor = BandCursor(spec: spec, focus: e.id)
                    guard cursor.press(d) == .moved, cursor.focus != e.id, let t = BandMap(cursor.spec).element(cursor.focus) else { continue }
                    movesChecked += 1
                    let there = BandMap(cursor.spec)
                    let from = there.element(e.id) ?? e
                    // Direction: a swipe moves toward where it points.
                    switch d {
                    case .right: assert(t.x > from.x, "\(e.id) right -> \(t.id) is not to the right")
                    case .left: assert(t.x < from.x, "\(e.id) left -> \(t.id) is not to the left")
                    case .down: assert(t.y > from.y && t.column == from.column && t.panel == from.panel, "\(e.id) down -> \(t.id) is not below")
                    case .up: assert(t.y < from.y && t.column == from.column && t.panel == from.panel, "\(e.id) up -> \(t.id) is not above")
                    }
                    // Within a row, a swipe moves exactly one control along.
                    if from.blockKey == t.blockKey { assert(abs(from.slot - t.slot) == 1, "\(e.id) skipped along its row") }
                    // Moves inside a column come back the way they went.
                    if from.panel == t.panel && from.column == t.column {
                        _ = cursor.press(opposite(d))
                        assert(cursor.focus == e.id, "\(e.id) \(d) -> \(t.id) does not come back")
                    }
                    // Sideways between columns of a panel comes back to that column.
                    if from.panel == t.panel && from.column != t.column {
                        _ = cursor.press(opposite(d))
                        assert(BandMap(cursor.spec).element(cursor.focus)?.column == from.column, "\(e.id) \(d) -> \(t.id) does not return to its column")
                    }
                }
            }
        }
        assert(movesChecked > 500, "The properties ran over \(movesChecked) moves")

        // Every control can be reached from the orb, and the orb from every control.
        var seen: [String: BandCursor] = [:]
        var edges: [String: [String]] = [:]
        var queue = [BandCursor(spec: scene(), focus: orb)]
        seen[key(queue[0])] = queue[0]
        var focused = Set<String>()
        while let cursor = queue.first {
            queue.removeFirst()
            focused.insert(cursor.focus.accessibilityID)
            for d in [RemoteDirection.left, .right, .up, .down] {
                var next = BandCursor(spec: cursor.spec, focus: cursor.focus)
                guard next.press(d) != .none else { continue }
                edges[key(cursor), default: []].append(key(next))
                if seen[key(next)] == nil { seen[key(next)] = next; queue.append(next) }
            }
        }
        for room in rooms.map(\.id) {
            for control in [DashboardFocus.child(room), .brightness(room), .action(room, "on"), .action(room, "off")] {
                assert(focused.contains(control.accessibilityID), "\(control) can be reached")
            }
        }
        for control in [DashboardFocus.section("climate"), .section("outside"), .section("network"), .section("__timers"),
                        .section(phonoscopeZoneID), .action("climate", "aircon-dial"), .action("climate", "heater-dial"),
                        .action("outside", "outside-power"), .action("outside", "camera-outside"), .action("outside", "weather"),
                        .action("network", "network"), .action("__timers", "timer"),
                        lights, quick("on"), quick("off"), quick("aircon-dial"), quick("heater-dial"), orb]
                        + [ThemeMode.cycleFocus, ThemeMode.hostFocus] {
            assert(focused.contains(control.accessibilityID), "\(control) can be reached")
        }
        var canReachOrb = Set(seen.keys.filter { seen[$0]?.focus == orb })
        var grew = true
        while grew {
            grew = false
            for (from, tos) in edges where !canReachOrb.contains(from) && tos.contains(where: canReachOrb.contains) {
                canReachOrb.insert(from)
                grew = true
            }
        }
        assert(canReachOrb.count == seen.count, "The orb can be reached from everywhere: \(seen.count - canReachOrb.count) places cannot")

        assert(arrangements.count == 16, "Every arrangement is checked")
        dump(arrangements: arrangements)
        print("[NovaTV][tests] band map: \(movesChecked) moves and \(seen.count) places checked")
    }

    /// The map as data, one line per arrangement, so it can be drawn over the screen.
    private static func dump(arrangements: [BandSpec]) {
        for spec in arrangements {
            let map = BandMap(spec)
            let places = map.elements.map { e -> String in
                var parts = ["\"id\":\"\(e.id.accessibilityID)\"", "\"panel\":\(e.panel)", "\"column\":\(e.column)", "\"block\":\(e.block)",
                             "\"slot\":\(e.slot)", "\"x\":\(Int(e.x))", "\"y\":\(Int(e.y))"]
                for (name, d) in [("left", RemoteDirection.left), ("right", .right), ("up", .up), ("down", .down)] {
                    var cursor = BandCursor(spec: spec, focus: e.id)
                    if cursor.press(d) == .moved, cursor.focus != e.id { parts.append("\"\(name)\":\"\(cursor.focus.accessibilityID)\"") }
                }
                for (name, d) in [("jumpLeft", RemoteDirection.left), ("jumpRight", .right)] {
                    var cursor = BandCursor(spec: spec, focus: e.id)
                    let panel = cursor.panel
                    if cursor.jump(d, fromPanel: panel) == .moved, cursor.focus != e.id { parts.append("\"\(name)\":\"\(cursor.focus.accessibilityID)\"") }
                }
                return "{" + parts.joined(separator: ",") + "}"
            }
            let name = "home=\(spec.homeSelection) systems=\(spec.systemSelection)"
            print("[NovaTV][bandmap] {\"scene\":\"\(name)\",\"places\":[" + places.joined(separator: ",") + "]}")
        }
    }
}
#endif
