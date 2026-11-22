import SwiftUI
import MetalKit

/// The Android display: an MTKView sampling the guest's IOSurface, with full
/// multitouch (10 points) and hardware-keyboard forwarding.
struct VMDisplayView: UIViewRepresentable {
    let engine: AndroiOSEngine
    var preferredFPS: Int
    @Binding var hostFPS: Double

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, hostFPS: $hostFPS) }

    func makeUIView(context: Context) -> GuestMTKView {
        let view = GuestMTKView(frame: .zero, device: nil)
        let renderer = MetalRenderer(frames: engine.frames)
        view.device = renderer?.device
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = preferredFPS
        view.enableSetNeedsDisplay = false      // continuous rendering
        view.isPaused = false
        view.isMultipleTouchEnabled = true
        view.isUserInteractionEnabled = true
        view.backgroundColor = .black
        view.coordinator = context.coordinator
        context.coordinator.renderer = renderer
        context.coordinator.startFPSCounter()
        return view
    }

    func updateUIView(_ view: GuestMTKView, context: Context) {
        if view.preferredFramesPerSecond != preferredFPS { view.preferredFramesPerSecond = preferredFPS }
    }

    static func dismantleUIView(_ view: GuestMTKView, coordinator: Coordinator) { coordinator.stopFPSCounter() }

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
                self.hostFPS = Double(r.drawnFrames - self.lastDrawn)
                self.lastDrawn = r.drawnFrames
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

final class GuestMTKView: MTKView {
    weak var coordinator: VMDisplayView.Coordinator?

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
