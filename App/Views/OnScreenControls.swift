import SwiftUI

/// Translucent Android navigation bar (back / home / recents) plus keyboard and
/// menu buttons. Collapses to a small pill; tap the pill to show it again.
struct OnScreenControls: View {
    let engine: AndroiOSEngine
    @Binding var showKeyboard: Bool
    @Binding var showMenu: Bool
    @State private var expanded = true

    var body: some View {
        VStack {
            Spacer()
            if expanded {
                HStack(spacing: 28) {
                    navButton("chevron.backward", .back)
                    navButton("circle", .home)
                    navButton("square", .recents)
                    Divider().frame(height: 22).overlay(Color.white.opacity(0.3))
                    Button { showKeyboard.toggle() } label: { Image(systemName: "keyboard") }
                    Button { showMenu = true } label: { Image(systemName: "ellipsis.circle") }
                    Button { withAnimation { expanded = false } } label: { Image(systemName: "chevron.down") }
                }
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(.ultraThinMaterial.opacity(0.85), in: Capsule())
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Capsule().fill(Color.white.opacity(0.5)).frame(width: 64, height: 6)
                    .padding(12).contentShape(Rectangle())
                    .onTapGesture { withAnimation { expanded = true } }
            }
        }
    }

    private func navButton(_ symbol: String, _ key: InputManager.NavKey) -> some View {
        Button { InputManager.shared.tap(key, engine: engine) } label: { Image(systemName: symbol) }
            .accessibilityLabel(String(describing: key))
    }
}

/// A hidden text field that brings up the iOS software keyboard and types into the guest.
struct GuestKeyboardField: UIViewRepresentable {
    let engine: AndroiOSEngine
    @Binding var active: Bool

    func makeUIView(context: Context) -> KeyField {
        let f = KeyField()
        f.engine = engine
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.smartQuotesType = .no
        f.smartDashesType = .no
        f.keyboardAppearance = .dark
        f.tintColor = .clear
        f.textColor = .clear
        return f
    }

    func updateUIView(_ f: KeyField, context: Context) {
        if active, !f.isFirstResponder { DispatchQueue.main.async { f.becomeFirstResponder() } }
        if !active, f.isFirstResponder { DispatchQueue.main.async { f.resignFirstResponder() } }
    }

    final class KeyField: UITextField {
        var engine: AndroiOSEngine?
        override func insertText(_ text: String) {
            guard let engine else { return }
            if text == "\n" { engine.key(28, down: true); engine.key(28, down: false); return }  // KEY_ENTER
            InputManager.shared.type(text, engine: engine)
        }
        override func deleteBackward() { engine?.key(14, down: true); engine?.key(14, down: false) }    // KEY_BACKSPACE
        override var hasText: Bool { true }   // keep backspace enabled
    }
}
