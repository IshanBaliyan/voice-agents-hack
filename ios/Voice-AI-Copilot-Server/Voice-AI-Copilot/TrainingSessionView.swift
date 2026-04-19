import SwiftUI

struct TrainingSessionView: View {
    let course: TrainingCourse

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: CactusEngine

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
        .onChange(of: engine.partial) { _, newValue in
            latestResponse = newValue
            if !showResponse && !newValue.isEmpty {
                withAnimation(.easeOut(duration: 0.2)) { showResponse = true }
            }
        }
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(OttoColor.cream)
                    .padding(10)
                    .background(OttoColor.navyDeep.opacity(0.7))
                    .clipShape(Circle())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(course.title)
                    .font(OttoFont.serif(16, weight: .regular))
                    .foregroundStyle(OttoColor.cream)
                Label2Mono(text: statusText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OttoColor.navyDeep.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var responseCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OttoColor.orange)
                .padding(.top, 2)
            Text(latestResponse.isEmpty ? "…" : latestResponse)
                .font(OttoFont.serif(15))
                .italic()
                .foregroundStyle(OttoColor.cream)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    showResponse = false
                    latestResponse = ""
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OttoColor.cream)
                    .padding(6)
                    .background(OttoColor.cream.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OttoColor.navy.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(OttoColor.hairline, lineWidth: 1)
        )
    }

    private var shutterRow: some View {
        VStack(spacing: 6) {
            Button(action: capture) {
                ZStack {
                    Circle()
                        .stroke(OttoColor.cream, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    Circle()
                        .fill(engine.isGenerating ? OttoColor.orange : OttoColor.cream)
                        .frame(width: 64, height: 64)
                    if engine.isGenerating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(OttoColor.navyDeep)
                    }
                }
            }
            .disabled(!isReady || engine.isGenerating)

            if let captureError {
                Text(captureError)
                    .font(OttoFont.body(12))
                    .foregroundStyle(OttoColor.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(OttoColor.navyDeep.opacity(0.7))
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
        if engine.isGenerating { return "Coach is reviewing" }
        switch engine.loadState {
        case .idle:    return "Loading coach"
        case .loading: return "Loading coach"
        case .ready:   return "Tap to ask the coach"
        case .failed:  return "Coach unavailable"
        }
    }

    // MARK: - Actions

    private func capture() {
        guard isReady, !engine.isGenerating else { return }
        captureError = nil

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
