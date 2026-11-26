import SwiftUI
import QuartzCore

/// The Android display: a CAMetalLayer that MetalRenderer draws into from its
/// own thread, with full multitouch (10 points) and hardware-keyboard forwarding.
struct VMDisplayView: UIViewRepresentable {
    let engine: AndroiOSEngine
    var preferredFPS: Int
    @Binding var hostFPS: Double

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, hostFPS: $hostFPS) }

    func makeUIView(context: Context) -> GuestMetalView {
        let view = GuestMetalView(frame: .zero)
        view.isMultipleTouchEnabled = true
        view.isUserInteractionEnabled = true
        view.backgroundColor = .black
        view.coordinator = context.coordinator
        if let renderer = MetalRenderer(frames: engine.frames) {
            renderer.attach(to: view.metalLayer, maxFPS: Self.pollRate(preferredFPS))
            view.renderer = renderer
            context.coordinator.renderer = renderer
        }
        context.coordinator.startFPSCounter()
        return view
    }

    func updateUIView(_ view: GuestMetalView, context: Context) {
        context.coordinator.renderer?.setMaxFPS(Self.pollRate(preferredFPS))
    }

    static func dismantleUIView(_ view: GuestMetalView, coordinator: Coordinator) {
        coordinator.stopFPSCounter()
        coordinator.renderer?.stop()
    }

    /// The renderer checks for a new guest frame on every display refresh, up to
    /// the screen's maximum (120 Hz on ProMotion), so a frame waits at most ~8 ms
    /// to be shown. Refreshes without a new frame cost nothing.
    static func pollRate(_ preferred: Int) -> Int {
        preferred < 60 ? preferred : max(preferred, UIScreen.main.maximumFramesPerSecond)
    }

    final class Coordinator {
        let engine: AndroiOSEngine
        var renderer: MetalRenderer?
        let slots = TouchSlots()
        @Binding var hostFPS: Double
        private var timer: Timer?
        private var lastDrawn: UInt64 = 0

        init(engine: AndroiOSEngine, hostFPS: Binding<Double>) { self.engine = engine; _hostFPS = hostFPS }

        func startFPSCounter() {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let r = self.renderer else { return }
                let drawn = r.drawnFrames
                self.hostFPS = Double(drawn - self.lastDrawn)
                self.lastDrawn = drawn
            }
        }
        func stopFPSCounter() { timer?.invalidate() }

        func handle(_ touches: Set<UITouch>, in view: UIView, phase: Int) {
            guard let renderer else { return }
            let size = engine.frames.size
            for t in touches {
                let slot: Int?
                switch phase {
                case AIOS_TOUCH_DOWN: slot = slots.begin(t)
                case AIOS_TOUCH_UP, AIOS_TOUCH_CANCEL: slot = slots.end(t)
                default: slot = slots.slot(t)
                }
                guard let slot else { continue }
                let p = t.location(in: view)
                if let (x, y) = renderer.guestPoint(p, guestSize: size) {
                    engine.touch(slot: slot, x: x, y: y, action: Int32(phase))
                } else if phase == AIOS_TOUCH_UP || phase == AIOS_TOUCH_CANCEL {
                    engine.touch(slot: slot, x: 0, y: 0, action: Int32(phase))
                }
            }
        }
    }
}

final class GuestMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    weak var coordinator: VMDisplayView.Coordinator?
    var renderer: MetalRenderer?

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        renderer?.resize(drawableSize: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                         scale: scale)
    }

    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) { coordinator?.handle(t, in: self, phase: AIOS_TOUCH_DOWN) }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { coordinator?.handle(t, in: self, phase: AIOS_TOUCH_MOVE) }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { coordinator?.handle(t, in: self, phase: AIOS_TOUCH_UP) }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { coordinator?.handle(t, in: self, phase: AIOS_TOUCH_CANCEL) }

    // Hardware keyboard → Linux keycodes (HID usage table in keymaps.json).
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() { super.didMoveToWindow(); becomeFirstResponder() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: true) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    private func forward(_ presses: Set<UIPress>, down: Bool) -> Bool {
        guard let engine = coordinator?.engine else { return false }
        var handled = false
        for p in presses {
            guard let key = p.key, let code = InputManager.shared.linuxKey(forHID: key.keyCode.rawValue) else { continue }
            engine.key(code, down: down)
            handled = true
        }
        return handled
    }
}
