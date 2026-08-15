import Foundation

// The tvOS half of the status orb info module catalogue. Ids, labels and
// default displays mirror `nova-ha-dashboard/lib/orb-info/catalogue.ts`; keep
// them in step when a module is added there.

struct OrbInfoSources {
    var now: Date = .now
    var watchface: WatchfacePreferences?
    var gymAlertThresholdHours: Double?
    var novaLoad: NovaLoad?
    var state: DashboardState?
    var power: PowerSnapshot?
    var tasks: [TaskSummary]?
}

/// The feeds a module needs beyond the always-present state/load polls. Mirrors
/// the web client's `OrbSourceId`, and lets this client fetch only what the
/// selected readout will actually display.
enum OrbSourceID: String {
    case power
    case tasks
}

struct OrbInfoModule {
    let id: String
    let label: String
    let baseUnit: OrbBaseUnit
    let defaultDisplay: OrbInfoDisplay
    /// Extra feeds this module needs; empty for anything served by the state
    /// and load polls the dashboard already runs.
    var extraSources: Set<OrbSourceID> = []
    let read: (OrbInfoSources, OrbModuleParams) -> OrbModuleOutput
}

/// Module parameters as decoded from the dashboard payload (which zone, which
/// sensor, which date). Values are strings or numbers, matching the web side.
struct OrbModuleParams {
    private let values: [String: OrbParamValue]

    init(_ values: [String: OrbParamValue] = [:]) { self.values = values }

    func string(_ key: String) -> String? {
        if case .string(let value) = values[key] { return value }
        return nil
    }

    func number(_ key: String) -> Double? {
        if case .number(let value) = values[key] { return value }
        return nil
    }
}

private func isoDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let parsed = fractional.date(from: value) { return parsed }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
}

private func reading(_ value: Double?, _ baseUnit: OrbBaseUnit) -> OrbModuleOutput {
    guard let value, value.isFinite else {
        return OrbModuleOutput(baseUnit: baseUnit, status: .unavailable)
    }
    return OrbModuleOutput(value: value, baseUnit: baseUnit, status: .ok)
}

private func gymOutput(_ sources: OrbInfoSources) -> OrbModuleOutput {
    let threshold = sources.gymAlertThresholdHours
    guard let reset = isoDate(sources.watchface?.gymLastResetAt) else {
        return OrbModuleOutput(baseUnit: .hours, status: .unavailable, alertThreshold: threshold)
    }
    // Fractional hours, exactly like the web module: the display's rounding
    // mode decides how it reads.
    let hours = max(0, sources.now.timeIntervalSince(reset)) / 3600
    return OrbModuleOutput(
        value: hours,
        baseUnit: .hours,
        observedAt: sources.watchface?.gymLastResetAt,
        status: .ok,
        alert: threshold.map { hours >= $0 } ?? false,
        alertThreshold: threshold
    )
}

private func hoursUntil(_ iso: String?, _ now: Date) -> Double? {
    guard let target = isoDate(iso) else { return nil }
    return max(0, target.timeIntervalSince(now)) / 3600
}

/// Modules whose data source exists only on the dashboard host (the power
/// readings) report unavailable here rather than showing a stale or invented
/// number.
private func unavailable(_ baseUnit: OrbBaseUnit) -> OrbModuleOutput {
    OrbModuleOutput(baseUnit: baseUnit, status: .unavailable)
}

/// Reduce the reminder list to the two numbers the readouts want. Mirrors
/// `tasksSourceFrom` in the web client.
private func reminderSummary(
    _ sources: OrbInfoSources
) -> (nextDueInHours: Double?, nextDueAt: String?, overdueCount: Int)? {
    guard let tasks = sources.tasks else { return nil }
    var nextDue: Date?
    var overdue = 0
    for task in tasks where task.dismissedAt == nil {
        guard let start = isoDate(task.start) else { continue }
        if start <= sources.now {
            overdue += 1
        } else if nextDue == nil || start < nextDue! {
            nextDue = start
        }
    }
    guard let nextDue else { return (nil, nil, overdue) }
    return (max(0, nextDue.timeIntervalSince(sources.now)) / 3600,
            ISO8601DateFormatter().string(from: nextDue),
            overdue)
}

/// A plain `yyyy-MM-dd` from the config page's date field, which is not a full
/// ISO-8601 instant.
private func dayOnlyDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
}

/// Resolve a zone's temperature/humidity the same way the web client does: the
/// HA-native area binding on the zone, read out of the entity list.
private func zoneEnvironment(
    _ sources: OrbInfoSources,
    _ zoneID: String?
) -> (temperature: Double?, humidity: Double?)? {
    guard let zoneID,
          let zone = sources.state?.zones.first(where: { $0.id == zoneID }),
          let entities = sources.state?.entities else { return nil }
    func value(_ entityID: String?) -> Double? {
        guard let entityID,
              let entity = entities.first(where: { $0.entityID == entityID }) else { return nil }
        return Double(entity.state)
    }
    return (value(zone.environment?.temperatureEntityID), value(zone.environment?.humidityEntityID))
}

/// A sensor's unit decides how its number must be converted: a °C sensor is a
/// temperature, a % sensor is already a percentage.
private func entityBaseUnit(_ entity: DashboardEntity) -> OrbBaseUnit {
    guard case .string(let raw)? = entity.attributes["unit_of_measurement"] else { return .count }
    switch raw.lowercased() {
    case "°c", "c": return .celsius
    case "%": return .percent
    case "w": return .watts
    case "h": return .hours
    default: return .count
    }
}

enum OrbInfoCatalogue {
    static let defaultModuleID = "gym"

    static let modules: [OrbInfoModule] = [
        OrbInfoModule(id: "none", label: "None", baseUnit: .none,
                      defaultDisplay: OrbInfoDisplay(format: .text, emptyText: ""),
                      read: { _, _ in OrbModuleOutput(baseUnit: .none, status: .unavailable) }),

        OrbInfoModule(id: "gym", label: "Gym", baseUnit: .hours,
                      defaultDisplay: OrbInfoDisplay(format: .duration, unit: .hours, decimals: 0, rounding: .floor),
                      read: { sources, _ in gymOutput(sources) }),

        OrbInfoModule(id: "gym-progress", label: "Gym progress", baseUnit: .hours,
                      defaultDisplay: OrbInfoDisplay(format: .percent, decimals: 0, rounding: .floor,
                                                     percentClamp: true, showUnit: true),
                      read: { sources, _ in gymOutput(sources) }),

        OrbInfoModule(id: "host-cpu", label: "Host CPU", baseUnit: .percent,
                      defaultDisplay: OrbInfoDisplay(format: .percent, decimals: 0, rounding: .round, showUnit: true),
                      read: { source, _ in reading(source.novaLoad.map { $0.cpu * 100 }, .percent) }),

        OrbInfoModule(id: "host-gpu", label: "Host GPU", baseUnit: .percent,
                      defaultDisplay: OrbInfoDisplay(format: .percent, decimals: 0, rounding: .round, showUnit: true),
                      read: { source, _ in reading(source.novaLoad.map { $0.gpu * 100 }, .percent) }),

        OrbInfoModule(id: "host-network", label: "Host network", baseUnit: .percent,
                      defaultDisplay: OrbInfoDisplay(format: .percent, decimals: 0, rounding: .round, showUnit: true),
                      read: { source, _ in reading(source.novaLoad.map { $0.net * 100 }, .percent) }),

        OrbInfoModule(id: "host-load", label: "Host load", baseUnit: .percent,
                      defaultDisplay: OrbInfoDisplay(format: .percent, decimals: 0, rounding: .round, showUnit: true),
                      read: { source, _ in reading(source.novaLoad.map { $0.load * 100 }, .percent) }),

        OrbInfoModule(id: "clock", label: "Current time", baseUnit: .timestamp,
                      defaultDisplay: OrbInfoDisplay(format: .clock),
                      read: { sources, _ in OrbModuleOutput(value: sources.now.timeIntervalSince1970 * 1000,
                                              baseUnit: .timestamp, status: .ok) }),

        OrbInfoModule(id: "until-sunset", label: "Until sunset", baseUnit: .hours,
                      defaultDisplay: OrbInfoDisplay(format: .duration, unit: .auto, decimals: 1,
                                                     rounding: .floor, showUnit: true),
                      read: { sources, _ in
                          var output = reading(hoursUntil(sources.state?.sun?.nextSetting, sources.now), .hours)
                          output.observedAt = sources.state?.sun?.nextSetting
                          return output
                      }),

        OrbInfoModule(id: "until-sunrise", label: "Until sunrise", baseUnit: .hours,
                      defaultDisplay: OrbInfoDisplay(format: .duration, unit: .auto, decimals: 1,
                                                     rounding: .floor, showUnit: true),
                      read: { sources, _ in
                          var output = reading(hoursUntil(sources.state?.sun?.nextRising, sources.now), .hours)
                          output.observedAt = sources.state?.sun?.nextRising
                          return output
                      }),

        OrbInfoModule(id: "outside-temperature", label: "Outside temperature", baseUnit: .celsius,
                      defaultDisplay: OrbInfoDisplay(format: .temperature, unit: .celsius, decimals: 0,
                                                     rounding: .round, showUnit: true),
                      read: { source, _ in reading(source.state?.weather?.temperature, .celsius) }),

        OrbInfoModule(id: "outside-feels-like", label: "Outside feels like", baseUnit: .celsius,
                      defaultDisplay: OrbInfoDisplay(format: .temperature, unit: .celsius, decimals: 0,
                                                     rounding: .round, showUnit: true),
                      read: { source, _ in reading(source.state?.weather?.feelsLike, .celsius) }),

        OrbInfoModule(id: "rain-chance", label: "Rain chance", baseUnit: .percent,
                      defaultDisplay: OrbInfoDisplay(format: .percent, decimals: 0, rounding: .round, showUnit: true),
                      read: { source, _ in reading(source.state?.weather?.rainChancePct, .percent) }),

        OrbInfoModule(id: "power-draw", label: "Power draw", baseUnit: .watts,
                      defaultDisplay: OrbInfoDisplay(format: .number, unit: .kilowatts, decimals: 2,
                                                     rounding: .round, showUnit: true),
                      extraSources: [.power],
                      read: { sources, _ in
                          var output = reading(sources.power?.currentWatts, .watts)
                          output.observedAt = sources.power?.generatedAt
                          return output
                      }),

        OrbInfoModule(id: "power-cost-rate", label: "Power cost rate", baseUnit: .count,
                      defaultDisplay: OrbInfoDisplay(format: .number, decimals: 2, rounding: .round, prefix: "$"),
                      extraSources: [.power],
                      read: { sources, _ in
                          var output = reading(sources.power?.currentCostPerHourNzd, .count)
                          output.observedAt = sources.power?.generatedAt
                          return output
                      }),

        OrbInfoModule(id: "lights-on", label: "Lights on", baseUnit: .count,
                      defaultDisplay: OrbInfoDisplay(format: .number, decimals: 0),
                      read: { sources, _ in
                          guard let entities = sources.state?.entities else { return unavailable(.count) }
                          let count = entities.filter { $0.domain == "light" && $0.state == "on" }.count
                          return OrbModuleOutput(value: Double(count), baseUnit: .count, status: .ok)
                      }),

        OrbInfoModule(id: "devices-unavailable", label: "Devices unavailable", baseUnit: .count,
                      defaultDisplay: OrbInfoDisplay(format: .number, decimals: 0),
                      read: { sources, _ in
                          guard let entities = sources.state?.entities else { return unavailable(.count) }
                          let count = entities.filter { $0.state == "unavailable" }.count
                          return OrbModuleOutput(value: Double(count), baseUnit: .count,
                                                 status: .ok, alert: count > 0)
                      }),

        OrbInfoModule(id: "zone-temperature", label: "Zone temperature", baseUnit: .celsius,
                      defaultDisplay: OrbInfoDisplay(format: .temperature, unit: .celsius, decimals: 1,
                                                     rounding: .round, showUnit: true),
                      read: { sources, params in
                          reading(zoneEnvironment(sources, params.string("zoneId"))?.temperature, .celsius)
                      }),

        OrbInfoModule(id: "zone-humidity", label: "Zone humidity", baseUnit: .percent,
                      defaultDisplay: OrbInfoDisplay(format: .percent, decimals: 0, rounding: .round, showUnit: true),
                      read: { sources, params in
                          reading(zoneEnvironment(sources, params.string("zoneId"))?.humidity, .percent)
                      }),

        OrbInfoModule(id: "indoor-outdoor-delta", label: "Indoor vs outdoor", baseUnit: .celsius,
                      defaultDisplay: OrbInfoDisplay(format: .temperature, unit: .celsius, decimals: 1,
                                                     rounding: .round, showUnit: true, signed: true),
                      read: { sources, params in
                          guard let inside = zoneEnvironment(sources, params.string("zoneId"))?.temperature,
                                let outside = sources.state?.weather?.temperature else {
                              return unavailable(.celsius)
                          }
                          return OrbModuleOutput(value: inside - outside, baseUnit: .celsius, status: .ok)
                      }),

        OrbInfoModule(id: "entity-numeric", label: "Any sensor", baseUnit: .count,
                      defaultDisplay: OrbInfoDisplay(format: .number, decimals: 1, rounding: .round),
                      read: { sources, params in
                          guard let entityID = params.string("entityId"),
                                let entity = sources.state?.entities.first(where: { $0.entityID == entityID }),
                                let value = Double(entity.state) else {
                              return unavailable(.count)
                          }
                          return OrbModuleOutput(value: value, baseUnit: entityBaseUnit(entity), status: .ok)
                      }),

        OrbInfoModule(id: "since-date", label: "Time since a date", baseUnit: .hours,
                      defaultDisplay: OrbInfoDisplay(format: .duration, unit: .days, decimals: 0,
                                                     rounding: .floor, showUnit: true),
                      read: { sources, params in
                          guard let since = params.string("since"),
                                let start = isoDate(since) ?? dayOnlyDate(since) else {
                              return unavailable(.hours)
                          }
                          let hours = max(0, sources.now.timeIntervalSince(start)) / 3600
                          let days = params.number("alertAfterDays") ?? 0
                          // 0 means "never alert", not "alert immediately".
                          let threshold: Double? = days > 0 ? days * 24 : nil
                          return OrbModuleOutput(
                              value: hours, baseUnit: .hours,
                              observedAt: since, status: .ok,
                              alert: threshold.map { hours >= $0 } ?? false,
                              alertThreshold: threshold
                          )
                      }),

        OrbInfoModule(id: "outside-humidity", label: "Outside humidity", baseUnit: .percent,
                      defaultDisplay: OrbInfoDisplay(format: .percent, decimals: 0, rounding: .round, showUnit: true),
                      read: { source, _ in reading(source.state?.weather?.humidity, .percent) }),

        OrbInfoModule(id: "uv-index", label: "UV index", baseUnit: .count,
                      defaultDisplay: OrbInfoDisplay(format: .number, decimals: 0, rounding: .round),
                      read: { source, _ in reading(source.state?.weather?.uvIndex, .count) }),

        OrbInfoModule(id: "wind-speed", label: "Wind speed", baseUnit: .count,
                      defaultDisplay: OrbInfoDisplay(format: .number, decimals: 0, rounding: .round),
                      read: { source, _ in reading(source.state?.weather?.windSpeed, .count) }),

        OrbInfoModule(id: "forecast-high", label: "Forecast high", baseUnit: .celsius,
                      defaultDisplay: OrbInfoDisplay(format: .temperature, unit: .celsius, decimals: 0,
                                                     rounding: .round, showUnit: true),
                      read: { source, _ in reading(source.state?.weather?.high, .celsius) }),

        OrbInfoModule(id: "forecast-low", label: "Forecast low", baseUnit: .celsius,
                      defaultDisplay: OrbInfoDisplay(format: .temperature, unit: .celsius, decimals: 0,
                                                     rounding: .round, showUnit: true),
                      read: { source, _ in reading(source.state?.weather?.low, .celsius) }),

        OrbInfoModule(id: "openings-open", label: "Doors & windows open", baseUnit: .count,
                      defaultDisplay: OrbInfoDisplay(format: .number, decimals: 0),
                      read: { sources, _ in
                          guard let entities = sources.state?.entities else { return unavailable(.count) }
                          let count = entities.filter { $0.domain == "cover" && $0.state == "open" }.count
                          return OrbModuleOutput(value: Double(count), baseUnit: .count,
                                                 status: .ok, alert: count > 0)
                      }),

        OrbInfoModule(id: "power-headroom", label: "Power headroom", baseUnit: .watts,
                      defaultDisplay: OrbInfoDisplay(format: .percent, decimals: 0, rounding: .round,
                                                     percentClamp: false, showUnit: true),
                      extraSources: [.power],
                      read: { sources, params in
                          let ceiling = params.number("ceilingWatts") ?? 0
                          let threshold: Double? = ceiling > 0 ? ceiling : nil
                          guard let watts = sources.power?.currentWatts, watts.isFinite else {
                              return OrbModuleOutput(baseUnit: .watts, status: .unavailable,
                                                     alertThreshold: threshold)
                          }
                          return OrbModuleOutput(
                              value: watts, baseUnit: .watts,
                              observedAt: sources.power?.generatedAt, status: .ok,
                              alert: threshold.map { watts >= $0 } ?? false,
                              alertThreshold: threshold
                          )
                      }),

        OrbInfoModule(id: "next-reminder", label: "Next reminder", baseUnit: .hours,
                      defaultDisplay: OrbInfoDisplay(format: .duration, unit: .auto, decimals: 0,
                                                     rounding: .floor, showUnit: true),
                      extraSources: [.tasks],
                      read: { sources, _ in
                          guard let summary = reminderSummary(sources) else { return unavailable(.hours) }
                          guard let hours = summary.nextDueInHours else { return unavailable(.hours) }
                          return OrbModuleOutput(value: hours, baseUnit: .hours,
                                                 observedAt: summary.nextDueAt, status: .ok)
                      }),

        OrbInfoModule(id: "reminders-overdue", label: "Overdue reminders", baseUnit: .count,
                      defaultDisplay: OrbInfoDisplay(format: .number, decimals: 0),
                      extraSources: [.tasks],
                      read: { sources, _ in
                          guard let summary = reminderSummary(sources) else { return unavailable(.count) }
                          return OrbModuleOutput(value: Double(summary.overdueCount), baseUnit: .count,
                                                 status: .ok, alert: summary.overdueCount > 0)
                      }),

        OrbInfoModule(id: "wan-status", label: "Internet connection", baseUnit: .none,
                      defaultDisplay: OrbInfoDisplay(format: .text),
                      read: { sources, _ in
                          guard let connected = sources.state?.router?.wanConnected else {
                              return unavailable(.none)
                          }
                          return OrbModuleOutput(text: connected ? "UP" : "DOWN", baseUnit: .none,
                                                 status: .ok, alert: !connected)
                      }),

        OrbInfoModule(id: "ha-health", label: "Home Assistant health", baseUnit: .none,
                      defaultDisplay: OrbInfoDisplay(format: .text),
                      read: { sources, _ in
                          guard let warnings = sources.state?.warnings else { return unavailable(.none) }
                          let healthy = warnings.isEmpty
                          return OrbModuleOutput(text: healthy ? "OK" : "DEG", baseUnit: .none,
                                                 status: .ok, alert: !healthy)
                      }),
    ]

    private static let byID: [String: OrbInfoModule] = Dictionary(
        uniqueKeysWithValues: modules.map { ($0.id, $0) }
    )

    static func module(id: String?) -> OrbInfoModule {
        byID[id ?? ""] ?? byID[defaultModuleID]!
    }

    /// The module, display and parameters for the current dashboard payload.
    static func resolve(
        _ payload: OrbInfoPayload?
    ) -> (module: OrbInfoModule, display: OrbInfoDisplay, params: OrbModuleParams) {
        let module = module(id: payload?.moduleID)
        let entry = payload?.modules?[module.id]
        let display = entry?.display?.resolved(onto: module.defaultDisplay) ?? module.defaultDisplay
        return (module, display, OrbModuleParams(entry?.params ?? [:]))
    }
}
