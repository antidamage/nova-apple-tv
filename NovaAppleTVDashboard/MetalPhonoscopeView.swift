import MetalKit
import SwiftUI

// Quality is no longer configurable. Lowering it never recovered frame rate, so
// the visualiser always renders at the highest setting the device supports.
func phonoscopeAASampleCount(supportsFourSamples: Bool) -> Int {
    supportsFourSamples ? 4 : 1
}

private struct PhonoscopeGPUParticle {
    var positionSize: SIMD4<Float>
    var color: SIMD4<Float>
    var colorEnd: SIMD4<Float>
    var glowColor: SIMD4<Float>
    var glowColorEnd: SIMD4<Float>
    var meta: SIMD4<Float>
    var trail: SIMD4<Float>
}

private struct PhonoscopeGPUUniforms {
    var viewport: SIMD4<Float>
    var boundsMin: SIMD4<Float>
    var boundsMax: SIMD4<Float>
    var signal: SIMD4<Float>
}

private struct PhonoscopeBloomUniforms {
    var texelStep: SIMD2<Float>
    var intensity: Float
    var padding: Float = 0
    var background: SIMD4<Float> = .zero
}

private struct PhonoscopeGlowUniforms {
    var axisTexel: SIMD2<Float> = .zero
    var sigma: Float = 0
    var opacity: Float = 0
    var overdrive: Float = 1
    var glowClamped: Int32 = 1
    var blendMode: Int32 = 1
}

/// Photoshop's blend modes for the glow layer, numbered as the `__glowBlend`
/// driver axis numbers them. Mirrors `nova::GlowBlendMode` in
/// `src/core/effect_scale.h`; the raw values are the shaders' `blendMode`
/// uniform, so modes are only ever appended.
enum PhonoscopeGlowBlendMode: Int, Equatable {
    case screen = 0
    case multiply = 1
    case overlay = 2

    /// Mirrors `nova::glowBlendModeFor`. Drivers produce a continuous number,
    /// so it snaps to the nearest whole mode — deliberately a cut and not a
    /// cross-fade, so a swap on the beat reads as a switch.
    init(driven value: Double) {
        let clamped = min(max(value, 0), Double(PhonoscopeGlowBlendMode.modeCount - 1))
        self = PhonoscopeGlowBlendMode(rawValue: Int(floor(clamped + 0.5))) ?? .screen
    }

    static let modeCount = 3

    /// SwiftUI ships all three as compositing modes, which is what the layers
    /// living above the Metal view on the local fallback path use.
    var swiftUI: BlendMode {
        switch self {
        case .screen: return .screen
        case .multiply: return .multiply
        case .overlay: return .overlay
        }
    }
}

/// How the scene layer meets the backdrop. Mirrors `nova::SceneBlendMode` in
/// `core/effect_scale.h`, and sits on its own driven axis (`__sceneBlend`)
/// separate from the glow's — so the numbering is free rather than inherited,
/// but still append-only, because a stored driver range is a pair of numbers
/// on it.
///
/// `linear` is the original composite term and therefore the default, so an
/// undriven picture is composited exactly as it always was.
enum PhonoscopeSceneBlendMode: Int, Equatable {
    case linear = 0
    case screen = 1
    case overlay = 2
    case multiply = 3

    /// Mirrors `nova::sceneBlendModeFor`.
    init(driven value: Double) {
        let clamped = min(max(value, 0), Double(PhonoscopeSceneBlendMode.modeCount - 1))
        self = PhonoscopeSceneBlendMode(rawValue: Int(floor(clamped + 0.5))) ?? .linear
    }

    static let modeCount = 4

    /// Where the two layers actually meet on this engine.
    ///
    /// The streamed renderer has the backdrop as a texture inside its composite
    /// pass, so it blends there (`sceneBlendMode` in composite.frag). This
    /// engine draws the backdrop as a separate view *behind* the Metal view and
    /// leaves the Metal view transparent where uncovered, so the two layers only
    /// ever meet in the compositor — which means the blend has to be a
    /// `BlendMode` on the layer rather than arithmetic in the shader.
    ///
    /// The result is close but not bit-identical to the streamed engine, which
    /// blends in linear HDR before the tonemap while SwiftUI blends the
    /// display-referred result. `core/composite_reference.h` and
    /// `ParitySelfTests.testSceneBlendParity()` lock the formula both sides
    /// intend; this is how far the fallback path can carry it.
    var swiftUI: BlendMode {
        switch self {
        case .linear: return .normal
        case .screen: return .screen
        case .overlay: return .overlay
        case .multiply: return .multiply
        }
    }
}

/// The final glow overlay's parameters, as the dashboard authors them.
///
/// Blur amount, opacity and blend mode are all fully driven Phonoscope
/// parameters, so these arrive already resolved for the current frame — the
/// blend mode as the discrete mode its driver axis snapped to.
/// Frame geometry, the vignette framing it, and how the scene layer meets the
/// backdrop. All five are driven parameters; the defaults are the fixed
/// one-third letterbox and the authored `PhonoscopeEdgeVignette` they replaced,
/// so an undriven picture is the one that was always drawn.
///
/// Mirrors the `__bgHeight` / `__bgWidth` / `__vignetteOpacity` /
/// `__vignetteSize` / `__sceneBlend` block in nova-visualiser's
/// `Engine::applyControlLanes`.
struct PhonoscopePictureFrame: Equatable {
    var backgroundHeight: Double = 1.0 / 3.0
    var backgroundWidth: Double = 1
    /// The rest of the size control set. With a background image on the live
    /// theme these size the image; with none they size the band above, exactly
    /// as they always have. The scale multiplies in every mode, which is what
    /// makes the backdrop able to thump on the beat.
    var backgroundScale: Double = 1
    var backgroundFit: PhonoscopeImageFit = .manual
    var backgroundProportional: Bool = true
    var vignetteOpacity: Double = 0.96
    var vignetteSize: Double = 1
    var sceneBlendMode: PhonoscopeSceneBlendMode = .linear
}

struct PhonoscopeGlowOverlaySettings: Equatable {
    var blurAmount: Double = 0
    var opacity: Double = 0
    var overdrive: Double = 1
    var clamped: Bool = true
    var blendMode: PhonoscopeGlowBlendMode = .screen

    /// Nothing to do when the layer is fully transparent, which is the default.
    /// Worth checking: the pass costs three fullscreen draws and two extra
    /// render targets, and the Apple TV runs this engine only when the streamed
    /// renderer is unavailable — the case where headroom is already scarce.
    var isActive: Bool { opacity > 0.05 }

    /// Mirrors `nova::glowBlurSigmaTexels`. One blur unit is 1.2 pixels of
    /// sigma at 1080p, scaled with output density, then expressed in texels of
    /// the quarter-resolution blur target.
    func blurSigmaTexels(outputHeight: Double) -> Float {
        let amount = min(max(blurAmount, 0), 20)
        let scale = max(1, outputHeight / 1_080)
        return Float(amount * 1.2 * scale / 4)
    }
}

/// What the centre slot's image half is doing this frame.
///
/// The image moved off SwiftUI and into the Metal pass so the Apple TV runs the
/// same three transitions the streamed renderer does rather than approximating
/// them with `.transition(.opacity)`. Everything here is already resolved by
/// `PhonoscopeStore`: which two images, how far through, and the transition the
/// change was LATCHED with when it started.
struct PhonoscopeCentreImageState: Equatable {
    var to: URL?
    var from: URL?
    /// 0 to 1, already shaped by the authored ramp.
    var progress: Double = 1
    var params = PhonoscopeCentreTransitionParams()
    /// Base size as fractions of the frame, how it is fitted, and the driven
    /// multiplier on top. Width is the authored axis; height is read only under
    /// a manual fit with `proportional` off.
    var widthFraction: Double = PhonoscopeCentreImage.defaultHeightPercent / 100
    var heightFraction: Double = PhonoscopeCentreImage.defaultHeightPercent / 100
    var fit: PhonoscopeImageFit = .manual
    var proportional: Bool = true
    var scale: Double = 1

    var isActive: Bool { to != nil || from != nil }
}

/// Uniforms for `phonoscope_centre_image`. Layout must match the Metal struct.
private struct PhonoscopeCentreImageUniforms {
    var halfExtentTo: SIMD2<Float> = .zero
    var halfExtentFrom: SIMD2<Float> = .zero
    var progress: Float = 1
    var frameAspect: Float = 0
    var axisRadians: Float = 0
    var segments: Int32 = 1
    var mode: Int32 = 0
    var hasFrom: Int32 = 0
    var returnFromOrigin: Int32 = 0
}

/// Half-extents of a drawn image, as the Metal passes want them.
///
/// A thin SIMD wrapper over `phonoscopeImageHalfExtent`, which is the shared
/// port of `nova::imageHalfExtent` and is what
/// `ParitySelfTests.testCentreImageParity()` locks against the renderer. Used by
/// BOTH slots: the centre image and the background image are sized by the same
/// control set.
func phonoscopeImageHalfExtentSIMD(
    frameAspect: Double,
    imageAspect: Double,
    widthFraction: Double,
    heightFraction: Double,
    scale: Double,
    fit: PhonoscopeImageFit,
    proportional: Bool
) -> SIMD2<Float> {
    let extent = phonoscopeImageHalfExtent(
        frameAspect: frameAspect, imageAspect: imageAspect,
        widthFraction: widthFraction, heightFraction: heightFraction,
        scale: scale, fit: fit, proportional: proportional)
    return SIMD2(Float(extent.halfWidth), Float(extent.halfHeight))
}

struct MetalPhonoscopeView: UIViewRepresentable {
    let module: PhonoscopeModule?
    let signal: PhonoscopeSignalFrame
    let settings: [String: Double]
    let driverInterpolatedSettings: Set<String>
    let theme: DashboardTheme
    let paletteColors: [String: SIMD4<Float>]
    let transitionDuration: Double
    let transitionPaused: Bool
    let reloadGeneration: Int
    let letterboxedBackground: Bool
    let glowOverlay: PhonoscopeGlowOverlaySettings
    let centreImage: PhonoscopeCentreImageState
    @Binding var measuredFramesPerSecond: Double

    func makeCoordinator() -> MetalPhonoscopeCoordinator {
        MetalPhonoscopeCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        guard let renderer = context.coordinator.renderer else {
            let fallback = UIView()
            fallback.backgroundColor = .black
            return fallback
        }
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = letterboxedBackground
            ? MTLClearColorMake(0, 0, 0, 0)
            : MTLClearColorMake(0, 0, 0, 1)
        view.isOpaque = !letterboxedBackground
        view.backgroundColor = letterboxedBackground ? .clear : .black
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.delegate = renderer
        renderer.view = view
        renderer.letterboxedBackground = letterboxedBackground
        renderer.glowOverlay = glowOverlay
        renderer.centreImage = centreImage
        let fpsBinding = $measuredFramesPerSecond
        renderer.onFPSUpdate = { fpsBinding.wrappedValue = $0 }
        context.coordinator.simulation.start()
        context.coordinator.simulation.update(
            module: module,
            signal: signal,
            settings: settings,
            driverInterpolatedSettings: driverInterpolatedSettings,
            palette: palette,
            transitionDuration: transitionDuration,
            transitionPaused: transitionPaused,
            reloadGeneration: reloadGeneration
        )
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.renderer?.letterboxedBackground = letterboxedBackground
        context.coordinator.renderer?.glowOverlay = glowOverlay
        context.coordinator.renderer?.centreImage = centreImage
        let fpsBinding = $measuredFramesPerSecond
        context.coordinator.renderer?.onFPSUpdate = { fpsBinding.wrappedValue = $0 }
        if let view = uiView as? MTKView {
            view.isOpaque = !letterboxedBackground
            view.backgroundColor = letterboxedBackground ? .clear : .black
        }
        context.coordinator.simulation.update(
            module: module,
            signal: signal,
            settings: settings,
            driverInterpolatedSettings: driverInterpolatedSettings,
            palette: palette,
            transitionDuration: transitionDuration,
            transitionPaused: transitionPaused,
            reloadGeneration: reloadGeneration
        )
    }

    private var palette: PhonoscopePalette {
        var colors = paletteColors
        if colors["primary"] == nil { colors["primary"] = theme.accent.vector }
        if colors["secondary"] == nil { colors["secondary"] = theme.highlight.vector }
        if colors["background"] == nil { colors["background"] = theme.background.vector }
        return PhonoscopePalette(colors: colors)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: MetalPhonoscopeCoordinator) {
        coordinator.simulation.stop()
        coordinator.renderer?.onFPSUpdate = nil
        if let view = uiView as? MTKView { view.delegate = nil }
    }
}

final class MetalPhonoscopeCoordinator {
    let simulation = PhonoscopeSimulation()
    let renderer: MetalPhonoscopeRenderer?

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            renderer = nil
            return
        }
        renderer = MetalPhonoscopeRenderer(device: device, simulation: simulation)
    }
}

final class MetalPhonoscopeRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    weak var view: MTKView?
    private let simulation: PhonoscopeSimulation
    private let commandQueue: MTLCommandQueue
    private let particlePipeline: MTLRenderPipelineState
    private let particleAAPipeline: MTLRenderPipelineState?
    private let bloomExtractPipeline: MTLRenderPipelineState
    private let bloomBlurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    // The glow overlay needs the composite in a texture it can sample, so it
    // gets its own composite pipeline writing to an offscreen frame target.
    // Without the overlay the composite still goes straight to the drawable.
    private let compositeToFramePipeline: MTLRenderPipelineState
    private let glowBlurPipeline: MTLRenderPipelineState
    private let glowOverlayPipeline: MTLRenderPipelineState
    // The centre slot's image half, drawn between the composite and the glow
    // overlay so it blooms with the rest of the picture.
    private let centreImagePipeline: MTLRenderPipelineState
    private var particleBuffer: MTLBuffer?
    private var particleCapacity = 0
    private var hdrTexture: MTLTexture?
    private var multisampleHDRTexture: MTLTexture?
    private var bloomTextureA: MTLTexture?
    private var bloomTextureB: MTLTexture?
    private var frameTexture: MTLTexture?
    private var glowTextureA: MTLTexture?
    private var glowTextureB: MTLTexture?
    private var renderTargetSize = MTLSize()
    private var lastSerial: UInt64 = 0
    private var particles: [PhonoscopeGPUParticle] = []
    private var snapshot: PhonoscopeSceneSnapshot?
    private var slowFrames = 0
    private var fastFrames = 0
    private var renderScale: CGFloat = 1
    private var fpsWindowStartedAt: CFTimeInterval?
    private var completedFramesInWindow = 0
    var letterboxedBackground = false
    var glowOverlay = PhonoscopeGlowOverlaySettings()
    var centreImage = PhonoscopeCentreImageState()
    var onFPSUpdate: ((Double) -> Void)?
    /// Decoded centre images, by source URL. Small and long-lived: a colour
    /// group rotates back through the same handful of images indefinitely, so
    /// re-decoding a PNG on every pass of the playlist would be pure waste.
    private var centreImageTextures: [URL: MTLTexture] = [:]
    /// URLs a load is already in flight for, so a miss on consecutive frames
    /// starts one download rather than sixty.
    private var centreImageLoading: Set<URL> = []

    init?(device: MTLDevice, simulation: PhonoscopeSimulation) {
        self.device = device
        self.simulation = simulation
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "phonoscope_vertex"),
              let fragment = library.makeFunction(name: "phonoscope_fragment"),
              let fullscreenVertex = library.makeFunction(name: "phonoscope_fullscreen_vertex"),
              let bloomExtract = library.makeFunction(name: "phonoscope_bloom_extract"),
              let bloomBlur = library.makeFunction(name: "phonoscope_bloom_blur"),
              let composite = library.makeFunction(name: "phonoscope_composite"),
              let glowBlur = library.makeFunction(name: "phonoscope_glow_blur"),
              let glowOverlay = library.makeFunction(name: "phonoscope_glow_overlay"),
              let centreImage = library.makeFunction(name: "phonoscope_centre_image")
        else { return nil }
        commandQueue = queue

        func particleDescriptor(sampleCount: Int) -> MTLRenderPipelineDescriptor {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.rasterSampleCount = sampleCount
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return descriptor
        }

        func fullscreenDescriptor(fragment: MTLFunction, format: MTLPixelFormat) -> MTLRenderPipelineDescriptor {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = fullscreenVertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = format
            return descriptor
        }

        let extractDescriptor = fullscreenDescriptor(fragment: bloomExtract, format: .rgba16Float)
        let blurDescriptor = fullscreenDescriptor(fragment: bloomBlur, format: .rgba16Float)
        let compositeDescriptor = fullscreenDescriptor(fragment: composite, format: .bgra8Unorm)
        compositeDescriptor.colorAttachments[0].isBlendingEnabled = true
        compositeDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        compositeDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        compositeDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        compositeDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        // Same shader, same blend, but into an offscreen bgra8Unorm frame the
        // glow pass can read back. Kept as a separate state rather than
        // switching the drawable's format, so the no-overlay path is byte for
        // byte what it was.
        let compositeToFrameDescriptor = fullscreenDescriptor(fragment: composite, format: .bgra8Unorm)
        compositeToFrameDescriptor.colorAttachments[0].isBlendingEnabled = true
        compositeToFrameDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        compositeToFrameDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        compositeToFrameDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        compositeToFrameDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let glowBlurDescriptor = fullscreenDescriptor(fragment: glowBlur, format: .bgra8Unorm)
        let glowOverlayDescriptor = fullscreenDescriptor(fragment: glowOverlay, format: .bgra8Unorm)
        // Drawn OVER whatever the composite left, so it blends rather than
        // replaces. Premultiplied source, matching the decode below and the
        // (GL_ONE, GL_ONE_MINUS_SRC_ALPHA) the renderer uses for the same pass.
        let centreImageDescriptor = fullscreenDescriptor(fragment: centreImage, format: .bgra8Unorm)
        centreImageDescriptor.colorAttachments[0].isBlendingEnabled = true
        centreImageDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        centreImageDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        centreImageDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        centreImageDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            particlePipeline = try device.makeRenderPipelineState(
                descriptor: particleDescriptor(sampleCount: 1)
            )
            particleAAPipeline = device.supportsTextureSampleCount(4)
                ? try device.makeRenderPipelineState(descriptor: particleDescriptor(sampleCount: 4))
                : nil
            bloomExtractPipeline = try device.makeRenderPipelineState(descriptor: extractDescriptor)
            bloomBlurPipeline = try device.makeRenderPipelineState(descriptor: blurDescriptor)
            compositePipeline = try device.makeRenderPipelineState(descriptor: compositeDescriptor)
            compositeToFramePipeline = try device.makeRenderPipelineState(
                descriptor: compositeToFrameDescriptor
            )
            glowBlurPipeline = try device.makeRenderPipelineState(descriptor: glowBlurDescriptor)
            glowOverlayPipeline = try device.makeRenderPipelineState(
                descriptor: glowOverlayDescriptor
            )
            centreImagePipeline = try device.makeRenderPipelineState(
                descriptor: centreImageDescriptor
            )
        } catch {
            return nil
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let started = CACurrentMediaTime()
        if let next = simulation.snapshot(), next.serial != lastSerial {
            lastSerial = next.serial
            snapshot = next
            particles = next.particles.map {
                PhonoscopeGPUParticle(
                    positionSize: SIMD4($0.position.x, $0.position.y, $0.position.z, $0.size),
                    color: $0.color,
                    colorEnd: $0.colorEnd,
                    glowColor: $0.glowColor,
                    glowColorEnd: $0.glowColorEnd,
                    meta: SIMD4($0.glow, $0.primitive, $0.material, 0),
                    trail: SIMD4(
                        $0.trailDirection.x,
                        $0.trailDirection.y,
                        $0.trailDirection.z,
                        $0.trailLength
                    )
                )
            }
            ensureParticleCapacity(particles.count)
            if let particleBuffer, !particles.isEmpty {
                particles.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress {
                        memcpy(particleBuffer.contents(), base, bytes.count)
                    }
                }
            }
            view.clearColor = letterboxedBackground
                ? MTLClearColorMake(0, 0, 0, 0)
                : MTLClearColor(
                    red: Double(next.background.x),
                    green: Double(next.background.y),
                    blue: Double(next.background.z),
                    alpha: Double(next.background.w)
                )
        }

        guard let snapshot,
              let particleBuffer,
              !particles.isEmpty,
              let drawable = view.currentDrawable,
              let drawableDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let sampleCount = phonoscopeAASampleCount(supportsFourSamples: particleAAPipeline != nil)
        ensureRenderTargets(
            width: drawable.texture.width,
            height: drawable.texture.height,
            sampleCount: sampleCount
        )
        guard let hdrTexture, let bloomTextureA, let bloomTextureB else { return }
        let activeSampleCount = sampleCount == 4 && multisampleHDRTexture != nil ? 4 : 1

        var uniforms = PhonoscopeGPUUniforms(
            viewport: SIMD4(Float(view.drawableSize.width), Float(view.drawableSize.height), Float(renderScale), 0),
            boundsMin: SIMD4(snapshot.boundsMinimum.x, snapshot.boundsMinimum.y, snapshot.boundsMinimum.z, 0),
            boundsMax: SIMD4(snapshot.boundsMaximum.x, snapshot.boundsMaximum.y, snapshot.boundsMaximum.z, 0),
            signal: SIMD4(Float(snapshot.signal.time), Float(snapshot.signal.beatPulse), snapshot.is3D ? 1 : 0, Float(snapshot.signal.quality.rawValue))
        )

        let particlePass = MTLRenderPassDescriptor()
        if activeSampleCount == 4, let multisampleHDRTexture, particleAAPipeline != nil {
            particlePass.colorAttachments[0].texture = multisampleHDRTexture
            particlePass.colorAttachments[0].resolveTexture = hdrTexture
            particlePass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            particlePass.colorAttachments[0].texture = hdrTexture
            particlePass.colorAttachments[0].storeAction = .store
        }
        particlePass.colorAttachments[0].loadAction = .clear
        // Keep the emissive scene transparent so the background colour cannot
        // leak into bloom extraction. The composite pass adds it afterwards.
        particlePass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let particleEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: particlePass) else { return }
        particleEncoder.setRenderPipelineState(
            activeSampleCount == 4 ? (particleAAPipeline ?? particlePipeline) : particlePipeline
        )
        particleEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        particleEncoder.setVertexBytes(&uniforms, length: MemoryLayout<PhonoscopeGPUUniforms>.stride, index: 1)
        particleEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particles.count)
        particleEncoder.endEncoding()

        encodeFullscreenPass(
            commandBuffer: commandBuffer,
            pipeline: bloomExtractPipeline,
            source: hdrTexture,
            destination: bloomTextureA,
            uniforms: nil
        )
        let effectScale = max(1, Float(view.drawableSize.height) / 1_080)
        var horizontal = PhonoscopeBloomUniforms(
            texelStep: SIMD2(effectScale / Float(bloomTextureA.width), 0),
            intensity: 1
        )
        encodeFullscreenPass(
            commandBuffer: commandBuffer,
            pipeline: bloomBlurPipeline,
            source: bloomTextureA,
            destination: bloomTextureB,
            uniforms: &horizontal
        )
        var vertical = PhonoscopeBloomUniforms(
            texelStep: SIMD2(0, effectScale / Float(bloomTextureB.height)),
            intensity: 1
        )
        encodeFullscreenPass(
            commandBuffer: commandBuffer,
            pipeline: bloomBlurPipeline,
            source: bloomTextureB,
            destination: bloomTextureA,
            uniforms: &vertical
        )

        // With the overlay on, the composite lands in an offscreen frame the
        // glow pass can sample; with it off, it goes straight to the drawable
        // exactly as before.
        let overlay = glowOverlay
        let overlayActive = overlay.isActive && frameTexture != nil
            && glowTextureA != nil && glowTextureB != nil
        let compositeDescriptor: MTLRenderPassDescriptor
        if overlayActive, let frameTexture {
            compositeDescriptor = MTLRenderPassDescriptor()
            compositeDescriptor.colorAttachments[0].texture = frameTexture
            compositeDescriptor.colorAttachments[0].loadAction = .clear
            compositeDescriptor.colorAttachments[0].clearColor = view.clearColor
            compositeDescriptor.colorAttachments[0].storeAction = .store
        } else {
            compositeDescriptor = drawableDescriptor
        }
        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositeDescriptor) else { return }
        var compositeUniforms = PhonoscopeBloomUniforms(
            texelStep: .zero,
            intensity: 1.45,
            background: letterboxedBackground ? .zero : snapshot.background
        )
        compositeEncoder.setRenderPipelineState(
            overlayActive ? compositeToFramePipeline : compositePipeline
        )
        compositeEncoder.setFragmentTexture(hdrTexture, index: 0)
        compositeEncoder.setFragmentTexture(bloomTextureA, index: 1)
        compositeEncoder.setFragmentBytes(
            &compositeUniforms,
            length: MemoryLayout<PhonoscopeBloomUniforms>.stride,
            index: 0
        )
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.endEncoding()

        // The centre image goes over the finished composite and UNDER the glow
        // overlay, so it blooms with the rest of the picture exactly as the
        // message does. Same position in the draw order as `renderCentreImage`
        // in nova-visualiser's renderer.
        encodeCentreImagePass(
            commandBuffer: commandBuffer,
            // Whatever the composite just wrote into: the offscreen frame when
            // the glow overlay is going to read it back, the drawable when it
            // is not. Loaded rather than cleared, or this pass would erase the
            // picture it is supposed to sit on.
            target: overlayActive ? (frameTexture ?? drawable.texture) : drawable.texture
        )

        if overlayActive, let frameTexture, let glowTextureA, let glowTextureB {
            let sigma = overlay.blurSigmaTexels(outputHeight: Double(drawable.texture.height))
            var horizontal = PhonoscopeGlowUniforms(
                axisTexel: SIMD2(1 / Float(glowTextureA.width), 0),
                sigma: sigma
            )
            encodeGlowPass(
                commandBuffer: commandBuffer,
                pipeline: glowBlurPipeline,
                sources: [frameTexture],
                destination: glowTextureA,
                uniforms: &horizontal
            )
            var vertical = PhonoscopeGlowUniforms(
                axisTexel: SIMD2(0, 1 / Float(glowTextureB.height)),
                sigma: sigma
            )
            encodeGlowPass(
                commandBuffer: commandBuffer,
                pipeline: glowBlurPipeline,
                sources: [glowTextureA],
                destination: glowTextureB,
                uniforms: &vertical
            )
            var blend = PhonoscopeGlowUniforms(
                opacity: Float(min(max(overlay.opacity, 0), 100) / 100),
                overdrive: Float(min(max(overlay.overdrive, 1), 10)),
                glowClamped: overlay.clamped ? 1 : 0,
                blendMode: Int32(overlay.blendMode.rawValue)
            )
            encodeGlowPass(
                commandBuffer: commandBuffer,
                pipeline: glowOverlayPipeline,
                sources: [frameTexture, glowTextureB],
                destination: nil,
                descriptor: drawableDescriptor,
                uniforms: &blend
            )
        }

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self, weak view] _ in
            guard let self, let view else { return }
            let elapsed = CACurrentMediaTime() - started
            let completedAt = CACurrentMediaTime()
            DispatchQueue.main.async {
                self.adjustRenderScale(elapsed: elapsed, view: view)
                self.recordCompletedFrame(at: completedAt)
            }
        }
        commandBuffer.commit()
    }

    private func recordCompletedFrame(at timestamp: CFTimeInterval) {
        guard let startedAt = fpsWindowStartedAt else {
            fpsWindowStartedAt = timestamp
            completedFramesInWindow = 0
            return
        }
        completedFramesInWindow += 1
        let duration = timestamp - startedAt
        guard duration >= 0.75 else { return }
        onFPSUpdate?(Double(completedFramesInWindow) / duration)
        fpsWindowStartedAt = timestamp
        completedFramesInWindow = 0
    }

    /// The centre slot's image half, and whatever transition it is mid-way
    /// through.
    ///
    /// Nothing here decides anything: which two images, how far through, and
    /// which transition all arrive already resolved and latched from
    /// `PhonoscopeStore`, because the entry a change STARTS from owns the
    /// transition and only the store knows which entry that was.
    private func encodeCentreImagePass(commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        let state = centreImage
        guard state.isActive else { return }
        let to = state.to.flatMap { centreImageTexture($0) }
        let from = state.from.flatMap { centreImageTexture($0) }
        // A texture that has not finished downloading yet simply is not drawn.
        // The alternative is holding the whole picture back on a network fetch.
        guard to != nil || from != nil else { return }

        let frameAspect = target.height > 0
            ? Double(target.width) / Double(target.height)
            : 0
        func extent(_ texture: MTLTexture?) -> SIMD2<Float> {
            guard let texture, texture.height > 0 else { return .zero }
            return phonoscopeImageHalfExtentSIMD(
                frameAspect: frameAspect,
                imageAspect: Double(texture.width) / Double(texture.height),
                widthFraction: state.widthFraction,
                heightFraction: state.heightFraction,
                scale: state.scale,
                fit: state.fit,
                proportional: state.proportional)
        }

        var uniforms = PhonoscopeCentreImageUniforms(
            halfExtentTo: extent(to),
            halfExtentFrom: extent(from),
            progress: Float(min(max(state.progress, 0), 1)),
            frameAspect: Float(frameAspect),
            axisRadians: Float(state.params.axisRadians),
            segments: Int32(state.params.segments),
            mode: Int32(state.params.mode.rawValue),
            hasFrom: from != nil ? 1 : 0,
            returnFromOrigin: state.params.returnFromOrigin ? 1 : 0)

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(centreImagePipeline)
        // Both slots are always bound: the shader reads `imageFrom` only when
        // `hasFrom` says to, but an unbound slot is undefined behaviour rather
        // than a black texture, so the incoming image doubles for it.
        encoder.setFragmentTexture(to ?? from, index: 0)
        encoder.setFragmentTexture(from ?? to, index: 1)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<PhonoscopeCentreImageUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// The decoded texture for a centre image, starting a load on the first miss.
    ///
    /// Premultiplied at decode, matching the pipeline's source-one blending and
    /// the renderer's own decode — an unpremultiplied PNG would halo against
    /// the picture behind it wherever its alpha is partial.
    private func centreImageTexture(_ url: URL) -> MTLTexture? {
        if let cached = centreImageTextures[url] { return cached }
        guard !centreImageLoading.contains(url) else { return nil }
        centreImageLoading.insert(url)
        let device = self.device
        // Deliberately the callback API rather than async/await: `draw(in:)` and
        // the cache both live on the main thread, so hopping back with
        // `DispatchQueue.main.async` keeps every touch of the two dictionaries
        // on one thread without dragging the renderer into an actor.
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let texture = data.flatMap { Self.centreImageTexture(from: $0, device: device) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.centreImageLoading.remove(url)
                if let texture { self.centreImageTextures[url] = texture }
            }
        }.resume()
        return nil
    }

    private static func centreImageTexture(from data: Data, device: MTLDevice) -> MTLTexture? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            // Premultiplied, and BGRA to match the texture format below.
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow)
        }
        return texture
    }

    private func encodeFullscreenPass(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        source: MTLTexture,
        destination: MTLTexture,
        uniforms: UnsafeMutablePointer<PhonoscopeBloomUniforms>?
    ) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        if let uniforms {
            encoder.setFragmentBytes(
                uniforms,
                length: MemoryLayout<PhonoscopeBloomUniforms>.stride,
                index: 0
            )
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Fullscreen pass for the glow chain. Separate from `encodeFullscreenPass`
    /// only because it takes several source textures and its own uniform
    /// struct; the drawable's own descriptor can be passed for the final blend.
    private func encodeGlowPass(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        sources: [MTLTexture],
        destination: MTLTexture?,
        descriptor providedDescriptor: MTLRenderPassDescriptor? = nil,
        uniforms: UnsafeMutablePointer<PhonoscopeGlowUniforms>
    ) {
        let descriptor: MTLRenderPassDescriptor
        if let providedDescriptor {
            descriptor = providedDescriptor
        } else {
            guard let destination else { return }
            descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = destination
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        for (index, source) in sources.enumerated() {
            encoder.setFragmentTexture(source, index: index)
        }
        encoder.setFragmentBytes(
            uniforms,
            length: MemoryLayout<PhonoscopeGlowUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func ensureRenderTargets(width: Int, height: Int, sampleCount: Int) {
        let nextSize = MTLSize(width: width, height: height, depth: 1)
        let sizeChanged = nextSize.width != renderTargetSize.width
                || nextSize.height != renderTargetSize.height
                || nextSize.depth != renderTargetSize.depth
        let needsMultisampleTexture = sampleCount == 4 && multisampleHDRTexture == nil
        guard sizeChanged || needsMultisampleTexture else { return }
        renderTargetSize = nextSize

        func texture(width: Int, height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: max(1, width),
                height: max(1, height),
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            return device.makeTexture(descriptor: descriptor)
        }

        // The glow chain works in the drawable's display-referred format, not
        // the HDR scene format: blend modes are defined on display colour, and
        // matching the drawable keeps the final pass a straight copy of what
        // the composite would otherwise have presented.
        func displayTexture(width: Int, height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: max(1, width),
                height: max(1, height),
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            return device.makeTexture(descriptor: descriptor)
        }

        hdrTexture = texture(width: width, height: height)
        bloomTextureA = texture(width: width / 4, height: height / 4)
        bloomTextureB = texture(width: width / 4, height: height / 4)
        frameTexture = displayTexture(width: width, height: height)
        // Quarter resolution, matching `nova::kGlowBlurDownsample`. The sigma
        // both engines receive is in this target's texels, so the divisor is
        // part of the cross-engine contract, not a local cost decision.
        glowTextureA = displayTexture(width: width / 4, height: height / 4)
        glowTextureB = displayTexture(width: width / 4, height: height / 4)
        if sampleCount == 4 {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DMultisample
            descriptor.pixelFormat = .rgba16Float
            descriptor.width = max(1, width)
            descriptor.height = max(1, height)
            descriptor.sampleCount = 4
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget]
            multisampleHDRTexture = device.makeTexture(descriptor: descriptor)
        } else if sizeChanged {
            multisampleHDRTexture = nil
        }
    }

    private func ensureParticleCapacity(_ count: Int) {
        guard count > particleCapacity else { return }
        particleCapacity = max(count, max(1_024, particleCapacity * 2))
        particleBuffer = device.makeBuffer(
            length: particleCapacity * MemoryLayout<PhonoscopeGPUParticle>.stride,
            options: .storageModeShared
        )
    }

    private func adjustRenderScale(elapsed: Double, view: MTKView) {
        if elapsed > 0.018 {
            slowFrames += 1
            fastFrames = 0
        } else if elapsed < 0.013 {
            fastFrames += 1
            slowFrames = 0
        } else {
            slowFrames = 0
            fastFrames = 0
        }
        if slowFrames >= 30, renderScale > 0.65 {
            renderScale = max(0.65, renderScale - 0.1)
            slowFrames = 0
        } else if fastFrames >= 300, renderScale < 1 {
            renderScale = min(1, renderScale + 0.05)
            fastFrames = 0
        }
        let bounds = view.bounds.size
        let scale = UIScreen.main.scale * renderScale
        let next = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if abs(next.width - view.drawableSize.width) > 2 || abs(next.height - view.drawableSize.height) > 2 {
            view.drawableSize = next
        }
    }
}
