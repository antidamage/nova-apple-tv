import MetalKit
import QuartzCore
import SwiftUI
import UIKit

private struct OrbGPUCommand {
    var meta = SIMD4<Float>(repeating: 0)
    var geometry0 = SIMD4<Float>(repeating: 0)
    var geometry1 = SIMD4<Float>(repeating: 0)
    var geometry2 = SIMD4<Float>(repeating: 0)
    var geometry3 = SIMD4<Float>(repeating: 0)
    var stopPositions0 = SIMD4<Float>(repeating: 1)
    var stopPositions1 = SIMD4<Float>(repeating: 1)
    var color0 = SIMD4<Float>(repeating: 0)
    var color1 = SIMD4<Float>(repeating: 0)
    var color2 = SIMD4<Float>(repeating: 0)
    var color3 = SIMD4<Float>(repeating: 0)
    var color4 = SIMD4<Float>(repeating: 0)
    var color5 = SIMD4<Float>(repeating: 0)
    var color6 = SIMD4<Float>(repeating: 0)
    var color7 = SIMD4<Float>(repeating: 0)
    var points0 = SIMD4<Float>(repeating: 0)
    var points1 = SIMD4<Float>(repeating: 0)
    var points2 = SIMD4<Float>(repeating: 0)
    var points3 = SIMD4<Float>(repeating: 0)
    var points4 = SIMD4<Float>(repeating: 0)
    var points5 = SIMD4<Float>(repeating: 0)
    var points6 = SIMD4<Float>(repeating: 0)
    var points7 = SIMD4<Float>(repeating: 0)
}

private struct OrbGPUUniforms {
    var viewport: SIMD4<Float>
    var background: SIMD4<Float>
    var accent: SIMD4<Float>
    var highlight: SIMD4<Float>
    var voiceGlow: SIMD4<Float>
    var glass0: SIMD4<Float>
    var glass1: SIMD4<Float>
    var glass2: SIMD4<Float>
    var glass3: SIMD4<Float>
    var background0: SIMD4<Float>
    var background1: SIMD4<Float>
}

struct MetalOrbInput: Equatable {
    var module: OrbModule
    var theme: DashboardTheme
    var load: Double
    var listening: Bool
    var gymAlert: Bool
    var speech: VoiceSpeechSnapshot?
    var speechActive: Bool
    var baseURL: URL
}

struct MetalOrbView: UIViewRepresentable {
    var module: OrbModule
    var theme: DashboardTheme
    var load: Double
    var listening: Bool
    var gymAlert: Bool
    var speech: VoiceSpeechSnapshot?
    var speechActive: Bool
    var baseURL: URL

    func makeCoordinator() -> MetalOrbCoordinator {
        MetalOrbCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        guard let device = context.coordinator.device,
              let renderer = context.coordinator.renderer
        else {
            let fallback = UIView()
            fallback.backgroundColor = UIColor(theme.avatar.gradientCenter.color)
            fallback.layer.cornerRadius = 999
            return fallback
        }

        let view = MTKView(frame: .zero, device: device)
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = false
        view.layer.isOpaque = false
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = renderer
        renderer.input = currentInput
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.renderer?.input = currentInput
        guard let view = uiView as? MTKView else { return }
        // The dashboard enlarges the speaking orb in the compositor. Double the
        // backing resolution during that window so the centred result stays crisp.
        let scale = max(1, UIScreen.main.scale) * (speechActive ? 2 : 1)
        let desired = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        if desired.width > 0, desired.height > 0, view.drawableSize != desired {
            view.drawableSize = desired
        }
    }

    private var currentInput: MetalOrbInput {
        MetalOrbInput(
            module: module,
            theme: theme,
            load: load,
            listening: listening,
            gymAlert: gymAlert,
            speech: speech,
            speechActive: speechActive,
            baseURL: baseURL
        )
    }
}

final class MetalOrbCoordinator {
    let device: MTLDevice?
    let renderer: MetalOrbRenderer?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        renderer = device.flatMap(MetalOrbRenderer.init(device:))
    }
}

final class MetalOrbRenderer: NSObject, MTKViewDelegate {
    private static let targetDPR: Float = 2
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureLoader: MTKTextureLoader
    private let animationModel = OrbAnimationModel()
    private let startTime = CACurrentMediaTime()
    private var previousFrameTime = CACurrentMediaTime()
    private var mosaicTexture: MTLTexture?
    private var loadedTextureKey: String?
    private var textureLoadGeneration = 0
    var input: MetalOrbInput? {
        didSet { updateMosaicTextureIfNeeded() }
    }

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "orbVertex"),
              let fragment = library.makeFunction(name: "orbFragment")
        else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        textureLoader = MTKTextureLoader(device: device)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let input,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        let absoluteNow = CACurrentMediaTime()
        let now = absoluteNow - startTime
        let dt = min(0.1, max(0, absoluteNow - previousFrameTime))
        previousFrameTime = absoluteNow
        let settings = input.module.resolvedSettings(
            saved: input.theme.avatar.orbModuleSettings[input.module.id]
        )
        let speechEnvelope = input.speech?.envelope(
            at: absoluteNow,
            alertPulsePeriod: input.module.alertPulsePeriod
        )
        let alertActive = input.gymAlert || speechEnvelope != nil
        let alertPulse = speechEnvelope ?? (
            alertActive
                ? (1 - cos((now / input.module.alertPulsePeriod) * .pi * 2)) / 2
                : 0
        )
        let palette = OrbPalette(avatar: input.theme.avatar)
        let commands = buildCommands(
            module: input.module,
            settings: settings,
            palette: palette,
            load: clamped(input.listening ? max(input.load, 0.28) : input.load),
            alertActive: alertActive,
            alertPulse: alertPulse,
            now: now,
            dt: dt
        )

        guard !commands.isEmpty,
              let commandData = device.makeBuffer(
                bytes: commands,
                length: commands.count * MemoryLayout<OrbGPUCommand>.stride
              )
        else {
            return
        }

        let glass = input.theme.avatar.glass
        let scale = Float(view.contentScaleFactor > 0 ? view.contentScaleFactor : 1)
        var uniforms = OrbGPUUniforms(
            viewport: SIMD4(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height),
                Float(min(view.drawableSize.width, view.drawableSize.height) * 0.48),
                Float(input.load)
            ),
            background: input.theme.background.vector,
            accent: input.theme.accent.vector,
            highlight: input.theme.highlight.vector,
            voiceGlow: input.theme.avatar.voiceGlowColor.vector,
            glass0: SIMD4(
                glass.enabled ? 1 : 0,
                Float(glass.displace / 100),
                Float(glass.localStretch / 100),
                glass.flipVertical ? 1 : 0
            ),
            glass1: SIMD4(
                Float(glass.refractPower / 100),
                Float(glass.smoothness / 100),
                Float(glass.imageBlur / 10),
                Float(glass.refractionOpacity / 100)
            ),
            glass2: SIMD4(
                Float(glass.clarity / 100),
                Float(glass.gloss / 100),
                Float(glass.shadow / 100),
                Float(glass.reflection / 100)
            ),
            glass3: SIMD4(
                Float(glass.drift / 100),
                Float(commands.count),
                (input.listening || input.speechActive) ? 1 : 0,
                mosaicTexture == nil ? 0 : 1
            ),
            background0: SIMD4(
                Float(input.theme.backgroundEffect.peakIntensity / 100),
                Float(input.theme.backgroundEffect.falloffPower / 100),
                Float(input.theme.backgroundEffect.warpAmplitude / 100),
                Float(input.theme.backgroundEffect.hueSpread / 100)
            ),
            background1: SIMD4(
                Float(input.theme.backgroundEffect.apexGlow / 100),
                Float(input.theme.backgroundEffect.textureScale / 100),
                Self.targetDPR / max(1, scale),
                Float(now)
            )
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OrbGPUUniforms>.stride, index: 0)
        encoder.setFragmentBuffer(commandData, offset: 0, index: 1)
        encoder.setFragmentTexture(mosaicTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func buildCommands(
        module: OrbModule,
        settings: [String: Double],
        palette: OrbPalette,
        load: Double,
        alertActive: Bool,
        alertPulse: Double,
        now: TimeInterval,
        dt: Double
    ) -> [OrbGPUCommand] {
        _ = animationModel.beginFrame(module: module, now: now)
        var result: [OrbGPUCommand] = []
        result.reserveCapacity(96)
        for (layerIndex, layer) in module.layers.enumerated() {
            let base = layer.base
            guard base.enabled else { continue }
            var opacity = base.opacity
            if let pulse = base.pulse {
                if pulse.alertOnly && !alertActive { continue }
                let wave = (1 - cos((now / pulse.period) * .pi * 2)) / 2
                opacity *= pulse.min + (pulse.max - pulse.min) * wave
            }
            guard opacity > 0 else { continue }

            switch layer {
            case .disc(let disc):
                var command = baseCommand(kind: 0, base: base, opacity: opacity)
                command.geometry0 = SIMD4(
                    Float(disc.center.x), Float(disc.center.y),
                    Float(disc.radius), Float(disc.scaleY)
                )
                let from = disc.gradientFrom
                let to = disc.gradientTo
                command.geometry1 = SIMD4(
                    Float(disc.rotation),
                    Float(from?.x ?? disc.center.x),
                    Float(from?.y ?? disc.center.y),
                    Float(from?.radius ?? 0)
                )
                command.geometry2 = SIMD4(
                    Float(to?.x ?? disc.center.x),
                    Float(to?.y ?? disc.center.y),
                    Float(to?.radius ?? disc.radius),
                    Float(base.glow)
                )
                applyStops(disc.stops, to: &command, palette: palette, alertPulse: alertPulse)
                result.append(command)

            case .ring(let ring):
                var command = baseCommand(kind: 1, base: base, opacity: opacity)
                let turbulence = ring.turbulence
                let fibers = clamped(
                    turbulence?.fibers?.resolved(settings: settings, fallback: 1) ?? 1,
                    1, 12
                )
                let chaos = clamped(
                    turbulence?.chaos?.resolved(settings: settings, fallback: 0) ?? 0,
                    0, 100
                )
                let weave = clamped(
                    turbulence?.weave?.resolved(settings: settings, fallback: 0) ?? 0,
                    0, 100
                )
                let speed = clamped(
                    turbulence?.speed?.resolved(settings: settings, fallback: 0) ?? 0,
                    0, 100
                )
                let pulse = clamped(
                    turbulence?.pulse?.resolved(settings: settings, fallback: 0) ?? 0,
                    0, 100
                )
                let softness = clamped(
                    turbulence?.softness?.resolved(settings: settings, fallback: 0) ?? 0,
                    0, 100
                )
                command.geometry0 = SIMD4(
                    Float(ring.radius), Float(ring.width), Float(fibers), Float(chaos)
                )
                command.geometry1 = SIMD4(
                    Float(weave), Float(speed), Float(pulse), Float(softness)
                )
                command.geometry2.w = Float(base.glow + softness / 100 * 0.035)
                command.color0 = gpuColor(
                    resolveOrbColor(ring.color, palette: palette, alertPulse: alertPulse)
                )
                result.append(command)

            case .arc(let arc):
                result.append(arcCommand(
                    radius: arc.radius,
                    width: arc.width,
                    from: arc.from,
                    to: arc.to,
                    reverse: arc.reverse,
                    stops: arc.stops,
                    base: base,
                    opacity: opacity,
                    palette: palette,
                    alertPulse: alertPulse
                ))

            case .arcField(let field):
                let segments = animationModel.arcSegments(
                    layerIndex: layerIndex,
                    layer: field,
                    load: load,
                    now: now,
                    dt: dt
                )
                for segment in segments where segment.colorIndex < field.colors.count {
                    let ref = field.colors[segment.colorIndex]
                    let color = resolveOrbColor(ref, palette: palette, alertPulse: alertPulse)
                    result.append(arcCommand(
                        radius: segment.baseRadius,
                        width: segment.width,
                        from: segment.angle,
                        to: segment.angle + segment.sweep,
                        reverse: false,
                        stops: [
                            OrbGradientStop(at: 0, color: ref),
                            OrbGradientStop(at: 1, color: ref)
                        ],
                        base: base,
                        opacity: opacity,
                        palette: palette,
                        alertPulse: alertPulse,
                        resolvedOverride: color
                    ))
                    if result.count >= 512 { return result }
                }

            case .line(let line):
                result.append(lineCommand(
                    from: line.from,
                    to: line.to,
                    width: line.width,
                    color: resolveOrbColor(line.color, palette: palette, alertPulse: alertPulse),
                    base: base,
                    opacity: opacity
                ))

            case .polygon(let polygon):
                var command = baseCommand(kind: 4, base: base, opacity: opacity)
                let points = Array(polygon.points.prefix(16))
                command.geometry0 = SIMD4(
                    Float(points.count), polygon.fill ? 1 : 0,
                    Float(polygon.width), polygon.close ? 1 : 0
                )
                command.geometry2.w = Float(base.glow)
                command.color0 = gpuColor(
                    resolveOrbColor(polygon.color, palette: palette, alertPulse: alertPulse)
                )
                applyPoints(points, to: &command)
                result.append(command)

            case .lineField(let field):
                let segments = animationModel.lineSegments(
                    layerIndex: layerIndex,
                    layer: field,
                    load: load,
                    now: now,
                    dt: dt
                )
                for segment in segments
                    where segment.trackIndex < field.tracks.count &&
                        segment.colorIndex < field.colors.count
                {
                    let track = field.tracks[segment.trackIndex]
                    let t0 = segment.position - segment.length / 2
                    let t1 = segment.position + segment.length / 2
                    let from = OrbPoint(
                        x: track.from.x + (track.to.x - track.from.x) * t0,
                        y: track.from.y + (track.to.y - track.from.y) * t0
                    )
                    let to = OrbPoint(
                        x: track.from.x + (track.to.x - track.from.x) * t1,
                        y: track.from.y + (track.to.y - track.from.y) * t1
                    )
                    result.append(lineCommand(
                        from: from,
                        to: to,
                        width: segment.width,
                        color: resolveOrbColor(
                            field.colors[segment.colorIndex],
                            palette: palette,
                            alertPulse: alertPulse
                        ),
                        base: base,
                        opacity: opacity
                    ))
                    if result.count >= 512 { return result }
                }
            }
            if result.count >= 512 { return result }
        }
        return result
    }

    private func baseCommand(kind: Float, base: OrbLayerBase, opacity: Double) -> OrbGPUCommand {
        var command = OrbGPUCommand()
        command.meta = SIMD4(
            kind,
            Float(blendIndex(base.blend)),
            Float(opacity),
            base.clip ? 1 : 0
        )
        command.geometry2.w = Float(base.glow)
        return command
    }

    private func arcCommand(
        radius: Double,
        width: Double,
        from: Double,
        to: Double,
        reverse: Bool,
        stops: [OrbGradientStop],
        base: OrbLayerBase,
        opacity: Double,
        palette: OrbPalette,
        alertPulse: Double,
        resolvedOverride: OrbResolvedColor? = nil
    ) -> OrbGPUCommand {
        var command = baseCommand(kind: 2, base: base, opacity: opacity)
        command.geometry0 = SIMD4(Float(radius), Float(width), Float(from), Float(to))
        command.geometry1.x = reverse ? 1 : 0
        command.geometry2.w = Float(base.glow)
        applyStops(stops, to: &command, palette: palette, alertPulse: alertPulse)
        if let resolvedOverride {
            let value = gpuColor(resolvedOverride)
            command.color0 = value
            command.color1 = value
            command.geometry3.x = 2
            command.stopPositions0 = SIMD4(0, 1, 1, 1)
        }
        return command
    }

    private func lineCommand(
        from: OrbPoint,
        to: OrbPoint,
        width: Double,
        color: OrbResolvedColor,
        base: OrbLayerBase,
        opacity: Double
    ) -> OrbGPUCommand {
        var command = baseCommand(kind: 3, base: base, opacity: opacity)
        command.geometry0 = SIMD4(Float(from.x), Float(from.y), Float(to.x), Float(to.y))
        command.geometry1.x = Float(width)
        command.geometry2.w = Float(base.glow)
        command.color0 = gpuColor(color)
        return command
    }

    private func applyStops(
        _ stops: [OrbGradientStop],
        to command: inout OrbGPUCommand,
        palette: OrbPalette,
        alertPulse: Double
    ) {
        let values = Array(stops.prefix(8))
        command.geometry3.x = Float(max(1, values.count))
        var positions = Array(repeating: Float(1), count: 8)
        var colors = Array(repeating: SIMD4<Float>(repeating: 0), count: 8)
        for (index, stop) in values.enumerated() {
            positions[index] = Float(stop.at)
            colors[index] = gpuColor(
                resolveOrbColor(stop.color, palette: palette, alertPulse: alertPulse)
            )
        }
        if values.isEmpty {
            colors[0] = SIMD4(1, 1, 1, 1)
            positions[0] = 0
        }
        command.stopPositions0 = SIMD4(positions[0], positions[1], positions[2], positions[3])
        command.stopPositions1 = SIMD4(positions[4], positions[5], positions[6], positions[7])
        command.color0 = colors[0]
        command.color1 = colors[1]
        command.color2 = colors[2]
        command.color3 = colors[3]
        command.color4 = colors[4]
        command.color5 = colors[5]
        command.color6 = colors[6]
        command.color7 = colors[7]
    }

    private func applyPoints(_ points: [OrbPoint], to command: inout OrbGPUCommand) {
        var packed = Array(repeating: SIMD4<Float>(repeating: 0), count: 8)
        for (index, point) in points.enumerated() {
            let vector = index / 2
            if index.isMultiple(of: 2) {
                packed[vector].x = Float(point.x)
                packed[vector].y = Float(point.y)
            } else {
                packed[vector].z = Float(point.x)
                packed[vector].w = Float(point.y)
            }
        }
        command.points0 = packed[0]
        command.points1 = packed[1]
        command.points2 = packed[2]
        command.points3 = packed[3]
        command.points4 = packed[4]
        command.points5 = packed[5]
        command.points6 = packed[6]
        command.points7 = packed[7]
    }

    private func blendIndex(_ blend: OrbBlendModeSpec) -> Int {
        switch blend {
        case .normal: return 0
        case .additive: return 1
        case .screen: return 2
        case .multiply: return 3
        }
    }

    private func gpuColor(_ color: OrbResolvedColor) -> SIMD4<Float> {
        SIMD4(
            Float(color.rgb.red / 255),
            Float(color.rgb.green / 255),
            Float(color.rgb.blue / 255),
            Float(color.alpha)
        )
    }

    private func updateMosaicTextureIfNeeded() {
        guard let input else { return }
        let key = input.theme.backgroundEffect.textureURL ?? ""
        guard key != loadedTextureKey else { return }
        loadedTextureKey = key
        textureLoadGeneration += 1
        guard let value = input.theme.backgroundEffect.textureURL,
              let url = resolvedTextureURL(value, baseURL: input.baseURL)
        else {
            mosaicTexture = nil
            return
        }
        let generation = textureLoadGeneration
        let loader = textureLoader
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else { return }
            let texture = try? loader.newTexture(
                data: data,
                options: [.SRGB: NSNumber(value: false), .generateMipmaps: NSNumber(value: false)]
            )
            DispatchQueue.main.async {
                guard generation == self.textureLoadGeneration else { return }
                self.mosaicTexture = texture
            }
        }.resume()
    }

    private func resolvedTextureURL(_ value: String, baseURL: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }
}
