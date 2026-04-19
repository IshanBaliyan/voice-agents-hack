import SwiftUI

private enum TrainingPalette {
    static let accent = Color(red: 0.114, green: 0.725, blue: 0.329)
    static let danger = Color(red: 0.95, green: 0.3, blue: 0.3)
    static let overlay = Color.black.opacity(0.55)
}

struct TrainingSessionView: View {
    let course: TrainingCourse

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: InferenceController
    @StateObject private var speaker = StreamingSpeaker()

    private let arController = EngineARView.Controller()

    @State private var latestResponse: String = ""
    @State private var showResponse: Bool = false
    @State private var captureError: String?

    var body: some View {
        ZStack {
            EngineARView(scenario: course.scenario, controller: arController)
                .ignoresSafeArea()
                .onAppear { EngineARSystems.registerOnce() }

            VStack {
                topBar
                Spacer()
                if showResponse {
                    responseCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                shutterRow
                    .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
        .task { await engine.loadIfNeeded() }
        .onChange(of: engine.partial) { oldValue, newValue in
            guard newValue.hasPrefix(oldValue) else {
                speaker.reset()
                return
            }
            let delta = String(newValue.dropFirst(oldValue.count))
            if !delta.isEmpty { speaker.append(delta) }
            latestResponse = newValue
            if !showResponse && !newValue.isEmpty {
                withAnimation(.easeOut(duration: 0.2)) { showResponse = true }
            }
        }
        .onChange(of: engine.isGenerating) { _, generating in
            if !generating { speaker.finish() }
        }
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack {
            Button {
                speaker.reset()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(TrainingPalette.overlay)
                    .clipShape(Circle())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(course.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(TrainingPalette.overlay)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var responseCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(TrainingPalette.accent)
                .padding(.top, 2)
            Text(latestResponse.isEmpty ? "…" : latestResponse)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    showResponse = false
                    latestResponse = ""
                }
                speaker.reset()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var shutterRow: some View {
        VStack(spacing: 6) {
            Button(action: capture) {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    Circle()
                        .fill(engine.isGenerating ? TrainingPalette.accent : .white)
                        .frame(width: 64, height: 64)
                    if engine.isGenerating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.black)
                    }
                }
            }
            .disabled(!isReady || engine.isGenerating)

            if let captureError {
                Text(captureError)
                    .font(.caption)
                    .foregroundStyle(TrainingPalette.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(TrainingPalette.overlay)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - State helpers

    private var isReady: Bool {
        if case .ready = engine.loadState { return true }
        return false
    }

    private var statusText: String {
        if engine.isGenerating { return "Coach is reviewing…" }
        switch engine.loadState {
        case .idle:    return "Loading coach"
        case .loading: return "Loading coach"
        case .ready:   return "Tap shutter to ask the coach"
        case .failed:  return "Coach unavailable"
        }
    }

    // MARK: - Actions

    private func capture() {
        guard isReady, !engine.isGenerating else { return }
        captureError = nil
        speaker.reset()

        arController.snapshotJPEG { url in
            guard let url else {
                captureError = "Couldn't capture the AR frame."
                return
            }
            Task {
                await engine.generate(prompt: course.systemPrompt, imagePath: url.path)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
