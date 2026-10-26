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
    let divide: Int?
    let intervalSeconds: Double?
    let cadence: String?

    var spec: PhonoscopeDriverSpec {
        let subdivision = divide ?? 1
        // Counting and subdividing are the two directions of one control: a
        // subdivided driver is always "every one", and its offset is nothing.
        let subdivided = subdivision == 2 || subdivision == 4 || subdivision == 8
        let cycle = subdivided ? 1 : Swift.max(1, Swift.min(16, every ?? 1))
        return PhonoscopeDriverSpec(
            type: type,
            every: cycle,
            offset: Swift.max(0, Swift.min(cycle - 1, offset ?? 0)),
            divide: subdivision,
            intervalSeconds: intervalSeconds ?? 4,
            cadence: cadence ?? "beat"
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
    let randomValue: Bool?
    let params: [String: Double]?

    var binding: PhonoscopeLaneBinding {
        PhonoscopeLaneBinding(
            id: id, effect: effect, min: min, max: max, attackSeconds: attackSeconds,
            holdSeconds: holdSeconds, releaseSeconds: releaseSeconds,
            // Sparse like everything else: absent reads as off.
            randomValue: randomValue ?? false, params: params ?? [:])
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
            // Anything unrecognised reads as `add`, which is what every effect
            // did before combine modes existed: a config written by a newer
            // dashboard degrades rather than being rejected.
            combine: (combine ?? [:]).mapValues { PhonoscopeCombineMode(rawValue: $0) ?? .add },
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
    /// A library id this theme puts BEHIND the whole picture, in place of the
    /// procedural backdrop, and under the vignette. Nil means the field draws.
    let backgroundImageId: String?
}

/// How an image is sized against the frame.
///
/// APPEND-ONLY: a stored binding keeps a numeric range on the `__bgFit` /
/// `__centreFit` axes, so renumbering silently repoints configurations that were
/// authored against the old numbers. Mirrors `ImageFit` in
/// nova-visualiser/src/core/image_fit_reference.h.
enum PhonoscopeImageFit: Int {
    case manual = 0
    case fit = 1
    case fill = 2

    static let modeCount = 3

    /// Snapped from the driven axis, exactly as `imageFitFor` does.
    init(value: Double) {
        if value >= 1.5 {
            self = .fill
        } else if value >= 0.5 {
            self = .fit
        } else {
            self = .manual
        }
    }
}

/// Half-extents of a drawn image, in normalised frame coordinates where the
/// whole frame is 1 x 1 and the centre is (0.5, 0.5).
struct PhonoscopeImageExtent: Equatable {
    var halfWidth: Double = 0
    var halfHeight: Double = 0
}

/// The scale axis's bounds, shared by `__messageScale` and `__bgScale`: the SLOT
/// is scaled, not whatever happens to be in it.
enum PhonoscopeImageScale {
    static let minimum: Double = 0.1
    static let maximum: Double = 5.0
}

/// Half-extents of the drawn image.
///
/// The Swift half of `imageHalfExtent` in
/// nova-visualiser/src/core/image_fit_reference.h, locked to it by
/// `ParitySelfTests.testCentreImageParity()`. ONE function for two slots,
/// because the centre image and the background image are sized by the same
/// control set — having answered the question twice is how the two drifted apart
/// in the first place.
///
/// `fit` decides where the base size comes from: manual takes it from the width
/// and height, and fit and fill DERIVE both from the image's own proportions and
/// ignore them. `proportional` makes the height follow the width under a manual
/// fit, so the picture can never be squashed. `scale` multiplies in every mode,
/// which is what lets a fitted or filled backdrop still thump on the beat.
func phonoscopeImageHalfExtent(
    frameAspect: Double,
    imageAspect: Double,
    widthFraction: Double,
    heightFraction: Double,
    scale: Double,
    fit: PhonoscopeImageFit,
    proportional: Bool
) -> PhonoscopeImageExtent {
    // A zero or negative aspect is a decode that produced no pixels, or a frame
    // with no area. Draw nothing rather than dividing by it.
    guard frameAspect > 0, imageAspect > 0 else { return PhonoscopeImageExtent() }

    let clampedScale = min(max(scale, PhonoscopeImageScale.minimum), PhonoscopeImageScale.maximum)
    // The height a proportional image of a given width must have. Both axes are
    // normalised to the frame, so the source's pixel aspect has to be rescaled
    // by the frame's own shape or a square image would not come out square.
    let heightPerWidth = frameAspect / imageAspect

    if fit == .manual {
        let halfWidth = 0.5 * max(0, widthFraction) * clampedScale
        let halfHeight = proportional
            ? halfWidth * heightPerWidth
            : 0.5 * max(0, heightFraction) * clampedScale
        return PhonoscopeImageExtent(halfWidth: halfWidth, halfHeight: halfHeight)
    }

    // Fit and fill are the same construction with opposite extremes: the image
    // keeps its proportions and grows until one axis touches the frame (fit) or
    // until both cover it (fill). Half-extents of 0.5 are exactly the frame.
    let heightWhenWidthFills = 0.5 * heightPerWidth
    let halfHeight = fit == .fit
        ? min(0.5, heightWhenWidthFills)
        : max(0.5, heightWhenWidthFills)
    let scaled = halfHeight * clampedScale
    return PhonoscopeImageExtent(halfWidth: scaled / heightPerWidth, halfHeight: scaled)
}

/// One stop on a colour group's rotation. A theme may appear in several
/// entries with different settings groups, which is why an entry carries its
/// own id: the theme id no longer addresses a position in the playlist.
struct PhonoscopeColorGroupEntry: Decodable, Equatable {
    let id: String
    let themeId: String
    /// A link to a second colour theme, shown instead of `themeId` while Nova
    /// has the household in alt. Nil when this entry has no alternative, in
    /// which case it keeps its own colours and the alt state passes it by.
    let altThemeId: String?
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
    /// The household's alt state. `themeId` above already has it applied, so
    /// this is only needed by the local fallback rotation, which resolves
    /// entries itself when no authoritative state has arrived.
    let altActive: Bool?
    let paused: Bool
    let revision: Int
    let changedAtMs: Double
    let transitionSeconds: Double
    /// How the change is being made, already resolved and latched by the
    /// dashboard from the settings groups in effect when the pulse fired.
    /// Optional so a state published by an older dashboard still decodes, in
    /// which case the picture keeps the cross-fade it always had.
    let transition: PhonoscopeTransitionState?
    /// The backdrop's own, resolved from its own four axes at the same instant
    /// and by the same rule. Separate from the centre's because the two slots
    /// run concurrently: the backdrop can dissolve while the centrepiece slides.
    /// Optional for the same reason as the centre's — an older dashboard
    /// publishes nothing here and the backdrop keeps its cross-fade.
    let backgroundTransition: PhonoscopeTransitionState?
}

/// The published shape of a change: its ramp, and how the image moves.
struct PhonoscopeTransitionState: Decodable, Equatable {
    /// The ramp as a motion profile: attack eases in, hold is the flat middle,
    /// release eases out, and their sum is `transitionSeconds` above.
    let attackSeconds: Double
    let holdSeconds: Double
    let releaseSeconds: Double
    /// 0 cross-fade, 1 flip, 2 slide. Append-only.
    let mode: Double
    let axisDegrees: Double
    let divisions: Double
    let returnFromOrigin: Bool

    var params: PhonoscopeCentreTransitionParams {
        PhonoscopeCentreTransitionParams(
            mode: phonoscopeCentreTransition(for: mode),
            axisRadians: axisDegrees * Double.pi / 180,
            divisions: Int(divisions.rounded()),
            returnFromOrigin: returnFromOrigin)
    }
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
    /// A grid wire's half-width at its SOURCE end; `size` above is the
    /// destination end's. A wire tapers along its length between the two dots it
    /// connects, and the vertex shader interpolates between these two on the
    /// `progress` it already walks the line with. Zero on every other primitive.
    /// Packed into `meta.w`, matching `Simulation::publish`.
    var sourceSize: Float = 0
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
