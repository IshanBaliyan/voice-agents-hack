import SwiftUI
import UIKit
import Combine

// MARK: - Root: query intro or step viewer

struct RepairGuideRootView: View {
    @EnvironmentObject var ottoStore: OttoStore
    @StateObject private var store: RepairGuideStoreHolder

    init() {
        _store = StateObject(wrappedValue: RepairGuideStoreHolder())
    }

    var body: some View {
        ZStack {
            OttoAtmosphere()

            Group {
                switch store.phase {
                case .ready:
                    RepairGuideStepsView()
                        .environmentObject(store.store)
                        .environmentObject(ottoStore)
                default:
                    RepairGuideQueryView()
                        .environmentObject(store.store)
                        .environmentObject(ottoStore)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: store.phase == .ready)
        }
        .task {
            store.attach(engine: ottoStore.engine)
        }
    }
}

/// Lightweight holder so we can inject the shared InferenceController at runtime
/// (an @StateObject can't easily take dependencies in init).
@MainActor
final class RepairGuideStoreHolder: ObservableObject {
    @Published private(set) var store: RepairGuideStore = RepairGuideStore(engine: InferenceController())
    @Published private(set) var phase: RepairPhase = .idle
    private var attached = false
    private var cancellables: Set<AnyCancellable> = []

    func attach(engine: InferenceController) {
        guard !attached else { return }
        attached = true
        store = RepairGuideStore(engine: engine)
        store.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.phase = p }
            .store(in: &cancellables)
    }
}

// MARK: - Query / intro view (design screen 04 · Repair guide · ask)

struct RepairGuideQueryView: View {
    @EnvironmentObject var store: RepairGuideStore
    @EnvironmentObject var ottoStore: OttoStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(vehicle: store.vehicle, onBack: { ottoStore.go(.session) })
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                OttoEyebrow(text: "Repair Guide")
                Text("Voice-guided,\nstep by step.")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(OttoColor.ink)
                    .kerning(-0.6)
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 8)

            Spacer(minLength: 0)

            Button(action: { store.tapMic() }) {
                BreathingOrb(state: orbState, size: 170)
            }
            .buttonStyle(.plain)

            Text(statusText)
                .font(OttoFont.body(14, weight: .light))
                .foregroundStyle(OttoColor.ink2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .animation(.easeInOut(duration: 0.15), value: statusText)
                .id(statusText)
                .transition(.opacity)

            // Live transcript during listening
            if store.phase == .listening, !store.transcript.isEmpty {
                Text("\u{201C}\(store.transcript)\u{201D}")
                    .font(.system(size: 17, weight: .light))
                    .italic()
                    .foregroundStyle(OttoColor.ink.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 12)
            }

            // Error + retry
            if case .error(let msg) = store.phase {
                ErrorPanel(message: msg, onRetry: { store.reset() })
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
            }

            Spacer(minLength: 0)

            // Suggestion chips — tap to skip voice and generate directly.
            if store.phase == .idle {
                VStack(alignment: .leading, spacing: 8) {
                    OttoEyebrow(text: "Try")
                        .padding(.leading, 4)
                    ForEach(["How do I change a tire",
                             "How do I change the oil",
                             "How do I replace the cabin air filter"], id: \.self) { q in
                        Button {
                            Task { await store.generate(for: q) }
                        } label: {
                            HStack {
                                Text(q)
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(OttoColor.ink)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .light))
                                    .foregroundStyle(OttoColor.ink3)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(.ultraThinMaterial)
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [Color(red: 30/255, green: 44/255, blue: 72/255).opacity(0.45),
                                                 Color(red: 16/255, green: 26/255, blue: 46/255).opacity(0.65)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(OttoColor.fog3.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }

            GlassNavBar(highlighted: .guide) { ottoNav($0, store: ottoStore) }
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
        }
    }

    private var orbState: VoiceState {
        switch store.phase {
        case .idle, .error:        return .idle
        case .listening:           return .listening
        case .thinking, .generatingImages: return .thinking
        case .ready:               return .idle
        }
    }

    private var statusText: String {
        switch store.phase {
        case .idle:              return "Tap and ask — \u{201C}how do I change a tire?\u{201D}"
        case .listening:         return "Listening… tap again to ask."
        case .thinking:          return "Thinking…"
        case .generatingImages:
            let total = store.manual?.steps.count ?? 3
            return "Drawing step \(min(store.imageProgress + 1, total)) of \(total)…"
        case .ready:             return ""
        case .error:             return ""
        }
    }
}

// MARK: - Step viewer (design screen 05 · Repair guide · step)

struct RepairGuideStepsView: View {
    @EnvironmentObject var store: RepairGuideStore
    @EnvironmentObject var ottoStore: OttoStore

    var body: some View {
        if let manual = store.manual {
            VStack(spacing: 0) {
                HeaderBar(vehicle: manual.vehicle,
                          micAction: { store.beginStepListening() },
                          onBack: { store.reset() })
                    .padding(.top, 4)

                VStack(spacing: 12) {
                    OttoEyebrow(text: manual.title)
                    ProgressDots(current: store.currentStep, total: manual.steps.count)
                }
                .padding(.top, 6)

                ScrollView(showsIndicators: false) {
                    StepCard(step: manual.steps[store.currentStep],
                             index: store.currentStep,
                             total: manual.steps.count)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                }
                .id(store.currentStep)

                StepFooterControls(
                    onPrev: { store.prevStep() },
                    onSay:  { store.beginStepListening() },
                    onNext: { store.nextStep() },
                    heard:  store.commandHeard
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                GlassNavBar(highlighted: .guide) { ottoNav($0, store: ottoStore) }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
            }
        }
    }
}

// MARK: - Header (back · vehicle pill · optional mic)

private struct HeaderBar: View {
    var vehicle: String
    var micAction: (() -> Void)? = nil
    var onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                OttoNeuCircle(size: 40) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OttoColor.ink)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            VehiclePill(vehicle: vehicle)

            Spacer()

            if let action = micAction {
                Button(action: action) {
                    OttoNeuCircle(size: 40, active: true) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OttoColor.accentWarm)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

private struct VehiclePill: View {
    var vehicle: String
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(OttoColor.fog2)
                .frame(width: 6, height: 6)
                .shadow(color: OttoColor.fog2, radius: 4)
            Text(vehicle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OttoColor.ink)
            Text("\(batteryPercent)%")
                .font(OttoFont.mono(10))
                .foregroundStyle(OttoColor.ink3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(OttoColor.fog3.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 4)
    }

    private var batteryPercent: Int {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level < 0 { return 96 }
        return max(0, min(100, Int(level * 100)))
        #else
        return 96
        #endif
    }
}

// MARK: - Progress (segmented bar with current capsule highlighted)

private struct ProgressDots: View {
    var current: Int
    var total: Int

    var body: some View {
        if total <= 5 {
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(fill(for: i))
                        .frame(width: i == current ? 26 : 14, height: 3)
                        .shadow(color: i == current ? OttoColor.accentWarm.opacity(0.8) : .clear, radius: 4)
                        .animation(.easeInOut(duration: 0.25), value: current)
                }
            }
        } else {
            HStack(spacing: 8) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i <= current ? (i == current ? OttoColor.accentWarm : OttoColor.fog2) : OttoColor.ink4)
                        .frame(width: 14, height: 3)
                }
                Text("\(current + 1) / \(total)")
                    .font(OttoFont.mono(10, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(OttoColor.ink3)
                    .padding(.leading, 4)
            }
        }
    }

    private func fill(for i: Int) -> Color {
        if i == current { return OttoColor.accentWarm }
        if i < current  { return OttoColor.fog2 }
        return OttoColor.ink4
    }
}

// MARK: - Step card (illustration + body + tools)

private struct StepCard: View {
    var step: RepairStep
    var index: Int
    var total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Illustration
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 14/255, green: 22/255, blue: 40/255).opacity(0.85),
                                 Color(red: 22/255, green: 34/255, blue: 58/255).opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        // Faint grid
                        GridBackground(spacing: 24)
                            .opacity(0.10)
                            .mask(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    )

                imageLayer
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(2)

                Text(String(format: "STEP %02d / %02d", index + 1, total))
                    .font(OttoFont.mono(9.5, weight: .medium))
                    .tracking(2.0)
                    .foregroundStyle(OttoColor.ink3)
                    .padding(.leading, 14)
                    .padding(.top, 12)
            }
            .frame(height: 220)

            VStack(alignment: .leading, spacing: 10) {
                Text(step.title)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(OttoColor.ink)
                    .kerning(-0.3)

                Text(step.description)
                    .font(OttoFont.body(14, weight: .light))
                    .foregroundStyle(OttoColor.ink2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = step.safetyNote, !note.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OttoColor.accentWarm)
                            .padding(.top, 2)
                        Text(note)
                            .font(OttoFont.body(13))
                            .foregroundStyle(OttoColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(OttoColor.accentWarm.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(OttoColor.accentWarm.opacity(0.30), lineWidth: 1)
                    )
                }

                if !step.tools.isEmpty {
                    OttoEyebrow(text: "Tools needed")
                        .padding(.top, 6)
                    HStack(spacing: 8) {
                        ForEach(step.tools, id: \.self) { tool in
                            ToolChip(name: tool)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(18)
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 30/255, green: 44/255, blue: 72/255).opacity(0.55),
                             Color(red: 16/255, green: 26/255, blue: 46/255).opacity(0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(OttoColor.fog3.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.40), radius: 18, x: 0, y: 12)
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let path = step.imagePNGPath, let ui = UIImage(contentsOfFile: path) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        } else {
            ImagePlaceholder()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Shown in a StepCard while the nanobanana illustration for that step is
/// still generating. Text instructions render immediately; this placeholder
/// communicates that the image is on its way without blocking the reader.
private struct ImagePlaceholder: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(OttoColor.ink3)
                .opacity(pulse ? 0.45 : 0.95)
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .tint(OttoColor.ink3)
                Text("DRAWING ILLUSTRATION")
                    .font(OttoFont.mono(9.5, weight: .medium))
                    .tracking(2.0)
                    .foregroundStyle(OttoColor.ink3)
            }
            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct ToolChip: View {
    var name: String
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(OttoColor.fog2)
                .frame(width: 5, height: 5)
                .shadow(color: OttoColor.fog2, radius: 3)
            Text(name)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(OttoColor.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(OttoColor.fog3.opacity(0.06)))
        .overlay(Capsule().stroke(OttoColor.fog3.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Step footer (back · SAY NEXT pill · forward)

private struct StepFooterControls: View {
    var onPrev: () -> Void
    var onSay:  () -> Void
    var onNext: () -> Void
    var heard:  String

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPrev) {
                OttoNeuCircle(size: 48) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OttoColor.ink)
                }
            }
            .buttonStyle(.plain)

            Button(action: onSay) {
                HStack(spacing: 10) {
                    PulsingDot(color: OttoColor.accentWarm)
                    Text(heard.isEmpty ? "SAY \u{201C}NEXT\u{201D}" : "HEARD \u{201C}\(heard.uppercased())\u{201D}")
                        .font(OttoFont.mono(11, weight: .medium))
                        .tracking(2.5)
                        .foregroundStyle(OttoColor.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Capsule().fill(.ultraThinMaterial))
                .background(Capsule().fill(LinearGradient(
                    colors: [Color(red: 30/255, green: 44/255, blue: 72/255).opacity(0.55),
                             Color(red: 16/255, green: 26/255, blue: 46/255).opacity(0.7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(Capsule().stroke(OttoColor.fog3.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.30), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)

            Button(action: onNext) {
                OttoNeuCircle(size: 48, active: true) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OttoColor.bg0)
                }
                .background(
                    Circle().fill(OttoColor.accentWarm)
                )
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Error panel

private struct ErrorPanel: View {
    var message: String
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(message)
                .font(OttoFont.body(14))
                .foregroundStyle(OttoColor.ink)
                .multilineTextAlignment(.center)

            Button(action: onRetry) {
                Text("TRY AGAIN")
                    .font(OttoFont.mono(11, weight: .semibold))
                    .tracking(2.5)
                    .foregroundStyle(OttoColor.bg0)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(OttoColor.accentWarm))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OttoColor.danger.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OttoColor.danger.opacity(0.35), lineWidth: 1)
        )
    }
}
