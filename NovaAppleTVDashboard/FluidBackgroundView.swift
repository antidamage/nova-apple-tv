import MetalKit
import QuartzCore
import SwiftUI
import UIKit

struct FluidBackgroundView: UIViewRepresentable {
    let theme: DashboardTheme
    var baseURL: URL = AppConfig.dashboardBaseURL
    var blobScale: Float = 1
    var blobSoftness: Float = 1
    var allowsDisplacementTexture: Bool = true

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
        let view = MTKView(frame: .zero, device: device)
        view.backgroundColor = UIColor(theme.background.color)
        view.clearColor = theme.clearColor
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = true
        view.preferredFramesPerSecond = 30
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
        if let view = uiView as? MTKView {
            view.backgroundColor = UIColor(theme.background.color)
            view.clearColor = theme.clearColor
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
    private let startTime = CACurrentMediaTime()
    var theme = DashboardTheme.default
    var baseURL: URL = AppConfig.dashboardBaseURL
    var blobScale: Float = 1
    var blobSoftness: Float = 1
    var allowsDisplacementTexture = true

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

    func draw(in view: MTKView) {
        updateMosaicTextureIfNeeded()

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        let scale = Float(view.contentScaleFactor > 0 ? view.contentScaleFactor : 1)
        let uiScaleMultiplier = Self.targetDPR / scale

        var uniforms = FluidBackgroundUniforms(
            time: Float(CACurrentMediaTime() - startTime),
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
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
            blobSoftness: blobSoftness
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
