import Foundation
import QuartzCore
import simd

private func phonoscopePaletteSlots(in expression: String) -> [String] {
    let parts = expression.components(
        separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted
    )
    return parts.enumerated().compactMap { index, component in
        guard component == "palette", index + 1 < parts.count, !parts[index + 1].isEmpty else { return nil }
        return parts[index + 1]
    }
}

struct PhonoscopePalette: Equatable {
    let colors: [String: SIMD4<Float>]

    var accent: SIMD4<Float> { color("primary", fallback: SIMD4(0.45, 0.45, 0.45, 1)) }
    var highlight: SIMD4<Float> { color("secondary", fallback: SIMD4(0.85, 0.85, 0.85, 1)) }
    var background: SIMD4<Float> { color("backgroundPrimary", fallback: color("background", fallback: SIMD4(0, 0, 0, 1))) }

    func color(_ id: String, fallback: SIMD4<Float>? = nil) -> SIMD4<Float> {
        if let value = colors[id] { return value }
        if id == "accent", let value = colors["primary"] { return value }
        if id == "highlight", let value = colors["secondary"] { return value }
        return fallback ?? accent
    }

    static let `default` = PhonoscopePalette(
        colors: [
            "primary": SIMD4(0.45, 0.45, 0.45, 1),
            "secondary": SIMD4(0.85, 0.85, 0.85, 1),
            "tertiary": SIMD4(0.65, 0.65, 0.65, 1),
            "background": SIMD4(0, 0, 0, 1),
            "backgroundPrimary": SIMD4(0, 0, 0, 1),
            "backgroundSecondary": SIMD4(0.05, 0.07, 0.11, 1),
        ]
    )
}

private struct PhonoscopeSimEntity {
    var position: SIMD3<Float>
    var origin: SIMD3<Float>
    var velocity = SIMD3<Float>(repeating: 0)
    var energy: Float = 0
    var phase: Float = 0
    var age: Float = 0
    var lifetime: Float = 0
    var size: Float = 0.012
    var energySize: Float = 0.028
    var beatSize: Float = 0.004
    var flareThreshold: Float = 2
    var flareSize: Float = 0
    var flareGlow: Float = 0
    var glow: Float = 0.4
    var trailLength: Float = 0
    var primitive: Float = 0
    var material: Float = 0
    var color = SIMD4<Float>(0.22, 0.72, 1, 0.8)
    var usesThemePalette = false
    var paletteStartSlot = "primary"
    var paletteEndSlot = "primary"
    var paletteGlowStartSlot = "primary"
    var paletteGlowEndSlot = "primary"
    var paletteTrailStartSlot = "primary"
    var paletteTrailEndSlot = "primary"
    var usesAnalyticWave = false
    var waveOffset = SIMD3<Float>.zero
    var waveTarget: Float = 0
    var waveEnergy: Float = 0
    var waveAttack: Float = 0.04
    var waveRelease: Float = 0.55
    var inverseMass: Float = 1
    var inertia: Float = 0.985
    var drag: Float = 0
}

private struct PhonoscopeFieldRange {
    let range: Range<Int>
    let columns: Int
    let rows: Int
    let depth: Int
    let topology: String
    let spacing: Float
    let wireframe: PhonoscopeJSONValue?
    let lineStartSlot: String
    let lineEndSlot: String
    let radialBeatWave: PhonoscopeFieldWaveSource?
}

private struct PhonoscopeFieldWaveSource {
    let strength: PhonoscopeJSONValue?
    let speed: PhonoscopeJSONValue?
    let falloff: PhonoscopeJSONValue?
    let wavelength: PhonoscopeJSONValue?
    let steepness: PhonoscopeJSONValue?
    let anticipation: PhonoscopeJSONValue?
    let attack: PhonoscopeJSONValue?
    let release: PhonoscopeJSONValue?
    let flashPower: PhonoscopeJSONValue?
}

private struct PhonoscopeFieldWave {
    let fieldIndex: Int
    let center: SIMD3<Float>
    let speed: Float
    let falloff: Float
    let strength: Float
    let wavelength: Float
    let steepness: Float
    let anticipation: Float
    let attack: Float
    let release: Float
    let flashPower: Float
    let maximumRadius: Float
    var radius: Float = 0
}

private struct PhonoscopeEffectDelivery {
    let receiver: Int
    let source: Int
    let token: UInt64
    let hop: Int
    let strength: Float
}

private struct PhonoscopeEmitter {
    let templateID: String
    let origin: SIMD3<Float>
    let burst: Int
    let maximum: Int
    var emitted: Int
}

struct PhonoscopeSettingTransition: Equatable {
    let start: Double
    let target: Double
    let startedAt: CFTimeInterval
    let duration: Double

    func value(at time: CFTimeInterval) -> Double {
        let amount = duration == 0 ? 1 : min(1, max(0, (time - startedAt) / duration))
        let eased = amount * amount * (3 - 2 * amount)
        return start + (target - start) * eased
    }

    func isComplete(at time: CFTimeInterval) -> Bool {
        duration == 0 || time - startedAt >= duration
    }
}

enum PhonoscopeSettingInterpolationAction: Equatable {
    case hold
    case applyImmediately
    case transition
}

func phonoscopeSettingInterpolationAction(
    targetChanged: Bool,
    wasDriverInterpolated: Bool,
    isDriverInterpolated: Bool
) -> PhonoscopeSettingInterpolationAction {
    if isDriverInterpolated { return .applyImmediately }
    if targetChanged || wasDriverInterpolated { return .transition }
    return .hold
}

/// Fixed-rate, deliberately approximate scene simulation. It owns a dedicated
/// serial queue, ingests immutable signal/module snapshots, and publishes the
/// latest complete render snapshot without ever blocking Metal's draw callback.
final class PhonoscopeSimulation {
    private let queue = DispatchQueue(label: "nz.co.skull.nova.phonoscope.simulation", qos: .userInteractive)
    private let inputLock = NSLock()
    private let outputLock = NSLock()
    private var timer: DispatchSourceTimer?

    private var pendingModule: PhonoscopeModule?
    private var pendingSignal = PhonoscopeSignalFrame.idle
    private var pendingSettings: [String: Double] = [:]
    private var pendingDriverInterpolatedSettings: Set<String> = []
    private var pendingPalette = PhonoscopePalette.default
    private var pendingTransitionDuration: Double = 0.6
    private var pendingReloadGeneration = 0
    private var pendingModuleKey = ""

    private var module: PhonoscopeModule?
    private var signal = PhonoscopeSignalFrame.idle
    private var settings: [String: Double] = [:]
    private var palette = PhonoscopePalette.default
    private var targetSettings: [String: Double] = [:]
    private var driverInterpolatedSettings: Set<String> = []
    private var settingTransitions: [String: PhonoscopeSettingTransition] = [:]
    private var reloadGeneration = 0
    private var moduleKey = ""
    private var entities: [PhonoscopeSimEntity] = []
    private var fields: [PhonoscopeFieldRange] = []
    private var fieldWaves: [PhonoscopeFieldWave] = []
    private var visitedTokens: [UInt64] = []
    private var effectQueue: [PhonoscopeEffectDelivery] = []
    private var emitters: [PhonoscopeEmitter] = []
    private var latestSnapshot: PhonoscopeSceneSnapshot?
    private var serial: UInt64 = 0
    private var effectSequence: UInt64 = 1
    private var lastBeatIndex = Int.min
    private var lastTick = CACurrentMediaTime()

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func update(
        module: PhonoscopeModule?,
        signal: PhonoscopeSignalFrame,
        settings: [String: Double],
        driverInterpolatedSettings: Set<String>,
        palette: PhonoscopePalette,
        transitionDuration: Double,
        reloadGeneration: Int
    ) {
        inputLock.lock()
        pendingModule = module
        pendingSignal = signal
        pendingSettings = settings
        pendingDriverInterpolatedSettings = driverInterpolatedSettings
        pendingPalette = palette
        pendingTransitionDuration = max(0, min(600, transitionDuration))
        pendingReloadGeneration = reloadGeneration
        pendingModuleKey = module.map { "\($0.id)@\($0.version)" } ?? ""
        inputLock.unlock()
    }

    func snapshot() -> PhonoscopeSceneSnapshot? {
        outputLock.lock()
        defer { outputLock.unlock() }
        return latestSnapshot
    }

    private func ingest() {
        inputLock.lock()
        let nextModule = pendingModule
        let nextSignal = pendingSignal
        let nextSettings = pendingSettings
        let nextDriverInterpolatedSettings = pendingDriverInterpolatedSettings
        let nextPalette = pendingPalette
        let nextTransitionDuration = pendingTransitionDuration
        let nextReloadGeneration = pendingReloadGeneration
        let nextKey = pendingModuleKey
        inputLock.unlock()
        let requiresRebuild = nextKey != moduleKey || nextReloadGeneration != reloadGeneration
        let now = CACurrentMediaTime()
        if !requiresRebuild {
            for (key, target) in nextSettings {
                let action = phonoscopeSettingInterpolationAction(
                    targetChanged: targetSettings[key] != target,
                    wasDriverInterpolated: driverInterpolatedSettings.contains(key),
                    isDriverInterpolated: nextDriverInterpolatedSettings.contains(key)
                )
                if action == .applyImmediately {
                    settings[key] = target
                    settingTransitions.removeValue(forKey: key)
                    continue
                }
                if action == .transition {
                    settingTransitions[key] = PhonoscopeSettingTransition(
                        start: settings[key] ?? targetSettings[key] ?? target,
                        target: target,
                        startedAt: now,
                        duration: nextTransitionDuration
                    )
                }
            }
            for key in Array(settings.keys) where nextSettings[key] == nil {
                settings.removeValue(forKey: key)
                settingTransitions.removeValue(forKey: key)
            }
        }
        targetSettings = nextSettings
        driverInterpolatedSettings = nextDriverInterpolatedSettings
        palette = nextPalette
        moduleKey = nextKey
        module = nextModule
        reloadGeneration = nextReloadGeneration
        if requiresRebuild {
            settings = nextSettings
            targetSettings = nextSettings
            driverInterpolatedSettings = nextDriverInterpolatedSettings
            settingTransitions.removeAll(keepingCapacity: true)
            palette = nextPalette
            rebuild()
        }
        signal = nextSignal
    }

    private func tick() {
        autoreleasepool {
            let started = CACurrentMediaTime()
            ingest()
            guard let module else {
                publish(started: started, diagnostics: PhonoscopeDiagnostics())
                return
            }
            let now = CACurrentMediaTime()
            let dt = Float(min(1.0 / 30.0, max(1.0 / 120.0, now - lastTick)))
            lastTick = now
            advanceConfiguration(now: now)
            advanceSignal(by: Double(dt))
            var diagnostics = PhonoscopeDiagnostics()

            if signal.beatIndex != lastBeatIndex {
                lastBeatIndex = signal.beatIndex
                emitBeatParticles(module: module)
                enqueueRootEffects(module: module)
            }
            advanceFieldWaves(dt: dt)
            processEffects(started: started, diagnostics: &diagnostics)
            integrate(dt: dt, module: module)
            diagnostics.entityCount = entities.count
            diagnostics.particleCount = min(module.resources.maxParticles, entities.count)
            publish(started: started, diagnostics: diagnostics)
        }
    }

    private func advanceConfiguration(now: CFTimeInterval) {
        var completed: [String] = []
        for (key, transition) in settingTransitions {
            settings[key] = transition.value(at: now)
            if transition.isComplete(at: now) {
                settings[key] = transition.target
                completed.append(key)
            }
        }
        for key in completed {
            settingTransitions.removeValue(forKey: key)
        }
        if module?.id == "particle-ripples" {
            let threshold = Float(settings["peak_threshold"] ?? 0.28)
            let glow = Float(settings["peak_glow"] ?? 6.5)
            let trail = Float(settings["trail_length"] ?? 7)
            for index in entities.indices {
                entities[index].flareThreshold = threshold
                entities[index].flareGlow = glow
                entities[index].trailLength = trail
            }
        }
    }

    private func advanceSignal(by delta: Double) {
        guard signal.playing else {
            signal.delta = delta
            return
        }
        signal.time += delta
        signal.delta = delta
        signal.progress = signal.duration > 0 ? min(1, signal.time / signal.duration) : 0
        let beatLength = 60 / max(20, signal.bpm)
        let beatValue = signal.time / beatLength
        signal.beatIndex = Int(floor(beatValue))
        signal.beatPhase = beatValue - floor(beatValue)
        signal.beatPulse = pow(max(0, 1 - signal.beatPhase), 5)
        let signature = 4
        signal.barIndex = signal.beatIndex / signature
        signal.barPhase = (Double(signal.beatIndex % signature) + signal.beatPhase) / Double(signature)
        signal.downbeatPulse = signal.beatIndex % signature == 0 ? signal.beatPulse : 0
    }

    private func rebuild() {
        entities.removeAll(keepingCapacity: true)
        fields.removeAll(keepingCapacity: true)
        fieldWaves.removeAll(keepingCapacity: true)
        effectQueue.removeAll(keepingCapacity: true)
        emitters.removeAll(keepingCapacity: true)
        lastBeatIndex = Int.min
        guard let module else { return }
        let maximum = min(module.resources.maxInteractiveFieldEntities, 16_384)
        var seed = signal.trackSeed ^ UInt64(bitPattern: Int64(module.id.hashValue))
        func random() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Float((seed >> 40) & 0x00ff_ffff) / Float(0x00ff_ffff)
        }

        for sceneValue in module.scene {
            let resolvedScene = resolveTemplate(in: sceneValue, module: module)
            guard let field = resolvedScene["field"]?.objectValue else {
                instantiateEntity(resolvedScene, at: .zero, module: module, random: random, depth: 0)
                continue
            }
            let requested = Int(field["count"]?.numberValue ?? 0)
            let resolution = field["resolution"]?.arrayValue?.compactMap(\.numberValue).map(Int.init) ?? []
            let baseColumns = max(1, resolution.first ?? Int(sqrt(Double(max(1, requested)))))
            let baseRows = max(1, resolution.count > 1 ? resolution[1] : max(1, requested / baseColumns))
            let baseDepth = max(1, module.is3D && resolution.count > 2 ? resolution[2] : 1)
            let layout = field["layout"]?.stringValue ?? "grid"
            let inputs = expressionInputs(random: 0.5)
            let density = Float(PhonoscopeExpression.evaluate(field["density"], inputs: inputs, fallback: 1))
            let normalizedDensity = max(0.05, min(1, density))
            let axisScale = module.is3D ? pow(normalizedDensity, 1.0 / 3.0) : sqrt(normalizedDensity)
            let columns = layout == "grid" ? max(1, Int((Float(baseColumns) * axisScale).rounded())) : baseColumns
            let rows = layout == "grid" ? max(1, Int((Float(baseRows) * axisScale).rounded())) : baseRows
            let depth = layout == "grid" ? max(1, Int((Float(baseDepth) * axisScale).rounded())) : baseDepth
            let requestedCount = requested > 0 ? requested : baseColumns * baseRows * baseDepth
            let scaledCount = layout == "grid"
                ? columns * rows * depth
                : Int((Float(requestedCount) * normalizedDensity).rounded())
            let count = min(max(1, scaledCount), maximum - entities.count)
            if count <= 0 { break }
            let start = entities.count
            let declaredSpacing = field["spacing"]?.arrayValue?.compactMap(\.numberValue).map(Float.init) ?? []
            let usesDensity = field["density"] != nil
            func resolvedSpacing(_ declared: Float?, baseCount: Int, scaledCount: Int) -> Float? {
                guard let declared, declared > 0 else { return nil }
                guard usesDensity, baseCount > 1, scaledCount > 1 else { return declared }
                // Density changes entity count, not the visual footprint. Preserve
                // the module author's original grid extent instead of stretching
                // the field to the module's full bounds.
                return declared * Float(baseCount - 1) / Float(scaledCount - 1)
            }
            let spacingX = resolvedSpacing(
                declaredSpacing.first,
                baseCount: baseColumns,
                scaledCount: columns
            )
            let spacingY = resolvedSpacing(
                declaredSpacing.dropFirst().first,
                baseCount: baseRows,
                scaledCount: rows
            )
            let spacingZ = resolvedSpacing(
                declaredSpacing.dropFirst(2).first,
                baseCount: baseDepth,
                scaledCount: depth
            )
            let center = (module.minimum + module.maximum) * 0.5
            let fieldTemplate = field["template"]?.stringValue
                .flatMap { module.templates[$0] }
                .map { resolveTemplate(in: $0, module: module) }
                ?? resolvedScene
            for localIndex in 0..<count {
                let position: SIMD3<Float>
                switch layout {
                case "radial":
                    let angle = Float(localIndex) / Float(max(1, count)) * .pi * 2
                    let radius: Float = module.is3D ? 0.35 + random() * 0.55 : 0.72
                    position = SIMD3(cos(angle) * radius, sin(angle) * radius, module.is3D ? (random() - 0.5) * 1.2 : 0)
                case "random", "volume":
                    position = SIMD3(
                        lerp(module.minimum.x, module.maximum.x, random()),
                        lerp(module.minimum.y, module.maximum.y, random()),
                        module.is3D ? lerp(module.minimum.z, module.maximum.z, random()) : 0
                    )
                case "line":
                    let t = Float(localIndex) / Float(max(1, count - 1))
                    position = SIMD3(lerp(module.minimum.x, module.maximum.x, t), 0, module.is3D ? lerp(module.minimum.z, module.maximum.z, t) : 0)
                default:
                    let x = localIndex % columns
                    let y = (localIndex / columns) % rows
                    let z = (localIndex / max(1, columns * rows)) % depth
                    position = SIMD3(
                        spacingX.map { center.x + (Float(x) - Float(columns - 1) * 0.5) * $0 }
                            ?? lerp(module.minimum.x, module.maximum.x, columns > 1 ? Float(x) / Float(columns - 1) : 0.5),
                        spacingY.map { center.y + (Float(y) - Float(rows - 1) * 0.5) * $0 }
                            ?? lerp(module.minimum.y, module.maximum.y, rows > 1 ? Float(y) / Float(rows - 1) : 0.5),
                        module.is3D
                            ? spacingZ.map { center.z + (Float(z) - Float(depth - 1) * 0.5) * $0 }
                                ?? lerp(module.minimum.z, module.maximum.z, depth > 1 ? Float(z) / Float(depth - 1) : 0.5)
                            : 0
                    )
                }
                entities.append(styledEntity(from: fieldTemplate, position: position, random: random))
            }
            let fallbackSpacingX = columns > 1 ? (module.maximum.x - module.minimum.x) / Float(columns - 1) : 1
            let fallbackSpacingY = rows > 1 ? (module.maximum.y - module.minimum.y) / Float(rows - 1) : fallbackSpacingX
            let legacyLineSlots = phonoscopePaletteSlots(
                in: field["wireframeColor"]?["$expr"]?.stringValue ?? ""
            )
            let lineStartSlots = phonoscopePaletteSlots(
                in: field["wireframeColorStart"]?["$expr"]?.stringValue ?? ""
            )
            let lineEndSlots = phonoscopePaletteSlots(
                in: field["wireframeColorEnd"]?["$expr"]?.stringValue ?? ""
            )
            let lineStartSlot = lineStartSlots.first
                ?? legacyLineSlots.first
                ?? "linePrimary"
            let lineEndSlot = lineEndSlots.first
                ?? legacyLineSlots.dropFirst().first
                ?? lineStartSlot
            fields.append(PhonoscopeFieldRange(
                range: start..<entities.count,
                columns: columns,
                rows: rows,
                depth: depth,
                topology: field["topology"]?.stringValue ?? "grid",
                spacing: max(0.0001, min(spacingX ?? fallbackSpacingX, spacingY ?? fallbackSpacingY)),
                wireframe: field["wireframe"],
                lineStartSlot: lineStartSlot,
                lineEndSlot: lineEndSlot,
                radialBeatWave: radialBeatWave(in: resolvedScene)
            ))
            if fields.last?.radialBeatWave != nil {
                for index in start..<entities.count {
                    entities[index].usesAnalyticWave = true
                }
            }
        }

        if entities.isEmpty {
            let count = min(768, maximum)
            for index in 0..<count {
                let angle = Float(index) / Float(count) * .pi * 2
                let radius = 0.22 + 0.7 * random()
                let z = module.is3D ? (random() - 0.5) * 1.4 : 0
                let position = SIMD3(cos(angle) * radius, sin(angle) * radius, z)
                entities.append(PhonoscopeSimEntity(position: position, origin: position, phase: random()))
            }
            fields.append(PhonoscopeFieldRange(
                range: 0..<entities.count,
                columns: entities.count,
                rows: 1,
                depth: 1,
                topology: "nearest",
                spacing: 1,
                wireframe: nil,
                lineStartSlot: "primary",
                lineEndSlot: "primary",
                radialBeatWave: nil
            ))
        }
        visitedTokens = Array(repeating: 0, count: entities.count)
        effectQueue.reserveCapacity(8_192)
    }

    private func resolveTemplate(in value: PhonoscopeJSONValue, module: PhonoscopeModule) -> PhonoscopeJSONValue {
        guard let object = value.objectValue,
              let templateID = object["template"]?.stringValue,
              let template = module.templates[templateID]?.objectValue
        else { return value }
        var merged = template
        for (key, entry) in object where key != "template" {
            merged[key] = entry
        }
        return .object(merged)
    }

    private func instantiateEntity(
        _ value: PhonoscopeJSONValue,
        at position: SIMD3<Float>,
        module: PhonoscopeModule,
        random: () -> Float,
        depth: Int
    ) {
        guard depth <= 4, entities.count < module.resources.maxParticles else { return }
        let resolved = resolveTemplate(in: value, module: module)
        if resolved["render"] != nil || resolved["sprite"] != nil || resolved["mesh"] != nil || resolved["trail"] != nil {
            entities.append(styledEntity(from: resolved, position: position, random: random))
        }
        if let emitter = resolved["emitter"]?.objectValue,
           let templateID = emitter["template"]?.stringValue,
           emitters.count < 256 {
            let inputs = expressionInputs(random: Double(random()))
            let burst = max(1, min(512, Int(PhonoscopeExpression.evaluate(emitter["burst"] ?? emitter["count"], inputs: inputs, fallback: 1).rounded())))
            let maximum = max(1, min(module.resources.maxParticles, Int(emitter["maxParticles"]?.numberValue ?? Double(burst * 32))))
            emitters.append(PhonoscopeEmitter(templateID: templateID, origin: position, burst: burst, maximum: maximum, emitted: 0))
        }
        if let children = resolved["children"]?.arrayValue {
            for child in children.prefix(16) {
                instantiateEntity(child, at: position, module: module, random: random, depth: depth + 1)
            }
        }
    }

    private func styledEntity(
        from value: PhonoscopeJSONValue,
        position: SIMD3<Float>,
        random: () -> Float
    ) -> PhonoscopeSimEntity {
        let render = value["render"]?.objectValue ?? value.objectValue ?? [:]
        let primitiveName = render["primitive"]?.stringValue
            ?? (value["sprite"] != nil ? "sprite" : value["trail"] != nil ? "trail" : "point")
        let materialName = render["material"]?.stringValue ?? "emissive"
        let inputs = expressionInputs(random: Double(random()))
        let glow = Float(PhonoscopeExpression.evaluate(render["glow"], inputs: inputs, fallback: materialName == "emissive" ? 0.65 : 0.15))
        let energySize = Float(PhonoscopeExpression.evaluate(render["energySize"], inputs: inputs, fallback: 0.028))
        let beatSize = Float(PhonoscopeExpression.evaluate(render["beatSize"], inputs: inputs, fallback: 0.004))
        let flareThreshold = Float(PhonoscopeExpression.evaluate(render["flareThreshold"], inputs: inputs, fallback: 2))
        let flareSize = Float(PhonoscopeExpression.evaluate(render["flareSize"], inputs: inputs, fallback: 0))
        let flareGlow = Float(PhonoscopeExpression.evaluate(render["flareGlow"], inputs: inputs, fallback: 0))
        let trailLength = Float(PhonoscopeExpression.evaluate(render["trailLength"], inputs: inputs, fallback: 0))
        let lifetime = Float(PhonoscopeExpression.evaluate(value["lifetime"], inputs: inputs, fallback: 0))
        let transform = value["transform"]?.objectValue
        let scaleValue = transform?["scale"]
        let size: Float
        if let array = scaleValue?.arrayValue, let first = array.first {
            size = Float(PhonoscopeExpression.evaluate(first, inputs: inputs, fallback: 0.025))
        } else {
            size = Float(PhonoscopeExpression.evaluate(scaleValue, inputs: inputs, fallback: 0.025))
        }
        let phase = random()
        let palette = SIMD4<Float>(0.12 + phase * 0.32, 0.54 + phase * 0.34, 0.92, 0.78)
        let paletteExpression = render["color"]?["$expr"]?.stringValue ?? ""
        let colorStartExpression = render["colorStart"]?["$expr"]?.stringValue ?? ""
        let colorEndExpression = render["colorEnd"]?["$expr"]?.stringValue ?? ""
        let glowExpression = render["glowColor"]?["$expr"]?.stringValue ?? ""
        let glowStartExpression = render["glowColorStart"]?["$expr"]?.stringValue ?? ""
        let glowEndExpression = render["glowColorEnd"]?["$expr"]?.stringValue ?? ""
        let trailExpression = render["trailColor"]?["$expr"]?.stringValue ?? ""
        let trailStartExpression = render["trailColorStart"]?["$expr"]?.stringValue ?? ""
        let trailEndExpression = render["trailColorEnd"]?["$expr"]?.stringValue ?? ""
        let usesThemePalette = [
            paletteExpression,
            colorStartExpression,
            colorEndExpression,
            glowExpression,
            glowStartExpression,
            glowEndExpression,
            trailExpression,
            trailStartExpression,
            trailEndExpression,
        ].contains { $0.contains("palette.") }
        let legacyColorSlots = phonoscopePaletteSlots(in: paletteExpression)
        let colorStartSlots = phonoscopePaletteSlots(in: colorStartExpression)
        let colorEndSlots = phonoscopePaletteSlots(in: colorEndExpression)
        let legacyGlowSlots = phonoscopePaletteSlots(in: glowExpression)
        let glowStartSlots = phonoscopePaletteSlots(in: glowStartExpression)
        let glowEndSlots = phonoscopePaletteSlots(in: glowEndExpression)
        let legacyTrailSlots = phonoscopePaletteSlots(in: trailExpression)
        let trailStartSlots = phonoscopePaletteSlots(in: trailStartExpression)
        let trailEndSlots = phonoscopePaletteSlots(in: trailEndExpression)
        let colorStartSlot = colorStartSlots.first ?? legacyColorSlots.first ?? "primary"
        let colorEndSlot = colorEndSlots.first
            ?? legacyColorSlots.dropFirst().first
            ?? colorStartSlot
        let glowStartSlot = glowStartSlots.first
            ?? legacyGlowSlots.first
            ?? colorStartSlot
        let glowEndSlot = glowEndSlots.first
            ?? legacyGlowSlots.dropFirst().first
            ?? glowStartSlot
        let trailStartSlot = trailStartSlots.first
            ?? legacyTrailSlots.first
            ?? colorStartSlot
        let trailEndSlot = trailEndSlots.first
            ?? legacyTrailSlots.dropFirst().first
            ?? trailStartSlot
        let color: SIMD4<Float>
        if let components = render["color"]?.arrayValue?.compactMap(\.numberValue), components.count >= 3 {
            color = SIMD4(
                Float(max(0, min(1, components[0]))),
                Float(max(0, min(1, components[1]))),
                Float(max(0, min(1, components[2]))),
                Float(max(0, min(1, components.count > 3 ? components[3] : 1)))
            )
        } else {
            color = palette
        }
        let physics = value["physics"]?.objectValue
        let mass = Float(PhonoscopeExpression.evaluate(physics?["mass"], inputs: inputs, fallback: 1))
        let inertia = Float(PhonoscopeExpression.evaluate(physics?["inertia"], inputs: inputs, fallback: 0.985))
        let drag = Float(PhonoscopeExpression.evaluate(physics?["drag"], inputs: inputs, fallback: 0))
        return PhonoscopeSimEntity(
            position: position,
            origin: position,
            phase: phase,
            lifetime: max(0, lifetime),
            size: max(0.003, min(0.32, size)),
            energySize: max(0, min(0.32, energySize)),
            beatSize: max(0, min(0.32, beatSize)),
            flareThreshold: max(0, min(2, flareThreshold)),
            flareSize: max(0, min(0.32, flareSize)),
            flareGlow: max(0, min(12, flareGlow)),
            glow: max(0, min(3, glow)),
            trailLength: max(0, min(32, trailLength)),
            primitive: primitiveCode(primitiveName),
            material: materialCode(materialName),
            color: color,
            usesThemePalette: usesThemePalette,
            paletteStartSlot: colorStartSlot,
            paletteEndSlot: colorEndSlot,
            paletteGlowStartSlot: glowStartSlot,
            paletteGlowEndSlot: glowEndSlot,
            paletteTrailStartSlot: trailStartSlot,
            paletteTrailEndSlot: trailEndSlot,
            inverseMass: 1 / max(0.001, mass),
            inertia: max(0, min(1, inertia)),
            drag: max(0, drag)
        )
    }

    private func primitiveCode(_ name: String) -> Float {
        switch name.lowercased() {
        case "ring": return 1
        case "square", "plane", "quad", "sprite": return 2
        case "triangle": return 3
        case "wireframe", "cube", "box", "icosphere": return 4
        case "trail", "line": return 5
        default: return 0
        }
    }

    private func materialCode(_ name: String) -> Float {
        switch name.lowercased() {
        case "phong", "lit": return 1
        case "wireframe": return 2
        default: return 0
        }
    }

    private func expressionInputs(random: Double) -> [String: Double] {
        let bass = Double(signal.spectrum.prefix(8).max() ?? 0)
        var inputs: [String: Double] = [
            "time": signal.time,
            "delta": signal.delta,
            "beat.phase": signal.beatPhase,
            "beat.pulse": signal.beatPulse,
            "bar.phase": signal.barPhase,
            "audio.energy": signal.energy,
            "audio.bass": bass,
            "audio.low": bass,
            "audio.mid": Double(signal.spectrum.dropFirst(8).prefix(12).max() ?? 0),
            "audio.high": Double(signal.spectrum.dropFirst(20).max() ?? 0),
            "lyrics.progress": signal.lyricProgress,
            "lyrics.pulse": signal.lyricPulse,
            "random.x": random,
        ]
        for (index, value) in signal.spectrum.enumerated() {
            inputs["spectrum.\(index)"] = Double(value)
        }
        for (key, value) in settings {
            inputs["settings.\(key)"] = value
        }
        return inputs
    }

    private func radialBeatWave(in scene: PhonoscopeJSONValue) -> PhonoscopeFieldWaveSource? {
        guard let sources = scene["effectSources"]?.arrayValue else { return nil }
        for value in sources {
            guard let source = value.objectValue,
                  source["trigger"]?.stringValue == "beat",
                  source["kind"]?.stringValue == "wave",
                  source["propagation"]?.stringValue == "radial"
            else { continue }
            return PhonoscopeFieldWaveSource(
                strength: source["strength"],
                speed: source["speed"],
                falloff: source["falloff"],
                wavelength: source["wavelength"],
                steepness: source["steepness"],
                anticipation: source["anticipation"],
                attack: source["attack"],
                release: source["release"],
                flashPower: source["flashPower"]
            )
        }
        return nil
    }

    private func emitBeatParticles(module: PhonoscopeModule) {
        guard !emitters.isEmpty, entities.count < module.resources.maxParticles else { return }
        var seed = signal.trackSeed ^ UInt64(bitPattern: Int64(signal.beatIndex)) ^ effectSequence
        func random() -> Float {
            seed = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            return Float((seed >> 40) & 0x00ff_ffff) / Float(0x00ff_ffff)
        }
        let initialEmitterCount = emitters.count
        for index in 0..<initialEmitterCount {
            var emitter = emitters[index]
            let available = min(
                emitter.maximum - emitter.emitted,
                module.resources.maxParticles - entities.count
            )
            let count = min(emitter.burst, max(0, available))
            guard count > 0, let template = module.templates[emitter.templateID] else { continue }
            for _ in 0..<count {
                let start = entities.count
                instantiateEntity(template, at: emitter.origin, module: module, random: random, depth: 1)
                if entities.count > start {
                    let azimuth = random() * .pi * 2
                    let elevation = module.is3D ? (random() - 0.5) * .pi : 0
                    let speed = 0.004 + random() * 0.018
                    entities[start].velocity = SIMD3(
                        cos(azimuth) * cos(elevation) * speed,
                        sin(azimuth) * cos(elevation) * speed,
                        module.is3D ? sin(elevation) * speed : 0
                    )
                }
            }
            emitter.emitted += count
            emitters[index] = emitter
        }
        if visitedTokens.count < entities.count {
            visitedTokens.append(contentsOf: repeatElement(0, count: entities.count - visitedTokens.count))
        }
    }

    private func enqueueRootEffects(module: PhonoscopeModule) {
        effectSequence &+= 1
        let token = (UInt64(bitPattern: Int64(signal.beatIndex)) &* 0x9e37_79b9_7f4a_7c15) ^ effectSequence
        let intensity = Float(settings["intensity"] ?? settings["density"] ?? 1)
        let strength = Float(0.18 + signal.beatPulse * (0.45 + signal.energy * 0.55)) * intensity
        let inputs = expressionInputs(random: 0.5)
        for (fieldIndex, field) in fields.enumerated() {
            let center = field.range.lowerBound + field.range.count / 2
            if let source = field.radialBeatWave {
                let waveStrength = Float(PhonoscopeExpression.evaluate(source.strength, inputs: inputs, fallback: Double(strength)))
                let speed = Float(PhonoscopeExpression.evaluate(source.speed, inputs: inputs, fallback: 0.45))
                let falloff = Float(PhonoscopeExpression.evaluate(source.falloff, inputs: inputs, fallback: 0.94))
                let wavelength = Float(PhonoscopeExpression.evaluate(
                    source.wavelength,
                    inputs: inputs,
                    fallback: Double(field.spacing * 3)
                ))
                let steepness = Float(PhonoscopeExpression.evaluate(source.steepness, inputs: inputs, fallback: 0.85))
                let anticipation = Float(PhonoscopeExpression.evaluate(source.anticipation, inputs: inputs, fallback: 0.42))
                let attack = Float(PhonoscopeExpression.evaluate(source.attack, inputs: inputs, fallback: 0.04))
                let release = Float(PhonoscopeExpression.evaluate(source.release, inputs: inputs, fallback: 0.55))
                let flashPower = Float(PhonoscopeExpression.evaluate(source.flashPower, inputs: inputs, fallback: 4.5))
                let centerPosition = field.range.reduce(SIMD3<Float>.zero) {
                    $0 + entities[$1].origin
                } / Float(max(1, field.range.count))
                let maximumRadius = field.range.reduce(Float.zero) {
                    max($0, simd_distance(entities[$1].origin, centerPosition))
                }
                fieldWaves.append(PhonoscopeFieldWave(
                    fieldIndex: fieldIndex,
                    center: centerPosition,
                    speed: max(0.01, speed),
                    falloff: max(0, min(1, falloff)),
                    strength: max(0, waveStrength),
                    wavelength: max(field.spacing, wavelength),
                    steepness: max(0, min(1, steepness)),
                    anticipation: max(0.02, anticipation),
                    attack: max(0.01, attack),
                    release: max(0.02, release),
                    flashPower: max(0.5, min(12, flashPower)),
                    maximumRadius: maximumRadius
                ))
                if fieldWaves.count > 16 {
                    fieldWaves.removeFirst(fieldWaves.count - 16)
                }
                continue
            }
            effectQueue.append(PhonoscopeEffectDelivery(receiver: center, source: center, token: token, hop: 0, strength: strength))
        }
    }

    private func advanceFieldWaves(dt: Float) {
        let offsetMagnifier = Float(max(0, min(50, settings["offset_magnifier"] ?? 1)))
        for index in entities.indices where entities[index].usesAnalyticWave {
            entities[index].waveOffset = .zero
            entities[index].waveTarget = 0
        }
        if !fieldWaves.isEmpty {
            for waveIndex in fieldWaves.indices {
                let wave = fieldWaves[waveIndex]
                guard fields.indices.contains(wave.fieldIndex) else { continue }
                let field = fields[wave.fieldIndex]
                let nextRadius = wave.radius + wave.speed * dt
                for entityIndex in field.range {
                    let radial = entities[entityIndex].origin - wave.center
                    let distance = simd_length(radial)
                    let distanceToFront = distance - nextRadius
                    let anticipationWidth = max(wave.wavelength * 0.5, wave.speed * wave.anticipation)
                    guard distanceToFront >= -(wave.speed * dt),
                          distanceToFront <= anticipationWidth
                    else { continue }
                    let gridSteps = distance / field.spacing
                    let deliveredStrength = wave.strength * pow(wave.falloff, gridSteps)
                    guard deliveredStrength > 0.005 else { continue }
                    let leadingProgress = max(0, min(1, distanceToFront / anticipationWidth))
                    let approach = 1 - leadingProgress
                    let anticipation = 0.22 * pow(approach, 1.15)
                    let flash = 0.78 * pow(approach, wave.flashPower)
                    let poweredDrive = pow(max(0, min(1, deliveredStrength)), 1.15)
                    let glowSpike = poweredDrive * (anticipation + flash)
                    entities[entityIndex].waveTarget = min(
                        1,
                        entities[entityIndex].waveTarget + glowSpike
                    )
                    entities[entityIndex].waveAttack = wave.attack
                    entities[entityIndex].waveRelease = wave.release

                    if distance > 0.000_001 {
                        let direction = radial / distance
                        let phase = leadingProgress * (.pi / 2)
                        let crest = cos(phase) * pow(approach, 2)
                        let horizontalAmplitude = min(
                            field.spacing * 0.45,
                            wave.steepness * deliveredStrength * field.spacing * 0.7
                        )
                        let gerstnerOffset = direction
                            * horizontalAmplitude
                            * crest
                            * offsetMagnifier
                        entities[entityIndex].waveOffset += SIMD3(
                            gerstnerOffset.x,
                            gerstnerOffset.y,
                            0
                        )
                    }
                }
                fieldWaves[waveIndex].radius = nextRadius
            }
            fieldWaves.removeAll {
                $0.radius > $0.maximumRadius + max($0.wavelength * 0.5, $0.speed * $0.anticipation)
            }
        }

        for index in entities.indices where entities[index].usesAnalyticWave {
            let target = entities[index].waveTarget
            let responseRate: Float
            if target > entities[index].waveEnergy {
                responseRate = (2.3 / entities[index].waveAttack) * (0.45 + 0.55 * pow(target, 2))
            } else {
                responseRate = 2.3 / entities[index].waveRelease
            }
            let response = 1 - exp(-responseRate * dt)
            entities[index].waveEnergy += (target - entities[index].waveEnergy) * response
        }
    }

    private func processEffects(started: CFTimeInterval, diagnostics: inout PhonoscopeDiagnostics) {
        var cursor = 0
        while cursor < effectQueue.count && diagnostics.propagationDeliveries < 8_192 {
            if CACurrentMediaTime() - started >= 0.004 { break }
            let delivery = effectQueue[cursor]
            cursor += 1
            guard delivery.receiver >= 0 && delivery.receiver < entities.count else { continue }
            if visitedTokens[delivery.receiver] == delivery.token {
                diagnostics.roundTrips += 1
                continue
            }
            visitedTokens[delivery.receiver] = delivery.token
            diagnostics.propagationDeliveries += 1
            entities[delivery.receiver].energy = min(2, entities[delivery.receiver].energy + delivery.strength)
            let direction = simd_normalize(entities[delivery.receiver].position + SIMD3<Float>(0.0001, 0.0001, 0.0001))
            entities[delivery.receiver].velocity += direction
                * delivery.strength
                * 0.045
                * entities[delivery.receiver].inverseMass
            guard delivery.hop < 8, delivery.strength > 0.025 else { continue }
            for neighbor in neighbors(of: delivery.receiver) {
                effectQueue.append(PhonoscopeEffectDelivery(
                    receiver: neighbor,
                    source: delivery.receiver,
                    token: delivery.token,
                    hop: delivery.hop + 1,
                    strength: delivery.strength * 0.78
                ))
            }
        }
        if cursor < effectQueue.count {
            diagnostics.droppedEffects = effectQueue.count - cursor
        }
        effectQueue.removeAll(keepingCapacity: true)
    }

    private func neighbors(of index: Int) -> [Int] {
        guard let field = fields.first(where: { $0.range.contains(index) }) else { return [] }
        let local = index - field.range.lowerBound
        if field.topology == "none" { return [] }
        if field.topology == "nearest" || field.topology == "radius" || field.rows == 1 {
            let before = local > 0 ? index - 1 : field.range.upperBound - 1
            let after = local + 1 < field.range.count ? index + 1 : field.range.lowerBound
            return [before, after]
        }
        let x = local % field.columns
        let y = (local / field.columns) % field.rows
        let z = local / max(1, field.columns * field.rows)
        var result: [Int] = []
        func append(_ nx: Int, _ ny: Int, _ nz: Int) {
            guard nx >= 0, nx < field.columns, ny >= 0, ny < field.rows, nz >= 0, nz < field.depth else { return }
            let neighbor = field.range.lowerBound + nz * field.columns * field.rows + ny * field.columns + nx
            if field.range.contains(neighbor) { result.append(neighbor) }
        }
        append(x - 1, y, z)
        append(x + 1, y, z)
        append(x, y - 1, z)
        append(x, y + 1, z)
        if field.depth > 1 {
            append(x, y, z - 1)
            append(x, y, z + 1)
        }
        return result
    }

    private func integrate(dt: Float, module: PhonoscopeModule) {
        let minimum = module.minimum
        let maximum = module.maximum
        let boundaryMode = module.boundary.mode
        let restitution = Float(module.boundary.restitution)
        for index in entities.indices {
            entities[index].age += dt
            if entities[index].lifetime > 0, entities[index].age >= entities[index].lifetime {
                entities[index].age = 0
                entities[index].position = entities[index].origin
                entities[index].energy = max(entities[index].energy, Float(signal.beatPulse))
            }
            if entities[index].usesAnalyticWave {
                entities[index].energy = entities[index].waveEnergy
                entities[index].position = entities[index].origin + entities[index].waveOffset
                entities[index].velocity = .zero
                continue
            }
            entities[index].energy *= pow(0.28, dt)
            let spring = (entities[index].origin - entities[index].position) * 0.45
            let wobble = SIMD3<Float>(
                sin(Float(signal.time) * 0.6 + entities[index].phase * 6.28),
                cos(Float(signal.time) * 0.5 + entities[index].phase * 4.31),
                module.is3D ? sin(Float(signal.time) * 0.4 + entities[index].phase * 5.17) : 0
            ) * (0.003 + entities[index].energy * 0.008)
            entities[index].velocity += (spring + wobble) * dt * entities[index].inverseMass
            let retainedMomentum = pow(entities[index].inertia, dt * 60)
                * exp(-entities[index].drag * dt)
            entities[index].velocity *= retainedMomentum
            entities[index].position += entities[index].velocity
            applyBounds(index: index, minimum: minimum, maximum: maximum, mode: boundaryMode, restitution: restitution, is3D: module.is3D)
        }
    }

    private func applyBounds(index: Int, minimum: SIMD3<Float>, maximum: SIMD3<Float>, mode: String, restitution: Float, is3D: Bool) {
        for axis in 0..<(is3D ? 3 : 2) {
            if entities[index].position[axis] >= minimum[axis] && entities[index].position[axis] <= maximum[axis] { continue }
            switch mode {
            case "wrap":
                entities[index].position[axis] = entities[index].position[axis] < minimum[axis] ? maximum[axis] : minimum[axis]
            case "slide", "clamp":
                entities[index].position[axis] = min(maximum[axis], max(minimum[axis], entities[index].position[axis]))
                entities[index].velocity[axis] = 0
            case "respawn", "despawn":
                entities[index].position = entities[index].origin
                entities[index].velocity = .zero
                entities[index].energy = 0
            default:
                entities[index].position[axis] = min(maximum[axis], max(minimum[axis], entities[index].position[axis]))
                entities[index].velocity[axis] *= -restitution
            }
        }
    }

    private func publish(started: CFTimeInterval, diagnostics initialDiagnostics: PhonoscopeDiagnostics) {
        var diagnostics = initialDiagnostics
        diagnostics.simulationMilliseconds = (CACurrentMediaTime() - started) * 1_000
        var particles: [PhonoscopeRenderParticle] = []
        particles.reserveCapacity(entities.count * 3)
        func renderedColors(for entity: PhonoscopeSimEntity) -> (SIMD4<Float>, SIMD4<Float>) {
            let usesThemePalette = entity.usesThemePalette || module?.id == "particle-ripples"
            guard usesThemePalette else { return (entity.color, entity.color) }
            return (
                palette.color(entity.paletteStartSlot),
                palette.color(entity.paletteEndSlot)
            )
        }
        func renderedGlowColors(for entity: PhonoscopeSimEntity) -> (SIMD4<Float>, SIMD4<Float>) {
            (
                palette.color(entity.paletteGlowStartSlot),
                palette.color(entity.paletteGlowEndSlot)
            )
        }
        func renderedTrailColors(for entity: PhonoscopeSimEntity) -> (SIMD4<Float>, SIMD4<Float>) {
            (
                palette.color(entity.paletteTrailStartSlot),
                palette.color(entity.paletteTrailEndSlot)
            )
        }
        for entity in entities {
            let energy = min(1, max(0, entity.energy))
            let linearFlare = entity.flareThreshold < 1
                ? max(0, min(1, (energy - entity.flareThreshold) / (1 - entity.flareThreshold)))
                : 0
            let flare = linearFlare * linearFlare * (3 - 2 * linearFlare)
            let colors = renderedColors(for: entity)
            let glowColors = renderedGlowColors(for: entity)
            let size = entity.size
                + energy * entity.energySize
                + Float(signal.beatPulse) * entity.beatSize
                + flare * entity.flareSize
            let glow = entity.glow + energy + flare * entity.flareGlow
            particles.append(PhonoscopeRenderParticle(
                position: entity.position,
                color: colors.0,
                colorEnd: colors.1,
                glowColor: glowColors.0,
                glowColorEnd: glowColors.1,
                size: size,
                glow: glow,
                primitive: entity.primitive,
                material: entity.material,
                trailDirection: .zero,
                trailLength: 0
            ))

            let trailDirection = entity.position - entity.origin
            if entity.trailLength > 0,
               linearFlare > 0,
               simd_length_squared(trailDirection) > 0.000_000_01 {
                let trailColors = renderedTrailColors(for: entity)
                particles.append(PhonoscopeRenderParticle(
                    position: entity.position,
                    color: trailColors.0,
                    colorEnd: trailColors.1,
                    glowColor: trailColors.0,
                    glowColorEnd: trailColors.1,
                    size: size,
                    glow: glow,
                    primitive: 5,
                    material: entity.material,
                    trailDirection: trailDirection,
                    trailLength: entity.trailLength
                ))
            }
        }
        let inputs = expressionInputs(random: 0.5)
        for field in fields where field.topology == "grid"
            && PhonoscopeExpression.evaluate(field.wireframe, inputs: inputs, fallback: 0) >= 0.5 {
            guard field.columns > 0, field.rows > 0 else { continue }
            let layerSize = field.columns * field.rows
            func appendLine(from start: Int, to end: Int) {
                guard field.range.contains(start), field.range.contains(end) else { return }
                let source = entities[start]
                let destination = entities[end]
                particles.append(PhonoscopeRenderParticle(
                    position: destination.position,
                    color: palette.color(field.lineStartSlot),
                    colorEnd: palette.color(field.lineEndSlot),
                    glowColor: palette.color(field.lineStartSlot),
                    glowColorEnd: palette.color(field.lineEndSlot),
                    size: max(0.0006, min(source.size, destination.size) * 0.18),
                    glow: 0,
                    primitive: 6,
                    material: 0,
                    trailDirection: destination.position - source.position,
                    trailLength: 1
                ))
            }
            for z in 0..<field.depth {
                for y in 0..<field.rows {
                    for x in 0..<field.columns {
                        let index = field.range.lowerBound + z * layerSize + y * field.columns + x
                        if x + 1 < field.columns { appendLine(from: index, to: index + 1) }
                        if y + 1 < field.rows { appendLine(from: index, to: index + field.columns) }
                    }
                }
            }
        }
        serial &+= 1
        let snapshot = PhonoscopeSceneSnapshot(
            serial: serial,
            timestamp: CACurrentMediaTime(),
            particles: particles,
            background: simd_mix(
                palette.background,
                palette.color("backgroundSecondary", fallback: palette.background),
                SIMD4<Float>(repeating: Float(min(0.35, max(0, signal.energy * 0.35))))
            ),
            boundsMinimum: module?.minimum ?? SIMD3(-1.7778, -1, 0),
            boundsMaximum: module?.maximum ?? SIMD3(1.7778, 1, 0),
            is3D: module?.is3D ?? false,
            signal: signal,
            diagnostics: diagnostics
        )
        outputLock.lock()
        latestSnapshot = snapshot
        outputLock.unlock()
    }

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }
}
