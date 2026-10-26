import Foundation

// The band as a person sees it, reduced to what navigation needs. The model is
// spatial: panels sit left to right, a panel is a row of columns, a column is a
// stack of blocks, and a block is a row of controls. Swiping moves to the
// neighbour a person would expect from where the controls are on screen. The
// rules and the reasoning are in `specs/band-navigation.md`.

enum BandPanel {
    /// The theme mode selector: off screen left of the orb, shown only while the
    /// remote is on it (Adeline, 2026-10-23).
    static let theme = -2
    /// The status orb: to the left of everything on screen, and not a panel.
    static let orb = -1
    static let quickAccess = 0
    static let home = 1
    static let systems = 2
}

struct BandSpec: Equatable {
    enum SystemKind: Equatable { case climate, outside(hasPower: Bool), network, timers, phonoscope, plain }
    struct System: Equatable {
        let zoneID: String
        let kind: SystemKind
        var focus: DashboardFocus { .section(zoneID) }
        /// Phonoscope opens a surface of its own, so it never becomes the selected system.
        var selectable: Bool { kind != .phonoscope }
    }
    struct Room: Equatable {
        let id: String
        let hasControls: Bool
    }

    var hasQuickLights = true
    var hasQuickClimate = true
    var rooms: [Room] = []
    var homeSelection = ""
    var systems: [System] = []
    var systemSelection = ""
    /// The theme mode in force (the theme button shows it).
    var themeSelection = ThemeMode.followShared

    var selectedRoom: Room? { rooms.first { $0.id == homeSelection } ?? rooms.first }
    var selectedSystem: System? { systems.first { $0.zoneID == systemSelection && $0.selectable } ?? systems.first { $0.selectable } }

    /// The list row Right was pressed on becomes the selection, so the controls
    /// beside the list are that row's.
    func selecting(_ focus: DashboardFocus) -> BandSpec {
        var next = self
        if case .child(let id) = focus, rooms.contains(where: { $0.id == id }) { next.homeSelection = id }
        if case .section(let id) = focus, systems.contains(where: { $0.zoneID == id && $0.selectable }) { next.systemSelection = id }
        return next
    }
}

/// This TV's theme modes, as the web's per-device override has them: follow the
/// shared setting, or auto (by the sun), light or dark on this TV only.
enum ThemeMode {
    static let followShared = "config"
    static let all = [followShared, "auto", "light", "dark"]
    static let zone = "__theme"
    static func focus(_ mode: String) -> DashboardFocus { .action(zone, mode) }
    /// The store's value for a mode: empty follows the shared setting.
    static func storeValue(_ mode: String) -> String { mode == followShared ? "" : mode }
    static func mode(storeValue: String) -> String { storeValue.isEmpty ? followShared : storeValue }
}

struct BandElement: Equatable {
    let id: DashboardFocus
    let panel: Int
    let column: Int
    let block: Int
    let slot: Int
    let slots: Int
    /// Where the control sits in the model's own coordinates (y grows downward).
    let x: Double
    let y: Double

    var blockKey: String { "\(panel).\(column).\(block)" }
}

enum BandMove: Equatable {
    case focus(DashboardFocus)
    case none
}

/// Where focus was left, so moving back lands on the control the person came from.
struct BandMemory {
    private var leftFrom: [String: Int] = [:]

    mutating func moved(from a: BandElement, to b: BandElement) {
        if a.column == b.column && a.panel == b.panel {
            leftFrom["\(a.blockKey)>\(b.blockKey)"] = a.slot
        } else {
            leftFrom.removeAll()
        }
        if a.blockKey == b.blockKey { leftFrom.removeAll() }
    }

    func slot(returningTo block: String, from source: String) -> Int? { leftFrom["\(block)>\(source)"] }
}

struct BandMap {
    let spec: BandSpec
    let elements: [BandElement]
    private let entryBlocks: [String: Int]

    init(_ spec: BandSpec) {
        var elements: [BandElement] = []
        var entries: [String: Int] = [:]
        func add(_ id: DashboardFocus, _ panel: Int, _ column: Int, _ block: Int, slot: Int = 0, slots: Int = 1,
                 x: Double, y: Double) {
            elements.append(BandElement(id: id, panel: panel, column: column, block: block, slot: slot, slots: slots, x: x, y: y))
        }
        /// A row of controls: one block, spread evenly across the column.
        func row(_ ids: [DashboardFocus], _ panel: Int, _ column: Int, _ block: Int, x0: Double, width: Double, y: Double) {
            for (index, id) in ids.enumerated() {
                add(id, panel, column, block, slot: index, slots: ids.count,
                    x: x0 + width * (Double(index) + 0.5) / Double(ids.count), y: y)
            }
        }
        let presets: (String) -> [DashboardFocus] = { zone in ["on", "candle", "white", "off"].map { .action(zone, $0) } }

        // Left of the orb: the theme button over the HOST button, entered at the theme.
        add(ThemeMode.cycleFocus, BandPanel.theme, 0, 0, x: -560, y: 120)
        add(ThemeMode.hostFocus, BandPanel.theme, 0, 1, x: -560, y: 260)
        add(.action("__orb", "dial"), BandPanel.orb, 0, 0, x: -250, y: 300)

        var block = 0
        if spec.hasQuickLights {
            row([.action("__quick", "lights")], BandPanel.quickAccess, 0, 0, x0: 0, width: 480, y: 120)
            row(presets("__quick"), BandPanel.quickAccess, 0, 1, x0: 0, width: 480, y: 230)
            block = 2
        }
        if spec.hasQuickClimate {
            row([.action("__quick", "aircon-dial"), .action("__quick", "heater-dial")], BandPanel.quickAccess, 0, block,
                x0: 0, width: 480, y: 380)
        }

        // Home and Systems: a list, then the selected row's controls. The group's
        // title strip beside the list is a label and holds nothing.
        var origin = 520.0 + 56
        for (index, room) in spec.rooms.enumerated() {
            add(.child(room.id), BandPanel.home, 0, index, x: origin + 116, y: 60 + 84 * Double(index))
        }
        entries["1.0"] = spec.rooms.firstIndex { $0.id == spec.selectedRoom?.id } ?? 0
        if let room = spec.selectedRoom, room.hasControls {
            row([.brightness(room.id)], BandPanel.home, 1, 0, x0: origin + 233, width: 560, y: 120)
            row(presets(room.id), BandPanel.home, 1, 1, x0: origin + 233, width: 560, y: 330)
        }
        origin += 233 + 560 + 24 + 56

        for (index, system) in spec.systems.enumerated() {
            add(system.focus, BandPanel.systems, 0, index, x: origin + 116, y: 60 + 84 * Double(index))
        }
        entries["2.0"] = spec.systems.firstIndex { $0.zoneID == spec.selectedSystem?.zoneID } ?? 0
        if let system = spec.selectedSystem {
            let zone = system.zoneID, x0 = origin + 233
            switch system.kind {
            case .climate:
                row([.action(zone, "aircon-dial"), .action(zone, "heater-dial")], BandPanel.systems, 1, 0, x0: x0, width: 560, y: 200)
            case .outside(let hasPower):
                row((hasPower ? [.action(zone, "outside-power")] : []) + [.action(zone, "camera-outside"), .action(zone, "weather")],
                    BandPanel.systems, 1, 0, x0: x0, width: 1230, y: 200)
            case .network:
                row([.action(zone, "network")], BandPanel.systems, 1, 0, x0: x0, width: 700, y: 200)
            case .timers:
                row([.action("__timers", "timer")], BandPanel.systems, 1, 0, x0: x0, width: 400, y: 200)
            case .phonoscope, .plain:
                break
            }
        }
        self.spec = spec
        self.elements = elements
        entryBlocks = entries
    }

    func element(_ id: DashboardFocus) -> BandElement? { elements.first { $0.id == id } }
    func panel(of id: DashboardFocus) -> Int? { element(id)?.panel }

    private func inBlock(_ key: String) -> [BandElement] {
        elements.filter { $0.blockKey == key }.sorted { $0.slot < $1.slot }
    }

    private func entry(panel: Int, column: Int, moving direction: RemoteDirection) -> DashboardFocus? {
        let inColumn = elements.filter { $0.panel == panel && $0.column == column }
        guard !inColumn.isEmpty else { return nil }
        let block = entryBlocks["\(panel).\(column)"] ?? 0
        let row = inColumn.filter { $0.block == block }.sorted { $0.slot < $1.slot }
        // Moving right enters a row from its left end, moving left from its right end.
        return (direction == .left ? row.last : row.first)?.id
    }

    /// Where a swipe lands when it enters a panel: the list is what a swipe from the
    /// left meets, and the controls what one from the right meets.
    private func landing(panel: Int, moving direction: RemoteDirection) -> DashboardFocus? {
        let columns = Set(elements.filter { $0.panel == panel }.map(\.column)).sorted()
        guard let first = columns.first, let last = columns.last else { return nil }
        let column = direction == .right ? first : last
        return entry(panel: panel, column: column, moving: direction)
    }

    private var panels: [Int] { Set(elements.map(\.panel)).sorted() }

    /// The control a swipe lands on in the next panel in `direction`, if there is one.
    func panelTarget(from panel: Int, _ direction: RemoteDirection) -> DashboardFocus? {
        let neighbour = direction == .right ? panels.first { $0 > panel } : panels.last { $0 < panel }
        return neighbour.flatMap { landing(panel: $0, moving: direction) }
    }

    func next(from id: DashboardFocus, _ direction: RemoteDirection, memory: BandMemory) -> BandMove {
        guard let e = element(id) else { return .none }
        switch direction {
        case .left, .right:
            let step = direction == .right ? 1 : -1
            if let neighbour = inBlock(e.blockKey).first(where: { $0.slot == e.slot + step }) { return .focus(neighbour.id) }
            if let target = entry(panel: e.panel, column: e.column + step, moving: direction) { return .focus(target) }
            return panelTarget(from: e.panel, direction).map { .focus($0) } ?? .none
        case .up, .down:
            let key = "\(e.panel).\(e.column).\(e.block + (direction == .down ? 1 : -1))"
            let row = inBlock(key)
            guard !row.isEmpty else { return .none }
            if let slot = memory.slot(returningTo: key, from: e.blockKey), let remembered = row.first(where: { $0.slot == slot }) {
                return .focus(remembered.id)
            }
            // The nearest control across, the left one when two are equally near.
            var best = row[0]
            for candidate in row where abs(candidate.x - e.x) < abs(best.x - e.x) - 0.001 { best = candidate }
            return .focus(best.id)
        }
    }
}

enum BandPress { case moved, none }

/// One person's place on the band. The app and the self-tests drive the same
/// type, so what the tests prove is what the remote does.
struct BandCursor {
    var spec: BandSpec
    var focus: DashboardFocus
    var memory = BandMemory()

    mutating func press(_ direction: RemoteDirection) -> BandPress {
        let working = direction == .right ? spec.selecting(focus) : spec
        let map = BandMap(working)
        switch map.next(from: focus, direction, memory: memory) {
        case .none:
            return .none
        case .focus(let target):
            if let from = map.element(focus), let to = map.element(target) { memory.moved(from: from, to: to) }
            spec = working
            focus = target
            return .moved
        }
    }

    /// Whether a press would go anywhere. Used to tell a move from a bounce.
    func canPress(_ direction: RemoteDirection) -> Bool {
        var copy = self
        return copy.press(direction) != .none
    }

    /// Whether a press would stay in the same column of the same panel. A flick
    /// carries on only while it does: it follows a row or a list, never into the
    /// next column or panel.
    func pressStaysInColumn(_ direction: RemoteDirection) -> Bool {
        let before = BandMap(spec).element(focus)
        var copy = self
        guard copy.press(direction) == .moved, let after = BandMap(copy.spec).element(copy.focus) else { return false }
        return before?.panel == after.panel && before?.column == after.column
    }

    /// A long horizontal swipe: to the next panel from the one the swipe began in.
    mutating func jump(_ direction: RemoteDirection, fromPanel panel: Int) -> BandPress {
        let map = BandMap(spec)
        guard let target = map.panelTarget(from: panel, direction) else { return .none }
        if map.panel(of: target) == map.panel(of: focus) { return .moved }
        if let from = map.element(focus), let to = map.element(target) { memory.moved(from: from, to: to) }
        focus = target
        return .moved
    }

    func canJump(_ direction: RemoteDirection, fromPanel panel: Int) -> Bool {
        BandMap(spec).panelTarget(from: panel, direction) != nil
    }

    var panel: Int { BandMap(spec).panel(of: focus) ?? BandPanel.quickAccess }
}
