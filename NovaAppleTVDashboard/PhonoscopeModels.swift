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
    /// The centre of the picture when it is text. A non-blank message overrides
    /// whatever image the live colour theme supplies.
    let message: String?
    let statusOverlay: Bool
    let transitionMs: Int
    let providers: PhonoscopeProviderConfig
    let moduleSettings: [String: [String: Double]]
    let pendingStructuralModuleSettings: [String: [String: Double]]
    let moduleReloadGenerations: [String: Int]
    /// Named sets of driver lanes. Which of them apply is decided by the
    /// selected playlist entry, so the whole library arrives here.
    let settingsGroups: [PhonoscopeSettingsGroupConfig]?
    /// The flat colour-only theme library, referenced by colour group entries.
    let colorThemes: [PhonoscopeColorTheme]?
    let colorGroups: [PhonoscopeColorGroup]?
    let moduleColorGroupIds: [String: String]?
    let editorPreviewColorGroupId: String?
    let editorPreviewColorEntryId: String?
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

/// Wire shapes for the driver lanes. They decode into the evaluator's own
/// types in PhonoscopeDrivers.swift; keeping the two separate means the
/// evaluator stays free of Codable and can be compiled on its own for the
/// standalone parity check.
struct PhonoscopeDriverConfig: Decodable, Equatable {
    let type: String
    let every: Int?
    let offset: Int?
    let intervalSeconds: Double?
    let cadence: String?
    let transitionSeconds: Double?

    var spec: PhonoscopeDriverSpec {
        let cycle = Swift.max(1, Swift.min(16, every ?? 1))
        return PhonoscopeDriverSpec(
            type: type,
            every: cycle,
            offset: Swift.max(0, Swift.min(cycle - 1, offset ?? 0)),
            intervalSeconds: intervalSeconds ?? 4,
            cadence: cadence ?? "beat",
            transitionSeconds: transitionSeconds ?? 0.5
        )
    }
}

struct PhonoscopeEffectBindingConfig: Decodable, Equatable {
    let id: String
    let effect: String
    let min: Double?
    let max: Double?
    let attackSeconds: Double?
    let holdSeconds: Double?
    let releaseSeconds: Double?
    let params: [String: Double]?

    var binding: PhonoscopeLaneBinding {
        PhonoscopeLaneBinding(
            id: id, effect: effect, min: min, max: max, attackSeconds: attackSeconds,
            holdSeconds: holdSeconds, releaseSeconds: releaseSeconds, params: params ?? [:])
    }
}

struct PhonoscopeDriverLaneConfig: Decodable, Equatable {
    let id: String
    let driver: PhonoscopeDriverConfig?
    let modifiers: [PhonoscopeDriverConfig]?
    let bindings: [PhonoscopeEffectBindingConfig]?

    var lane: PhonoscopeLane {
        PhonoscopeLane(
            id: id,
            driver: driver?.spec ?? PhonoscopeDriverSpec(type: "beat"),
            modifiers: (modifiers ?? []).map { $0.spec },
            bindings: (bindings ?? []).map { $0.binding })
    }
}

struct PhonoscopeSettingsGroupConfig: Decodable, Equatable {
    let id: String
    let name: String?
    let moduleId: String?
    let lanes: [PhonoscopeDriverLaneConfig]?
    let combine: [String: String]?
    let staticSettings: [String: Double]?
    let isDefault: Bool?

    var group: PhonoscopeSettingsGroupSpec {
        PhonoscopeSettingsGroupSpec(
            id: id,
            name: name ?? id,
            moduleId: moduleId ?? "",
            lanes: (lanes ?? []).map { $0.lane },
            combine: (combine ?? [:]).mapValues { $0 == "strongest" ? .strongest : .add },
            staticSettings: staticSettings ?? [:],
            isDefault: isDefault ?? false)
    }
}

/// The centre slot's image half.
enum PhonoscopeCentreImage {
    /// The default base height, as a percentage of the frame.
    ///
    /// A centre image is a centrepiece, not a backdrop: it sits in the middle of
    /// the picture at a legible size rather than covering it, keeping the
    /// source's proportions exactly. Mirrors
    /// `kCentreImageDefaultHeightPercent` in
    /// nova-visualiser/src/core/centre_image_reference.h; the two are locked
    /// together by `ParitySelfTests.testCentreImageParity()`.
    static let defaultHeightPercent: Double = 33
}

/// Colour, and the picture's centrepiece. Behaviour comes from whichever
/// settings groups the playlist entry names alongside it.
struct PhonoscopeColorTheme: Decodable, Equatable {
    let id: String
    let name: String
    let moduleId: String?
    let colors: [String: PhonoscopeColorValue]
    /// A centre-image library id this theme puts in the middle of the frame.
    let imageId: String?
}

/// One stop on a colour group's rotation. A theme may appear in several
/// entries with different settings groups, which is why an entry carries its
/// own id: the theme id no longer addresses a position in the playlist.
struct PhonoscopeColorGroupEntry: Decodable, Equatable {
    let id: String
    let themeId: String
    let settingsGroupIds: [String]?
}

struct PhonoscopeColorGroup: Decodable, Equatable {
    let id: String
    let moduleId: String
    let name: String
    let entries: [PhonoscopeColorGroupEntry]
    let genres: [String]?
    let isDefault: Bool?
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
    /// Centre-image library id to fetchable URL. The configuration stores ids;
    /// the dashboard resolves them here so no client has to know how its data
    /// directory is laid out. Each URL carries a `?v=` so a re-upload is a new
    /// cache key rather than a stale hit.
    let centreImageUrls: [String: String]?
}

/// Nova-owned runtime colour-theme selection. The streamed and fallback
/// renderers consume the same id so reconnecting cannot reset or fork state.
/// Nova's authoritative rotation choice. The entry, its colour theme and its
/// settings groups arrive together at one revision, so colour and behaviour can
/// never tear apart on a client.
struct PhonoscopeThemeState: Decodable, Equatable {
    let groupId: String
    let entryId: String
    let themeId: String
    let entryIndex: Int
    let settingsGroupIds: [String]?
    let paused: Bool
    let revision: Int
    let changedAtMs: Double
    let transitionSeconds: Double
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
    /// Beats per bar. Carried on the frame so the driver evaluator can turn a
    /// downbeat cycle into a period without reaching back into the analysis.
    /// Defaults to 4 so existing frame construction keeps compiling.
    var timeSignature: Int = 4
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
