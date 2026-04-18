import SwiftUI

struct ContentView: View {
    @StateObject private var engine = CactusEngine()
    @State private var prompt: String = "What is the capital of France?"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                statusBanner

                TextField("Ask Gemma…", text: $prompt, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(engine.isGenerating)

                Button(action: send) {
                    HStack {
                        if engine.isGenerating { ProgressView().tint(.white) }
                        Text(engine.isGenerating ? "Generating…" : "Send")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isSendable ? Color.accentColor : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!isSendable)

                ScrollView {
                    Text(engine.partial.isEmpty ? "Response will appear here." : engine.partial)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .textSelection(.enabled)
                }
            }
            .padding()
            .navigationTitle("GemmaMVP")
            .task { await engine.loadIfNeeded() }
        }
    }

    private var isSendable: Bool {
        if case .ready = engine.loadState, !engine.isGenerating,
           !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    private func send() {
        Task { await engine.generate(prompt: prompt) }
    }

    @ViewBuilder private var statusBanner: some View {
        switch engine.loadState {
        case .idle:
            Label("Idle", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .loading:
            Label("Loading model…", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .ready:
            Label("Model ready (on-device)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }
}

#Preview { ContentView() }
