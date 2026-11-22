import SwiftUI

/// Serial console (boot log + shell on ttyAMA0).
struct ConsoleView: View {
    @ObservedObject var engine: AndroiOSEngine
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(engine.console.isEmpty ? "Waiting for serial output…" : engine.console)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(engine.console.isEmpty ? .gray : .green)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(8)
                }
                .onChange(of: engine.console) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            HStack {
                TextField("command, ⏎ to send", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { engine.sendConsole(input + "\r"); input = "" }
                Button("^C") { engine.sendConsole("\u{03}") }
            }
            .padding(8)
            .background(Color(white: 0.12))
            .disabled(engine.state != .running)
        }
        .background(Color.black)
    }
}
