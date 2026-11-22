import UIKit

/// Maps iOS input to Linux evdev events for the guest (virtio-multitouch-pci,
/// virtio-keyboard-pci). Key tables come from Resources/Keyboard/keymaps.json.
final class InputManager {
    static let shared = InputManager()

    /// Linux keycodes Android understands for navigation (Generic.kl).
    enum NavKey: Int { case back = 158, home = 172, recents = 580, volumeUp = 115, volumeDown = 114, power = 116 }

    private struct Keymaps: Decodable {
        let characters: [String: [Int]]      // "a": [30, 0] (keycode, shift)
        let hidToLinux: [String: Int]        // HID usage (decimal) → Linux keycode
    }

    private let chars: [Character: (Int, Bool)]
    private let hid: [Int: Int]
    static let keyShift = 42

    private init() {
        let url = Bundle.main.url(forResource: "keymaps", withExtension: "json")
        let maps = url.flatMap { try? JSONDecoder().decode(Keymaps.self, from: Data(contentsOf: $0)) }
        var c: [Character: (Int, Bool)] = [:]
        for (k, v) in maps?.characters ?? [:] where v.count == 2 { if let ch = k.first { c[ch] = (v[0], v[1] != 0) } }
        chars = c
        hid = Dictionary(uniqueKeysWithValues: (maps?.hidToLinux ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } })
    }

    func linuxKey(for character: Character) -> (code: Int, shift: Bool)? { chars[character].map { ($0.0, $0.1) } }
    func linuxKey(forHID usage: Int) -> Int? { hid[usage] }

    /// Types a string from the iOS software keyboard.
    func type(_ text: String, engine: AndroiOSEngine) {
        for ch in text {
            guard let (code, shift) = linuxKey(for: ch) else { continue }
            if shift { engine.key(Self.keyShift, down: true) }
            engine.key(code, down: true)
            engine.key(code, down: false)
            if shift { engine.key(Self.keyShift, down: false) }
        }
    }

    func tap(_ key: NavKey, engine: AndroiOSEngine) {
        engine.key(key.rawValue, down: true)
        engine.key(key.rawValue, down: false)
    }
}

/// Tracks UITouch → multitouch slot (0-9; Android supports 10 points).
final class TouchSlots {
    private var slots: [ObjectIdentifier: Int] = [:]

    func begin(_ t: UITouch) -> Int? {
        let used = Set(slots.values)
        guard let free = (0..<10).first(where: { !used.contains($0) }) else { return nil }
        slots[ObjectIdentifier(t)] = free
        return free
    }
    func slot(_ t: UITouch) -> Int? { slots[ObjectIdentifier(t)] }
    func end(_ t: UITouch) -> Int? { slots.removeValue(forKey: ObjectIdentifier(t)) }
    func reset() { slots.removeAll() }
}
