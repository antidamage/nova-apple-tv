import Foundation
import simd

enum PhonoscopeJSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PhonoscopeJSONValue])
    case object([String: PhonoscopeJSONValue])

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
        } else if let value = try? container.decode([PhonoscopeJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PhonoscopeJSONValue].self))
        }
    }

    var objectValue: [String: PhonoscopeJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [PhonoscopeJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> PhonoscopeJSONValue? {
        objectValue?[key]
    }
}

struct PhonoscopeModuleSetting: Decodable, Equatable {
    struct Curve: Decodable, Equatable {
        let type: String
        let exponent: Double
    }

    struct Option: Decodable, Equatable {
        let label: String
        let value: Double
    }

    let id: String
    let label: String
    let description: String?
    let control: String?
    let min: Double
    let max: Double
    let step: Double
    let `default`: Double
    let affects: [String]?
    let curve: Curve?
    let options: [Option]?
    let section: String?
    let updateMode: String?
}

struct PhonoscopePaletteSlot: Decodable, Equatable {
    let id: String
    let label: String
    let defaultRgb: [Double]
}

struct PhonoscopeBoundary: Decodable, Equatable {
    let mode: String
    let restitution: Double
    let then: String?
    let effect: String?
}

struct PhonoscopeBounds: Decodable, Equatable {
    let min: [Double]
    let max: [Double]
}

struct PhonoscopeResources: Decodable, Equatable {
    let maxParticles: Int
    let maxInteractiveFieldEntities: Int
    let maxRenderBatches: Int
}

struct PhonoscopeModule: Decodable, Equatable {
    let engineVersion: Int
    let id: String
    let version: String
    let name: String
    let description: String
    let dimension: String
    let bounds: PhonoscopeBounds
    let boundary: PhonoscopeBoundary
    let settings: [PhonoscopeModuleSetting]
    let paletteSlots: [PhonoscopePaletteSlot]?
    let templates: [String: PhonoscopeJSONValue]
    let scene: [PhonoscopeJSONValue]
    let resources: PhonoscopeResources

    var is3D: Bool { dimension == "3d" }

    var minimum: SIMD3<Float> {
        SIMD3(
            Float(bounds.min[safe: 0] ?? -1),
            Float(bounds.min[safe: 1] ?? -1),
            Float(bounds.min[safe: 2] ?? (is3D ? -1 : 0))
        )
    }

    var maximum: SIMD3<Float> {
        SIMD3(
            Float(bounds.max[safe: 0] ?? 1),
            Float(bounds.max[safe: 1] ?? 1),
            Float(bounds.max[safe: 2] ?? (is3D ? 1 : 0))
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct PhonoscopeModuleSummary: Decodable, Equatable, Identifiable {
    let id: String
    let version: String
    let name: String
    let description: String
    let dimension: String
    let hash: String
    let builtin: Bool
    let settings: [PhonoscopeModuleSetting]
    let paletteSlots: [PhonoscopePaletteSlot]?
}

struct PhonoscopeProviderConfig: Decodable, Equatable {
    let reccoBeats: Bool
    let lrclib: Bool
}

struct PhonoscopeConfiguration: Decodable, Equatable {
    let activeModuleId: String
    let activeModuleVersion: String
    let idleBehavior: String
    let quality: String
    let message: String?
    let statusOverlay: Bool
    let transitionMs: Int
    let providers: PhonoscopeProviderConfig
    let moduleSettings: [String: [String: Double]]
    let moduleParameterSources: [String: [String: PhonoscopeParameterSource]]?
    let pendingStructuralModuleSettings: [String: [String: Double]]
    let moduleReloadGenerations: [String: Int]
    let colorGroups: [PhonoscopeColorGroup]?
    let moduleColorGroupIds: [String: String]?
    let editorPreviewColorGroupId: String?
    let editorPreviewColorThemeId: String?
    let themeGroups: [PhonoscopeThemeGroup]?
    let moduleThemeGroupIds: [String: String]?
}

struct PhonoscopeColorValue: Decodable, Equatable {
    let rgb: [Double]
    let intensity: Double
    let opacity: Double?

    var themeRGB: ThemeRGB {
        let scale = max(0, min(100, intensity)) / 100
        return ThemeRGB(
            red: max(0, min(255, rgb[safe: 0] ?? 0)) * scale,
            green: max(0, min(255, rgb[safe: 1] ?? 0)) * scale,
            blue: max(0, min(255, rgb[safe: 2] ?? 0)) * scale
        )
    }

    var vector: SIMD4<Float> {
        let color = themeRGB
        return SIMD4(
            Float(color.red / 255),
            Float(color.green / 255),
            Float(color.blue / 255),
            Float(max(0, min(100, opacity ?? 100)) / 100)
        )
    }
}

struct PhonoscopeParameterSource: Decodable, Equatable {
    let type: String
    let value: Double?
    let min: Double?
    let max: Double?
    let cadence: String?
    let intervalSeconds: Double?
    let transitionSeconds: Double?
    let attackSeconds: Double?
    let releaseSeconds: Double?
}

struct PhonoscopeColorTheme: Decodable, Equatable {
    let id: String
    let name: String
    let colors: [String: PhonoscopeColorValue]
    let parameterOverrides: [String: [String: PhonoscopeParameterSource]]
}

struct PhonoscopeColorGroup: Decodable, Equatable {
    let id: String
    let moduleId: String
    let name: String
    let themes: [PhonoscopeColorTheme]
    let order: String
    let changeMode: String
    let waitSeconds: Double
    let transitionSeconds: Double
    let housePartyHueMode: String
    let housePartyBrightnessMode: String
}

struct PhonoscopeThemeGroupEntry: Decodable, Equatable {
    let themeId: String
    let baseVariant: String
    let swapOnDownbeat: Bool
    let genres: [String]
}

struct PhonoscopeThemeGroup: Decodable, Equatable {
    let id: String
    let name: String
    let themes: [PhonoscopeThemeGroupEntry]
    let useGenres: Bool
    let order: String
    let changeMode: String
    let waitSeconds: Double
    let transitionSeconds: Double
    let housePartyHueMode: String
    let housePartyBrightnessMode: String
}

struct HousePartySessionEnvelope: Decodable {
    let id: String
    let leaseMs: Int
}

struct HousePartyFramePayload: Encodable {
    let sequence: Int
    let peakRgb: [Int]
    let peakBrightnessPct: Double
    let cloudPeakBrightnessPct: Double
    let transitionSeconds: Double
    let hueMode: String
    let brightnessMode: String
    let ambient: Bool
    let themeId: String?
    let themeVariant: String?
    let themeTransitionSeconds: Double
    let colorThemeId: String?
    let palette: [String: [Int]]?
    let clock: HousePartyMasterClockPayload?
}

struct HousePartyMasterClockPayload: Encodable {
    let trackKey: String?
    let position: Double
    let duration: Double
    let playing: Bool
    let sampledAtMs: Double
}

struct PhonoscopeThemeLibrary: Decodable {
    let entries: [PhonoscopeThemeLibraryEntry]
}

struct PhonoscopeThemeLibraryEntry: Decodable {
    let id: String
    let name: String
    let themeSet: SharedThemePayload
}

struct PhonoscopeConfigurationEnvelope: Decodable {
    let config: PhonoscopeConfiguration
    let modules: [PhonoscopeModuleSummary]
    let themeLibrary: PhonoscopeThemeLibrary?
}

struct PhonoscopeTimedLyric: Decodable, Equatable {
    let time: Double
    let text: String
}

struct PhonoscopeTrackIdentity: Codable, Equatable {
    let appleMusicId: String?
    let isrc: String?
    let title: String
    let artist: String
    let album: String?
    let duration: Double
    let artworkUrl: String?
    let genreNames: [String]?
}

struct PhonoscopeTrackAnalysis: Decodable, Equatable {
    let trackKey: String
    let matched: Bool
    let matchConfidence: Double
    let sourceTier: String
    let bpm: Double?
    let beatOffset: Double
    let beatTimes: [Double]
    let beatSource: String
    let timeSignature: Int
    let key: String?
    let energy: Double?
    let valence: Double?
    let danceability: Double?
    let acousticness: Double?
    let instrumentalness: Double?
    let mood: String?
    let lyrics: [PhonoscopeTimedLyric]
    let providers: [String]
    let warnings: [String]
}

struct PhonoscopeTrackAnalysisEnvelope: Decodable {
    let analysis: PhonoscopeTrackAnalysis
}

enum PhonoscopeSignalQuality: Int, Sendable {
    case idle = 0
    case metadata = 1
    case bpm = 2
    case timeline = 3
    case live = 4
}

struct PhonoscopeSignalFrame: Equatable, Sendable {
    var time: Double
    var delta: Double
    var duration: Double
    var progress: Double
    var playing: Bool
    var bpm: Double
    var beatPhase: Double
    var beatPulse: Double
    var beatIndex: Int
    var barPhase: Double
    var barIndex: Int
    var downbeatPulse: Double
    var energy: Double
    var valence: Double
    var lyricProgress: Double
    var lyricPulse: Double
    var lyricIndex: Int
    var lyricCurrent: String
    var lyricNext: String
    var spectrum: [Float]
    var quality: PhonoscopeSignalQuality
    var trackSeed: UInt64

    static let idle = PhonoscopeSignalFrame(
        time: 0,
        delta: 1.0 / 60.0,
        duration: 0,
        progress: 0,
        playing: false,
        bpm: 72,
        beatPhase: 0,
        beatPulse: 0,
        beatIndex: 0,
        barPhase: 0,
        barIndex: 0,
        downbeatPulse: 0,
        energy: 0.28,
        valence: 0.5,
        lyricProgress: 0,
        lyricPulse: 0,
        lyricIndex: -1,
        lyricCurrent: "",
        lyricNext: "",
        spectrum: Array(repeating: 0, count: 32),
        quality: .idle,
        trackSeed: 0x4e4f_5641
    )
}

struct PhonoscopeRenderParticle {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
    var colorEnd: SIMD4<Float>
    var glowColor: SIMD4<Float>
    var glowColorEnd: SIMD4<Float>
    var size: Float
    var glow: Float
    var primitive: Float
    var material: Float
    var trailDirection: SIMD3<Float>
    var trailLength: Float
}

struct PhonoscopeDiagnostics: Equatable, Sendable {
    var simulationMilliseconds: Double = 0
    var propagationDeliveries: Int = 0
    var droppedEffects: Int = 0
    var roundTrips: Int = 0
    var entityCount: Int = 0
    var particleCount: Int = 0
}

struct PhonoscopeSceneSnapshot {
    let serial: UInt64
    let timestamp: Double
    let particles: [PhonoscopeRenderParticle]
    let background: SIMD4<Float>
    let boundsMinimum: SIMD3<Float>
    let boundsMaximum: SIMD3<Float>
    let is3D: Bool
    let signal: PhonoscopeSignalFrame
    let diagnostics: PhonoscopeDiagnostics
}
