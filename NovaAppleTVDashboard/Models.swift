import Foundation

struct DashboardState: Decodable {
    let generatedAt: String
    let zones: [DashboardZone]
    let entities: [DashboardEntity]
    let totals: DomainCounts
    let router: RouterStatus?
    let spectrumCursors: [String: SpectrumCursor]?
    let sun: SunStatus?
    let weather: WeatherStatus?
    let preferences: DashboardPreferences?
    let climateControl: ClimateControlState?
    let warnings: [String]

    var primaryZones: [DashboardZone] {
        [homeZone, climateZone, outsideZone, networkZone].compactMap { $0 }
    }

    var activeEntityCount: Int {
        entities.filter { $0.state == "on" }.count
    }

    var homeZone: DashboardZone? {
        zones.first { $0.isHomeZone }
    }

    var climateZone: DashboardZone? {
        zones.first { $0.isClimateZone }
    }

    var outsideZone: DashboardZone? {
        zones.first { $0.isOutsideZone }
    }

    var networkZone: DashboardZone? {
        zones.first { $0.isNetworkZone }
    }

    var homeChildZones: [DashboardZone] {
        return zones
            .filter { zone in
                !zone.isHomeZone && !zone.isClimateZone && !zone.isOutsideZone && !zone.isNetworkZone
            }
    }

    func zone(id: String?) -> DashboardZone? {
        guard let id else { return nil }
        return zones.first { $0.id == id }
    }

    func topLevelZoneID(containing zoneID: String?) -> String? {
        guard let zoneID else { return primaryZones.first?.id }
        if let home = homeZone, home.id == zoneID || homeChildZones.contains(where: { $0.id == zoneID }) {
            return home.id
        }
        if climateZone?.id == zoneID {
            return zoneID
        }
        if outsideZone?.id == zoneID {
            return zoneID
        }
        if networkZone?.id == zoneID {
            return zoneID
        }
        return primaryZones.first?.id
    }

    func homeSelectionID(preferred zoneID: String?) -> String {
        if let zoneID,
           (homeZone?.id == zoneID || homeChildZones.contains(where: { $0.id == zoneID })) {
            return zoneID
        }
        return homeZone?.id ?? homeChildZones.first?.id ?? "everything"
    }
}

struct DashboardZone: Decodable, Identifiable {
    let id: String
    let name: String
    let entities: [DashboardEntity]
    let counts: DomainCounts
    let isOn: Bool
    let brightnessPct: Double

    var lightCount: Int { counts.light ?? lightingEntities.count }
    var switchCount: Int { counts.switch ?? 0 }
    var climateCount: Int { counts.climate ?? 0 }
    var sensorCount: Int { counts.sensor ?? 0 }
    var totalCount: Int { counts.total }
    var canUseLightingControls: Bool { !lightingEntities.isEmpty }
    var hasHueControls: Bool { !lightEntities.isEmpty }
    var unavailableCount: Int { entities.filter { $0.state == "unavailable" || $0.state == "unknown" }.count }
    var activeCount: Int { entities.filter { $0.state == "on" }.count }
    var lightEntities: [DashboardEntity] { entities.filter { $0.domain == "light" } }
    var lightingEntities: [DashboardEntity] { entities.filter { $0.domain == "light" || $0.isIllumination } }
    var climateEntities: [DashboardEntity] { entities.filter { $0.domain == "climate" } }
    var switchEntities: [DashboardEntity] { entities.filter { $0.domain == "switch" } }

    var isHomeZone: Bool { id == "everything" || name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "home" }
    var isClimateZone: Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id == "climate" || id == "heating" || normalized == "climate" || normalized == "heating"
    }
    var isOutsideZone: Bool { id == "outside" || name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "outside" }
    var isNetworkZone: Bool { id == "network" || name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "network" }

    var shortName: String {
        let parts = name.split(separator: " ")
        guard parts.count > 1 else { return name }
        return parts.map { String($0.prefix(1)) }.joined()
    }
}

struct DomainCounts: Decodable {
    let light: Int?
    let `switch`: Int?
    let climate: Int?
    let fan: Int?
    let cover: Int?
    let humidifier: Int?
    let sensor: Int?

    var total: Int {
        [light, `switch`, climate, fan, cover, humidifier, sensor].compactMap { $0 }.reduce(0, +)
    }

    var summaryParts: [String] {
        [
            ("lights", light),
            ("switches", `switch`),
            ("climate", climate),
            ("fans", fan),
            ("covers", cover),
            ("sensors", sensor)
        ].compactMap { label, count in
            guard let count, count > 0 else { return nil }
            return "\(count) \(label)"
        }
    }
}

struct DashboardEntity: Decodable {
    let entityID: String
    let domain: String
    let state: String
    let name: String
    let areaID: String
    let attributes: [String: JSONValue]
    let isIllumination: Bool

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case domain
        case state
        case name
        case areaID = "area_id"
        case attributes
        case isIllumination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try container.decode(String.self, forKey: .entityID)
        domain = try container.decode(String.self, forKey: .domain)
        state = try container.decode(String.self, forKey: .state)
        name = try container.decode(String.self, forKey: .name)
        areaID = try container.decode(String.self, forKey: .areaID)
        attributes = try container.decode([String: JSONValue].self, forKey: .attributes)
        isIllumination = (try? container.decode(Bool.self, forKey: .isIllumination)) ?? false
    }

    var isProblemState: Bool {
        state == "unavailable" || state == "unknown"
    }

    var statusText: String {
        if let brightness = attributes["brightness"]?.doubleValue, brightness > 0 {
            return "\(state) \(Int(((brightness / 255) * 100).rounded()))%"
        }
        if let temperature = attributes["current_temperature"]?.doubleValue {
            return "\(state) \(Int(temperature.rounded())) C"
        }
        return state
    }

    var isOn: Bool {
        if isProblemState { return false }
        if domain == "climate" { return state != "off" }
        if domain == "sensor" { return false }
        return ["on", "open", "opening", "playing", "heat", "cool", "heat_cool"].contains(state)
    }

    var targetTemperature: Double? {
        attributes["temperature"]?.doubleValue
    }

    var currentTemperature: Double? {
        attributes["current_temperature"]?.doubleValue
    }

    var minimumTemperature: Double {
        attributes["min_temp"]?.doubleValue ?? 5
    }

    var maximumTemperature: Double {
        attributes["max_temp"]?.doubleValue ?? 40
    }

    var fanMode: String? {
        attributes["fan_mode"]?.stringValue
    }

    var hvacModes: [String] {
        attributes["hvac_modes"]?.stringArray ?? []
    }

    var fanModes: [String] {
        attributes["fan_modes"]?.stringArray ?? []
    }
}

struct RouterStatus: Decodable {
    let name: String
    let download: RouterMetric?
    let upload: RouterMetric?
    let externalIp: String?
    let wanConnected: Bool?
    let wanState: String?
}

struct RouterMetric: Decodable {
    let value: Double?
    let unit: String?
    let display: String?
}

struct WeatherStatus: Decodable {
    let entityID: String?
    let condition: String
    let temperature: Double?
    let high: Double?
    let low: Double?
    let humidity: Double?

    let windSpeed: Double?
    let windUnit: String?
    let precipitation: Double?
    let precipitationUnit: String?
    let rainChancePct: Double?
    let uvIndex: Double?
    let maxUvIndex: Double?
    let feelsLike: Double?

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case condition
        case temperature
        case high
        case low
        case humidity
        case windSpeed
        case windUnit
        case precipitation
        case precipitationUnit
        case rainChancePct
        case uvIndex
        case maxUvIndex
        case feelsLike
    }
}

struct SunStatus: Decodable {
    let state: String
    let nextRising: String?
    let nextSetting: String?
}

struct DashboardPreferences: Decodable {
    let aircon: AirconPreferences?
    let watchface: WatchfacePreferences?
}

struct AirconPreferences: Decodable {
    let autoMode: Bool?
    let hvacMode: String?
    let temperature: Double?
    let fanMode: String?
    let quietMode: Bool?
    let turboMode: Bool?
}

struct ClimateControlState: Decodable {
    let lounge: ClimateControlRoomState
    let bedroom: ClimateControlRoomState
}

struct ClimateControlRoomState: Decodable {
    let owner: String
    let mode: String
    let phase: String
    let direction: String?
    let sensorAvailable: Bool
    let sensorReportedAt: String?
    let sensorGraceEndsAt: String?
    let actuatorAvailable: Bool
    let overrideReason: String?
    let lastStopReason: String?
}

struct WatchfacePreferences: Decodable {
    let daysSinceGym: Int?
    let gymLastResetAt: String?
    let idleTimeoutMs: Double?
}

struct SpectrumCursor: Codable, Equatable {
    var x: Double
    var y: Double
}

struct NovaLoad: Decodable {
    let cpu: Double
    let net: Double
    let gpu: Double
    let listening: Bool
    let load: Double
}

enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object((try? container.decode([String: JSONValue].self)) ?? [:])
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.formatted()
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    var stringArray: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }

    var doubleArray: [Double]? {
        guard case .array(let values) = self else { return nil }
        let numbers = values.compactMap(\.doubleValue)
        return numbers.count == values.count ? numbers : nil
    }
}
