import Metal
import MetalKit
import IOSurface

/// Draws the latest guest frame. The IOSurface is wrapped as an MTLTexture
/// without copying; ANGLE (same GPU) or the 2D path wrote into it.
final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let frames: FrameStore

    private var texture: MTLTexture?
    private var textureSurface: IOSurfaceRef?
    private(set) var drawnFrames: UInt64 = 0
    private var lastSeq: UInt64 = 0
    /// Rect (in view points) the guest image occupies; used to map touches.
    private(set) var contentRect: CGRect = .zero

    init?(frames: FrameStore) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary() else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "guest_vertex")
        desc.fragmentFunction = lib.makeFunction(name: "guest_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.frames = frames
    }

    private func texture(for surface: IOSurfaceRef) -> MTLTexture? {
        if let texture, textureSurface === surface { return texture }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: IOSurfaceGetWidth(surface),
                                                         height: IOSurfaceGetHeight(surface),
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        texture = device.makeTexture(descriptor: d, iosurface: surface, plane: 0)
        textureSurface = surface
        return texture
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let (surface, seq) = frames.latest(), let tex = texture(for: surface) {
            // Aspect-fit the guest into the drawable.
            let dw = Float(view.drawableSize.width), dh = Float(view.drawableSize.height)
            let gw = Float(tex.width), gh = Float(tex.height)
            let scale = min(dw / gw, dh / gh)
            let w = gw * scale, h = gh * scale
            var vp = (origin: SIMD2<Float>(-w / dw, h / dh), size: SIMD2<Float>(2 * w / dw, 2 * h / dh))
            let s = view.contentScaleFactor
            contentRect = CGRect(x: CGFloat((dw - w) / 2) / s, y: CGFloat((dh - h) / 2) / s,
                                 width: CGFloat(w) / s, height: CGFloat(h) / s)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&vp, length: MemoryLayout.size(ofValue: vp), index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            if seq != lastSeq { lastSeq = seq; drawnFrames += 1 }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Converts a point in the MTKView to guest display pixels, or nil if outside the image.
    func guestPoint(_ p: CGPoint, guestSize: (Int, Int)) -> (Int, Int)? {
        guard contentRect.width > 0, contentRect.contains(p), guestSize.0 > 0 else { return nil }
        let x = (p.x - contentRect.minX) / contentRect.width * CGFloat(guestSize.0)
        let y = (p.y - contentRect.minY) / contentRect.height * CGFloat(guestSize.1)
        return (Int(x), Int(y))
    }
}
