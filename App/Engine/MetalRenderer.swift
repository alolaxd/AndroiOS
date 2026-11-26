import Metal
import QuartzCore
import IOSurface

/// Draws guest frames into a CAMetalLayer on a dedicated render thread, never
/// the main thread, so SwiftUI work can't make the display miss frames.
///
/// - QEMU rotates frames through 3 IOSurfaces; each is wrapped once as an
///   MTLTexture (no copies).
/// - Frame `seq` is complete when the engine's MTLSharedEvent reaches `seq`.
///   ANGLE signals it on the GPU, and this command buffer waits for it on the
///   GPU, so no thread blocks on the other.
/// - A CADisplayLink on the render thread checks for a new frame on every screen
///   refresh (up to 120 Hz) and draws only when there is one.
final class MetalRenderer: NSObject {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let frames: FrameStore
    private let syncEvent: MTLSharedEvent?

    private weak var layer: CAMetalLayer?
    private var thread: Thread?
    private var link: CADisplayLink?

    // Render-thread state.
    private var textures: [UnsafeMutableRawPointer: MTLTexture] = [:]
    private var textureSize = (0, 0)
    private var lastSeq: UInt64 = 0

    // Shared with the main thread.
    private let lock = NSLock()
    private var _drawableSize = CGSize.zero
    private var _scale: CGFloat = 1
    private var _needsRedraw = true
    private var _contentRect = CGRect.zero
    private var _drawnFrames: UInt64 = 0
    private var _maxFPS = 60

    /// Rect (in view points) the guest image occupies; used to map touches.
    var contentRect: CGRect { lock.lock(); defer { lock.unlock() }; return _contentRect }
    var drawnFrames: UInt64 { lock.lock(); defer { lock.unlock() }; return _drawnFrames }

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
        if let p = aios_display_sync_event() {
            syncEvent = Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? MTLSharedEvent
        } else {
            syncEvent = nil
        }
    }

    // MARK: main thread

    func attach(to layer: CAMetalLayer, maxFPS: Int) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // Two drawables: a new guest frame reaches the screen one refresh sooner
        // than with the default three.
        layer.maximumDrawableCount = 2
        layer.presentsWithTransaction = false
        self.layer = layer
        setMaxFPS(maxFPS)
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "AndroiOS display"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        guard let thread else { return }
        perform(#selector(invalidateLink), on: thread, with: nil, waitUntilDone: false)
        self.thread = nil
    }

    func resize(drawableSize: CGSize, scale: CGFloat) {
        lock.lock(); _drawableSize = drawableSize; _scale = scale; _needsRedraw = true; lock.unlock()
    }

    func setMaxFPS(_ fps: Int) {
        lock.lock(); _maxFPS = fps; lock.unlock()
        if let thread { perform(#selector(applyFrameRate), on: thread, with: nil, waitUntilDone: false) }
    }

    /// Converts a point in the view to guest display pixels, or nil if outside the image.
    func guestPoint(_ p: CGPoint, guestSize: (Int, Int)) -> (Int, Int)? {
        let r = contentRect
        guard r.width > 0, r.contains(p), guestSize.0 > 0 else { return nil }
        let x = (p.x - r.minX) / r.width * CGFloat(guestSize.0)
        let y = (p.y - r.minY) / r.height * CGFloat(guestSize.1)
        return (Int(x), Int(y))
    }

    // MARK: render thread

    private func runLoop() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        applyFrameRate()
        link.add(to: .current, forMode: .default)
        // Runs until stop() invalidates the link on this thread.
        while self.link != nil {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
    }

    @objc private func invalidateLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func applyFrameRate() {
        lock.lock(); let fps = _maxFPS; lock.unlock()
        guard let link else { return }
        if #available(iOS 15.0, *) {
            let f = Float(fps)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, f), maximum: f, preferred: f)
        } else {
            link.preferredFramesPerSecond = fps
        }
    }

    @objc private func tick() {
        autoreleasepool { render() }
    }

    private func texture(for surface: IOSurfaceRef) -> MTLTexture? {
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        if textureSize != (w, h) { textures.removeAll(); textureSize = (w, h) }   // new resolution
        let key = Unmanaged.passUnretained(surface).toOpaque()
        if let t = textures[key] { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        let t = device.makeTexture(descriptor: d, iosurface: surface, plane: 0)
        if textures.count >= 6 { textures.removeAll() }
        textures[key] = t
        return t
    }

    private func render() {
        guard let layer else { return }
        lock.lock()
        let size = _drawableSize, scale = _scale, redraw = _needsRedraw
        lock.unlock()
        guard size.width > 0, size.height > 0 else { return }

        // Nothing new from the guest: skip (no drawable, no GPU work).
        let latest = frames.latest()
        if let (_, seq) = latest, seq == lastSeq, !redraw { return }
        if latest == nil, !redraw { return }

        // drawableSize is set on the main thread (GuestMetalView.layoutSubviews);
        // fit to whatever size this drawable actually has.
        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else { return }
        lock.lock(); _needsRedraw = false; lock.unlock()

        // Wait (on the GPU) until ANGLE has finished writing this frame.
        if let (_, seq) = latest, let ev = syncEvent, ev.signaledValue < seq {
            cmd.encodeWaitForEvent(ev, value: seq)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let (surface, seq) = latest, let tex = texture(for: surface) {
            // Aspect-fit the guest into the drawable.
            let dw = Float(drawable.texture.width), dh = Float(drawable.texture.height)
            let gw = Float(tex.width), gh = Float(tex.height)
            let fit = min(dw / gw, dh / gh)
            let w = gw * fit, h = gh * fit
            var vp = (origin: SIMD2<Float>(-w / dw, h / dh), size: SIMD2<Float>(2 * w / dw, 2 * h / dh))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&vp, length: MemoryLayout.size(ofValue: vp), index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            let rect = CGRect(x: CGFloat((dw - w) / 2) / scale, y: CGFloat((dh - h) / 2) / scale,
                              width: CGFloat(w) / scale, height: CGFloat(h) / scale)
            lock.lock()
            _contentRect = rect
            if seq != lastSeq { _drawnFrames += 1 }
            lock.unlock()
            lastSeq = seq
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
