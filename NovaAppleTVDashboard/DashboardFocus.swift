import Foundation
import SwiftUI

let phonoscopeZoneID = "__phonoscope"

// Focus model + remote-input gating + the focus graph that drives all
// navigation. The dashboard does not use the system focus engine for movement;
// it owns focus explicitly via `@FocusState<DashboardFocus?>` so the layout can
// be transposed (depth runs left→right on screen, siblings stack top→bottom)
// and so edit-mode controls can capture the remote. This file is the single
// source of truth for "what can be focused" and "where the remote can go".

// MARK: - Focus identity

/// Every focusable element in the dashboard is identified by one of these cases.
/// The associated strings are zone ids (and, for controls, an action/entity id),
/// which is also what `dashboardFocus(_:equals:)` uses as the scroll id.
enum DashboardFocus: Hashable {
    case section(String)
    case child(String)
    case action(String, String)
    case hue(String)
    case brightness(String)
    case temperature(String, String)
    case fanSpeed(String, String)

    /// The owning zone id for any focus case, used to keep `selectedZoneID` in
    /// sync and to resolve which top-level zone a control belongs to.
    var zoneID: String {
        switch self {
        case .section(let id), .child(let id), .hue(let id), .brightness(let id):
            return id
        case .action(let id, _), .temperature(let id, _), .fanSpeed(let id, _):
            return id
        }
    }
}

/// A control surface element — anything that isn't a zone/room title button.
func isControlFocus(_ focus: DashboardFocus) -> Bool {
    switch focus {
    case .section, .child: return false
    default: return true
    }
}

// MARK: - Remote input

/// The four directional remote inputs, mapped from SwiftUI's `MoveCommandDirection`.
enum RemoteDirection: Equatable {
    case left
    case right
    case up
    case down

    #if os(tvOS)
    init?(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        @unknown default: return nil
        }
    }
    #endif

    func isOpposite(of other: RemoteDirection) -> Bool {
        switch (self, other) {
        case (.left, .right), (.right, .left), (.up, .down), (.down, .up):
            return true
        default:
            return false
        }
    }
}

/// A serialized request, sent from the root view to an editing control, to step
/// its draft value in a direction. Serial + focus let the receiving control
/// ignore stale/foreign events via `onChange`.
struct DashboardEditMove: Equatable {
    let serial: Int
    let focus: DashboardFocus
    let direction: RemoteDirection
}

/// A serialized request telling an editing control to discard its draft and exit
/// edit mode (Menu/Back while editing).
struct DashboardEditCancel: Equatable {
    let serial: Int
    let focus: DashboardFocus
    /// The phone's tap while a control is unlocked: end the edit keeping the
    /// draft, as Select on the control does, rather than discarding it as Back does.
    var commit = false
}

/// Requires two root-level Back presses close together before allowing the app
/// to exit. A monotonic timestamp keeps wall-clock changes from affecting the
/// gesture, and any navigation/collapse resets the pending first press.
struct RootBackExitGate {
    private let interval: TimeInterval
    private var firstPressAt: TimeInterval?

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    mutating func register(at now: TimeInterval) -> Bool {
        if let firstPressAt,
           now >= firstPressAt,
           now - firstPressAt <= interval {
            self.firstPressAt = nil
            return true
        }

        firstPressAt = now
        return false
    }

    mutating func reset() {
        firstPressAt = nil
    }
}

/// Absorbs duplicate/trailing tvOS exit callbacks after a modal-style surface
/// has handled Back. A single Siri Remote gesture can produce more than one
/// callback while the focus tree is being rebuilt.
struct ExitCommandShield {
    private var suppressUntil: TimeInterval = 0

    mutating func begin(at now: TimeInterval, duration: TimeInterval = 1.25) {
        suppressUntil = max(suppressUntil, now + duration)
    }

    func contains(_ now: TimeInterval) -> Bool {
        now < suppressUntil
    }
}

/// Interaction tracing, compiled out of release builds. Used to follow accepted
/// vs ignored moves, focus transitions, and edit enter/confirm/cancel when
/// tuning the remote feel.
func debugInteractionLog(_ message: String) {
#if DEBUG
    print("[NovaTV][interaction] \(message)")
#endif
}

// MARK: - Focus graph

/// A position inside the transposed focus graph: `row` is the depth level (laid
/// out left→right on screen), `column` is the sibling index within that level
/// (stacked top→bottom).
struct DashboardFocusPosition {
    let row: Int
    let column: Int
}

/// The set of focusable elements for the current expansion state, arranged as
/// rows-of-siblings. The root view queries it to translate a remote direction
/// into the next focus.
struct DashboardFocusGraph {
    let rows: [[DashboardFocus]]

    var first: DashboardFocus? {
        rows.first?.first
    }

    func position(of focus: DashboardFocus) -> DashboardFocusPosition? {
        for rowIndex in rows.indices {
            if let columnIndex = rows[rowIndex].firstIndex(of: focus) {
                return DashboardFocusPosition(row: rowIndex, column: columnIndex)
            }
        }
        return nil
    }

    func focus(row: Int, column: Int) -> DashboardFocus? {
        guard rows.indices.contains(row),
              rows[row].indices.contains(column)
        else { return nil }
        return rows[row][column]
    }

    /// The element at `column` in `row`, clamped to the row's bounds — used when
    /// stepping into a neighbouring level whose sibling count differs.
    func nearestFocus(row: Int, column: Int) -> DashboardFocus? {
        guard rows.indices.contains(row), !rows[row].isEmpty else { return nil }
        let boundedColumn = min(max(column, 0), rows[row].count - 1)
        return rows[row][boundedColumn]
    }
}

/// Builds the focus graph for the current expansion. Row 0 is always the primary
/// zone ribbon; expanding a zone appends that zone's deeper levels. Each branch
/// MUST contribute its control rows here, otherwise focus on those controls has
/// no position and navigation collapses to the first zone button.
func dashboardFocusGraph(state: DashboardState, expandedTopZoneID: String?, expandedChildZoneID: String?) -> DashboardFocusGraph {
    var rows: [[DashboardFocus]] = [
        state.primaryZones.map { DashboardFocus.section($0.id) } + [.section(phonoscopeZoneID)]
    ]

    guard let expandedTopZoneID,
          let topZone = state.zone(id: expandedTopZoneID)
    else {
        return DashboardFocusGraph(rows: rows.filter { !$0.isEmpty })
    }

    if topZone.isHomeZone {
        let childZones = [topZone] + state.homeChildZones
        rows.append(childZones.map { DashboardFocus.child($0.id) })

        if let expandedChildZoneID,
           let selectedZone = state.zone(id: expandedChildZoneID) {
            rows.append(contentsOf: lightingFocusRows(zone: selectedZone))
        }
    } else if topZone.isClimateZone {
        rows.append(contentsOf: climateFocusRows(zone: topZone))
    } else if topZone.isOutsideZone {
        if !topZone.lightEntities.isEmpty {
            rows.append([.action(topZone.id, "outside-power")])
        }
        // Camera and the (passive) weather panel are each their own focusable
        // column so you can swipe right onto them and they scroll into view.
        rows.append([.action(topZone.id, "camera-outside")])
        rows.append([.action(topZone.id, "weather")])
    } else if topZone.isNetworkZone {
        // The network panel has no controls but is focusable so you can swipe
        // onto it and it scrolls into view.
        rows.append([.action(topZone.id, "network")])
    } else if topZone.canUseLightingControls {
        // Any other lighting zone that is a top-level zone in its own right
        // (not a Home child). Its controls MUST be in the graph too, otherwise
        // focus on them has no position and navigation collapses to the first
        // zone button.
        rows.append(contentsOf: lightingFocusRows(zone: topZone))
    }

    return DashboardFocusGraph(rows: rows.filter { !$0.isEmpty })
}

/// The first focusable element revealed when a top-level zone is expanded (where
/// "right"/Select lands when drilling in).
func firstFocusInsideTopZone(_ zone: DashboardZone, state: DashboardState) -> DashboardFocus? {
    if zone.isHomeZone {
        return ([zone] + state.homeChildZones).first.map { .child($0.id) }
    }
    if zone.isClimateZone {
        return climateFocusRows(zone: zone).first?.first
    }
    if zone.isOutsideZone {
        if !zone.lightEntities.isEmpty {
            return .action(zone.id, "outside-power")
        }
        return .action(zone.id, "camera-outside")
    }
    if zone.isNetworkZone {
        return .action(zone.id, "network")
    }
    if zone.canUseLightingControls {
        return lightingFocusRows(zone: zone).first?.first
    }
    return nil
}

/// The first focusable control when a Home child (room) zone is expanded.
func firstFocusInsideChildZone(_ zone: DashboardZone) -> DashboardFocus? {
    lightingFocusRows(zone: zone).first?.first
}

/// The control rows for a lighting zone: the preset column (ON / CANDLE/DAY /
/// WHITE / OFF), then the brightness slider one level to the right.
func lightingFocusRows(zone: DashboardZone) -> [[DashboardFocus]] {
    guard zone.canUseLightingControls else { return [] }
    return [
        [
            .action(zone.id, "on"),
            .action(zone.id, "candle"),
            .action(zone.id, "white"),
            .action(zone.id, "off")
        ],
        [.brightness(zone.id)]
    ]
}

/// The control rows for the climate zone, laid out to match the visual stacking:
/// power column, mode column, fresh-air switch, temperature stepper, fan speed —
/// then the panel heater's power and temperature columns.
func climateFocusRows(zone: DashboardZone) -> [[DashboardFocus]] {
    let devices = ClimateDevices(zone: zone)
    var rows: [[DashboardFocus]] = []

    if let aircon = devices.aircon {
        rows.append([
            .action(zone.id, "aircon-auto"),
            .action(zone.id, "aircon-manual"),
            .action(zone.id, "aircon-off")
        ])

        // Visual order: HEAT (top), FAN, DRY (native only), COOL (bottom).
        let modeRow = ["heat", "fan_only", "dry", "cool"]
            .filter { $0 == "dry" ? aircon.hvacModes.contains("dry") : (aircon.hvacModes.isEmpty || aircon.hvacModes.contains($0)) }
            .map { DashboardFocus.action(zone.id, "mode-\($0)") }
        rows.append(modeRow)

        if let freshAirSwitch = devices.freshAirSwitch {
            rows.append([.action(zone.id, freshAirSwitch.entityID)])
        }

        // + (up) is on top, - (down) on the bottom, so up=first column.
        rows.append([
            .action(zone.id, climateTemperatureActionID(entityID: aircon.entityID, direction: .up)),
            .action(zone.id, climateTemperatureActionID(entityID: aircon.entityID, direction: .down))
        ])
        rows.append([.fanSpeed(zone.id, aircon.entityID)])
    }

    if let heater = devices.heater {
        rows.append([.action(zone.id, "heater-on"), .action(zone.id, "heater-off")])
        rows.append([
            .action(zone.id, climateTemperatureActionID(entityID: heater.entityID, direction: .up)),
            .action(zone.id, climateTemperatureActionID(entityID: heater.entityID, direction: .down))
        ])
    }

    return rows.filter { !$0.isEmpty }
}

/// The top-level zone id that owns a given focus (a `.section` is its own top;
/// everything else resolves through the dashboard state).
func topID(for focus: DashboardFocus?, state: DashboardState) -> String? {
    guard let focus else { return nil }
    if case .section(let id) = focus {
        return id
    }
    return state.topLevelZoneID(containing: focus.zoneID)
}

/// The focus one level shallower than `focus` — where Back/left returns to. A
/// control returns to its room (`.child`) within Home, otherwise to its zone
/// title (`.section`).
func ownerTitle(for focus: DashboardFocus, state: DashboardState) -> DashboardFocus? {
    switch focus {
    case .section:
        return nil
    case .child(let id):
        guard let topID = state.topLevelZoneID(containing: id) else { return nil }
        return .section(topID)
    case .action(let zoneID, _), .hue(let zoneID), .brightness(let zoneID), .temperature(let zoneID, _), .fanSpeed(let zoneID, _):
        if let homeTopID = state.homeZone?.id,
           state.homeZone?.id == zoneID || state.homeChildZones.contains(where: { $0.id == zoneID }) {
            return .child(zoneID == homeTopID ? homeTopID : zoneID)
        }
        guard let topID = state.topLevelZoneID(containing: zoneID) else { return nil }
        return .section(topID)
    }
}

/// A stable id for the "component group" a focus belongs to. Controls that drive
/// the same device share an id; switching to a focus with a *different* id is a
/// component-group crossing (e.g. air conditioner → panel heater) and is made
/// stickier than moving control-to-control inside one device. A title is its own
/// group; non-climate zones are a single group (no internal device split).
func controlGroupID(for focus: DashboardFocus, state: DashboardState) -> String {
    switch focus {
    case .section(let id):
        return "section:\(id)"
    case .child(let id):
        return "child:\(id)"
    default:
        let zoneID = focus.zoneID
        if let zone = state.zone(id: zoneID), zone.isClimateZone {
            return "climate:\(zoneID):\(climateDeviceGroup(for: focus, zone: zone))"
        }
        return "controls:\(zoneID)"
    }
}

/// Resolves a climate control to its device ("aircon" or "heater"). The heater's
/// controls are tagged by the `heater-` action prefix or by carrying the heater's
/// entity id; everything else in the climate zone is the air conditioner.
private func climateDeviceGroup(for focus: DashboardFocus, zone: DashboardZone) -> String {
    let heaterID = ClimateDevices(zone: zone).heater?.entityID
    switch focus {
    case .action(_, let actionID):
        if actionID.hasPrefix("heater-") { return "heater" }
        if let heaterID, actionID.contains(heaterID) { return "heater" }
        return "aircon"
    case .temperature(_, let entityID), .fanSpeed(_, let entityID):
        return entityID == heaterID ? "heater" : "aircon"
    default:
        return "aircon"
    }
}

/// Whether a focus belongs to a specific expanded child (room) — used to decide
/// when leaving a room should collapse it.
func isFocus(_ focus: DashboardFocus?, insideChild childID: String) -> Bool {
    guard let focus else { return false }
    switch focus {
    case .section:
        return false
    case .child(let id), .hue(let id), .brightness(let id):
        return id == childID
    case .action(let id, _), .temperature(let id, _), .fanSpeed(let id, _):
        return id == childID
    }
}
