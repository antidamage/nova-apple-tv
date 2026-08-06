import MetalKit
import QuartzCore
import SwiftUI
import UIKit

/// The centred backdrop band and the vignette framing it.
///
/// This used to be a SwiftUI `.frame(height: geometry.size.height / 3)` with a
/// `PhonoscopeEdgeVignette` overlay. Height, width, vignette opacity and
/// vignette size are all driven parameters now, and a driven value changes
/// every frame — re-running SwiftUI layout at 60 Hz is the wrong mechanism, so
/// the band is resolved in the fragment shader instead. That is also what
/// `nova-visualiser/src/shaders/fluid_background.frag` does, which retires a
/// long-standing divergence between the two engines.
struct FluidBackgroundBand: Equatable {
    /// Whether this surface is banded at all. Separate from `heightFraction`
    /// rather than inferred from it: a height driven to zero is a band closed
    /// down to nothing, which fills the frame with vignette colour, and that is
    /// a different picture from a surface that has no band in the first place.
    var isEnabled: Bool
    var heightFraction: Float
    var widthFraction: Float
    var vignetteColor: SIMD4<Float>
    var vignetteOpacity: Float
    var vignetteSize: Float

    /// No band: the whole drawable is field, unclipped and unvignetted.
    static let none = FluidBackgroundBand(
        isEnabled: false, heightFraction: 1, widthFraction: 1,
        vignetteColor: SIMD4<Float>(0, 0, 0, 1), vignetteOpacity: 0.96, vignetteSize: 1)
}

struct FluidBackgroundView: UIViewRepresentable {
    let theme: DashboardTheme
    var baseURL: URL = AppConfig.dashboardBaseURL
    var blobScale: Float = 1
    var blobSoftness: Float = 1
    var allowsDisplacementTexture: Bool = true
    var animationSpeed: Float = 1
    var renderScale: CGFloat = 1
    /// Band geometry and vignette, for the Phonoscope surface. Defaults to no
    /// band at all, which is what the dashboard background wants.
    var band: FluidBackgroundBand = .none

    func makeCoordinator() -> FluidBackgroundCoordinator {
        FluidBackgroundCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        guard let device = context.coordinator.device,
              let renderer = context.coordinator.renderer
        else {
            let view = UIView()
            view.backgroundColor = UIColor(theme.background.color)
            return view
        }

        renderer.baseURL = baseURL
        renderer.theme = theme
        renderer.blobScale = blobScale
        renderer.blobSoftness = blobSoftness
        renderer.allowsDisplacementTexture = allowsDisplacementTexture
        renderer.animationSpeed = animationSpeed
        renderer.band = band
        let view = FluidBackgroundMTKView(frame: .zero, device: device)
        view.renderScale = renderScale
        view.backgroundColor = UIColor(theme.background.color)
        view.clearColor = theme.clearColor
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = true
        view.preferredFramesPerSecond = fluidBackgroundFrameRate
        view.layer.magnificationFilter = .linear
        view.layer.minificationFilter = .linear
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = renderer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.renderer?.baseURL = baseURL
        context.coordinator.renderer?.theme = theme
        context.coordinator.renderer?.blobScale = blobScale
        context.coordinator.renderer?.blobSoftness = blobSoftness
        context.coordinator.renderer?.allowsDisplacementTexture = allowsDisplacementTexture
        context.coordinator.renderer?.animationSpeed = animationSpeed
        context.coordinator.renderer?.band = band
        if let view = uiView as? MTKView {
            view.backgroundColor = UIColor(theme.background.color)
            view.clearColor = theme.clearColor
            view.preferredFramesPerSecond = fluidBackgroundFrameRate
        }
        if let view = uiView as? FluidBackgroundMTKView {
            view.renderScale = renderScale
        }
    }
}

// The fluid background is deliberately fixed rather than configurable. Its
// refresh rate made no measurable difference to the visualiser's frame rate, so
// every surface renders it at the highest rate the design ever used.
let fluidBackgroundFrameRate = 60

func fluidDrawableSize(bounds: CGSize, nativeScale: CGFloat, renderScale: CGFloat) -> CGSize {
    let scale = max(0.125, min(1, renderScale)) * max(1, nativeScale)
    return CGSize(
        width: max(1, (bounds.width * scale).rounded()),
        height: max(1, (bounds.height * scale).rounded())
    )
}

final class FluidBackgroundMTKView: MTKView {
    var renderScale: CGFloat = 1 {
        didSet { updateDrawableSize() }
    }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        autoResizeDrawable = false
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        autoResizeDrawable = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let next = fluidDrawableSize(
            bounds: bounds.size,
            nativeScale: contentScaleFactor,
            renderScale: renderScale
        )
        if abs(next.width - drawableSize.width) > 1 || abs(next.height - drawableSize.height) > 1 {
            drawableSize = next
        }
    }
}

final class FluidBackgroundCoordinator {
    let device: MTLDevice?
    let renderer: FluidBackgroundRenderer?

    init() {
        let metalDevice = MTLCreateSystemDefaultDevice()
        device = metalDevice
        renderer = metalDevice.flatMap { FluidBackgroundRenderer(device: $0) }
    }
}

struct FluidBackgroundUniforms {
    var time: Float
    var resolution: SIMD2<Float>
    var background: SIMD4<Float>
    var accent: SIMD4<Float>
    var highlight: SIMD4<Float>
    var peakIntensity: Float
    var falloffPower: Float
    var warpAmplitude: Float
    var hueSpread: Float
    var apexGlow: Float
    var textureScale: Float
    var uiScaleMultiplier: Float
    var hasMosaicTexture: Float
    var blobScale: Float
    var blobSoftness: Float
    // Band geometry. Field order and the float4 placement must match
    // FluidBackgroundUniforms in FluidBackgroundShader.metal exactly: the
    // float4 lands on a 16-byte boundary only because the two Floats above it
    // do, which is why there is a trailing pad at all.
    var bandFraction: Float = 1
    var bandWidthFraction: Float = 1
    var vignetteColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    var vignetteOpacity: Float = 0.96
    var vignetteSize: Float = 1
    /// 1 when this surface is banded. A height of zero is a band closed to
    /// nothing, not the absence of one, so the flag cannot be inferred.
    var bandEnabled: Float = 0
    var padding: Float = 0
}

final class FluidBackgroundRenderer: NSObject, MTKViewDelegate {
    // Reference device pixel ratio the texture scale is authored against (iOS
    // Retina). Normalizing to this keeps the mosaic texture at the same apparent
    // scale as the web dashboard regardless of the screen's pixel density.
    private static let targetDPR: Float = 2.0

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let textureLoader: MTKTextureLoader
    // The shader is driven by an *accumulated* phase, not `elapsed * speed`.
    // Multiplying a running clock by a live speed makes the phase jump every
    // time the speed moves -- and `fluid_speed` is a driven/chased setting, so
    // it moves every frame. That is the "jolting all over" symptom. Integrating
    // `dt * speed` keeps the motion continuous through any speed change, and a
    // speed of 0 simply holds the current phase instead of resetting it.
    private var phase: Double = 0
    private var lastTick: CFTimeInterval?
    var theme = DashboardTheme.default
    var baseURL: URL = AppConfig.dashboardBaseURL
    var blobScale: Float = 1
    var blobSoftness: Float = 1
    var allowsDisplacementTexture = true
    var animationSpeed: Float = 1
    var band: FluidBackgroundBand = .none

    private var mosaicTexture: MTLTexture?
    private var loadedTextureKey: String?
    private var textureLoadGeneration = 0

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "fluidBackgroundVertex"),
              let fragmentFunction = library.makeFunction(name: "fluidBackgroundFragment")
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }

        self.commandQueue = commandQueue
        self.textureLoader = MTKTextureLoader(device: device)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func advancePhase() {
        let now = CACurrentMediaTime()
        defer { lastTick = now }
        guard let lastTick else { return }
        // Clamp the step so a stall (backgrounding, a long texture decode) can
        // never launch the field forward by seconds in a single frame.
        let delta = min(0.25, max(0, now - lastTick))
        phase += delta * Double(max(0, animationSpeed))
    }

    func draw(in view: MTKView) {
        updateMosaicTextureIfNeeded()
        advancePhase()

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        let scale = Float(view.contentScaleFactor > 0 ? view.contentScaleFactor : 1)
        let uiScaleMultiplier = Self.targetDPR / scale

        // The band's own pixel size, not the drawable's. That is what sets the
        // blob field's aspect and the grain frequency, and it is what the view
        // used to be physically sized to before the band moved into the shader.
        // Using the full drawable here would stretch the field sideways the
        // moment the band stopped being full-height.
        let bandPixels = SIMD2(
            Float(view.drawableSize.width) * (band.isEnabled ? max(band.widthFraction, 0.0001) : 1),
            Float(view.drawableSize.height) * (band.isEnabled ? max(band.heightFraction, 0.0001) : 1)
        )
        var uniforms = FluidBackgroundUniforms(
            time: Float(phase),
            resolution: bandPixels,
            background: theme.background.vector,
            accent: theme.accent.vector,
            highlight: theme.highlight.vector,
            peakIntensity: Float(theme.backgroundEffect.peakIntensity / 100),
            falloffPower: Float(theme.backgroundEffect.falloffPower / 100),
            warpAmplitude: Float(theme.backgroundEffect.warpAmplitude / 100),
            hueSpread: Float(theme.backgroundEffect.hueSpread / 100),
            apexGlow: Float(theme.backgroundEffect.apexGlow / 100),
            textureScale: Float(theme.backgroundEffect.textureScale / 100),
            uiScaleMultiplier: uiScaleMultiplier,
            hasMosaicTexture: mosaicTexture == nil ? 0 : 1,
            blobScale: blobScale,
            blobSoftness: blobSoftness,
            bandFraction: band.heightFraction,
            bandWidthFraction: band.widthFraction,
            vignetteColor: band.vignetteColor,
            vignetteOpacity: band.vignetteOpacity,
            vignetteSize: band.vignetteSize,
            bandEnabled: band.isEnabled ? 1 : 0
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FluidBackgroundUniforms>.stride, index: 0)
        encoder.setFragmentTexture(mosaicTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // Loads the mosaic texture referenced by the shared theme. The URL may be
    // absolute (http/https) or relative to the dashboard host; relative URLs are
    // resolved against `baseURL`. Reloads only when the URL changes.
    private func updateMosaicTextureIfNeeded() {
        guard allowsDisplacementTexture else {
            loadedTextureKey = nil
            mosaicTexture = nil
            return
        }
        let key = theme.backgroundEffect.textureURL ?? ""
        guard key != loadedTextureKey else { return }
        loadedTextureKey = key
        textureLoadGeneration += 1

        guard let urlString = theme.backgroundEffect.textureURL,
              let url = resolvedTextureURL(urlString) else {
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

    private func resolvedTextureURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }
}

private extension DashboardTheme {
    var clearColor: MTLClearColor {
        MTLClearColor(
            red: background.red / 255,
            green: background.green / 255,
            blue: background.blue / 255,
            alpha: 1
        )
    }
}
