import AVFAudio

/// Plays guest audio (virtio-sound → QEMU "ios" audiodev → engine ring buffer)
/// through AVAudioEngine. The render block pulls from the lock-free C ring.
final class AudioBridge {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredIOBufferDuration(512.0 / 48000.0)   // ~10 ms
        try? session.setActive(true)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            _ = aios_audio_read(l, r, Int32(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        try? engine.start()
    }

    func stop() {
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
