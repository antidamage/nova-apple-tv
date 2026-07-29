import MetalKit
import SwiftUI

private struct PhonoscopeGPUParticle {
    var positionSize: SIMD4<Float>
    var color: SIMD4<Float>
    var meta: SIMD4<Float>
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
}

struct MetalPhonoscopeView: UIViewRepresentable {
    let module: PhonoscopeModule?
    let signal: PhonoscopeSignalFrame
    let settings: [String: Double]
    let theme: DashboardTheme
    let letterboxedBackground: Bool

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
        context.coordinator.simulation.start()
        context.coordinator.simulation.update(
            module: module,
            signal: signal,
            settings: settings,
            palette: palette
        )
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.renderer?.letterboxedBackground = letterboxedBackground
        if let view = uiView as? MTKView {
            view.isOpaque = !letterboxedBackground
            view.backgroundColor = letterboxedBackground ? .clear : .black
        }
        context.coordinator.simulation.update(
            module: module,
            signal: signal,
            settings: settings,
            palette: palette
        )
    }

    private var palette: PhonoscopePalette {
        PhonoscopePalette(
            accent: theme.accent.vector,
            highlight: theme.highlight.vector,
            background: theme.background.vector
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: MetalPhonoscopeCoordinator) {
        coordinator.simulation.stop()
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
    private let bloomExtractPipeline: MTLRenderPipelineState
    private let bloomBlurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private var particleBuffer: MTLBuffer?
    private var particleCapacity = 0
    private var hdrTexture: MTLTexture?
    private var bloomTextureA: MTLTexture?
    private var bloomTextureB: MTLTexture?
    private var renderTargetSize = MTLSize()
    private var lastSerial: UInt64 = 0
    private var particles: [PhonoscopeGPUParticle] = []
    private var snapshot: PhonoscopeSceneSnapshot?
    private var slowFrames = 0
    private var fastFrames = 0
    private var renderScale: CGFloat = 1
    var letterboxedBackground = false

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
              let composite = library.makeFunction(name: "phonoscope_composite")
        else { return nil }
        commandQueue = queue

        let particleDescriptor = MTLRenderPipelineDescriptor()
        particleDescriptor.vertexFunction = vertex
        particleDescriptor.fragmentFunction = fragment
        particleDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        particleDescriptor.colorAttachments[0].isBlendingEnabled = true
        particleDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        particleDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        particleDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        particleDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

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
        do {
            particlePipeline = try device.makeRenderPipelineState(descriptor: particleDescriptor)
            bloomExtractPipeline = try device.makeRenderPipelineState(descriptor: extractDescriptor)
            bloomBlurPipeline = try device.makeRenderPipelineState(descriptor: blurDescriptor)
            compositePipeline = try device.makeRenderPipelineState(descriptor: compositeDescriptor)
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
                    meta: SIMD4($0.glow, $0.primitive, $0.material, 0)
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
                    alpha: 1
                )
        }

        guard let snapshot,
              let particleBuffer,
              !particles.isEmpty,
              let drawable = view.currentDrawable,
              let drawableDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        ensureRenderTargets(width: drawable.texture.width, height: drawable.texture.height)
        guard let hdrTexture, let bloomTextureA, let bloomTextureB else { return }

        var uniforms = PhonoscopeGPUUniforms(
            viewport: SIMD4(Float(view.drawableSize.width), Float(view.drawableSize.height), Float(renderScale), 0),
            boundsMin: SIMD4(snapshot.boundsMinimum.x, snapshot.boundsMinimum.y, snapshot.boundsMinimum.z, 0),
            boundsMax: SIMD4(snapshot.boundsMaximum.x, snapshot.boundsMaximum.y, snapshot.boundsMaximum.z, 0),
            signal: SIMD4(Float(snapshot.signal.time), Float(snapshot.signal.beatPulse), snapshot.is3D ? 1 : 0, Float(snapshot.signal.quality.rawValue))
        )

        let particlePass = MTLRenderPassDescriptor()
        particlePass.colorAttachments[0].texture = hdrTexture
        particlePass.colorAttachments[0].loadAction = .clear
        particlePass.colorAttachments[0].storeAction = .store
        particlePass.colorAttachments[0].clearColor = letterboxedBackground
            ? MTLClearColorMake(0, 0, 0, 0)
            : MTLClearColor(
                red: Double(snapshot.background.x),
                green: Double(snapshot.background.y),
                blue: Double(snapshot.background.z),
                alpha: 1
            )
        guard let particleEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: particlePass) else { return }
        particleEncoder.setRenderPipelineState(particlePipeline)
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
        var horizontal = PhonoscopeBloomUniforms(
            texelStep: SIMD2(1 / Float(bloomTextureA.width), 0),
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
            texelStep: SIMD2(0, 1 / Float(bloomTextureB.height)),
            intensity: 1
        )
        encodeFullscreenPass(
            commandBuffer: commandBuffer,
            pipeline: bloomBlurPipeline,
            source: bloomTextureB,
            destination: bloomTextureA,
            uniforms: &vertical
        )

        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: drawableDescriptor) else { return }
        var compositeUniforms = PhonoscopeBloomUniforms(texelStep: .zero, intensity: 1.45)
        compositeEncoder.setRenderPipelineState(compositePipeline)
        compositeEncoder.setFragmentTexture(hdrTexture, index: 0)
        compositeEncoder.setFragmentTexture(bloomTextureA, index: 1)
        compositeEncoder.setFragmentBytes(
            &compositeUniforms,
            length: MemoryLayout<PhonoscopeBloomUniforms>.stride,
            index: 0
        )
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self, weak view] _ in
            guard let self, let view else { return }
            let elapsed = CACurrentMediaTime() - started
            DispatchQueue.main.async { self.adjustRenderScale(elapsed: elapsed, view: view) }
        }
        commandBuffer.commit()
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

    private func ensureRenderTargets(width: Int, height: Int) {
        let nextSize = MTLSize(width: width, height: height, depth: 1)
        guard nextSize.width != renderTargetSize.width
                || nextSize.height != renderTargetSize.height
                || nextSize.depth != renderTargetSize.depth
        else { return }
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

        hdrTexture = texture(width: width, height: height)
        bloomTextureA = texture(width: width / 4, height: height / 4)
        bloomTextureB = texture(width: width / 4, height: height / 4)
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
