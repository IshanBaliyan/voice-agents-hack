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
            OttoBackground()

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

/// Lightweight holder so we can inject Otto's shared CactusEngine at runtime
/// (an @StateObject can't easily take dependencies in init).
@MainActor
final class RepairGuideStoreHolder: ObservableObject {
    @Published private(set) var store: RepairGuideStore = RepairGuideStore(engine: CactusEngine())
    @Published private(set) var phase: RepairPhase = .idle
    private var attached = false
    private var cancellables: Set<AnyCancellable> = []

    func attach(engine: CactusEngine) {
        guard !attached else { return }
        attached = true
        store = RepairGuideStore(engine: engine)
        // Mirror phase so the root view re-renders on transitions.
        store.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.phase = p }
            .store(in: &cancellables)
    }
}

// MARK: - Query / intro view

struct RepairGuideQueryView: View {
    @EnvironmentObject var store: RepairGuideStore
    @EnvironmentObject var ottoStore: OttoStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(title: "Repair Guide",
                      subtitle: "VOICE-GUIDED, STEP-BY-STEP",
                      vehicle: store.vehicle,
                      onBack: { ottoStore.go(.session) })
                .padding(.top, 40)

            Spacer()

            // Mic orb — tap to speak, tap again to submit.
            Button(action: { store.tapMic() }) {
                BreathingOrb(state: orbState, size: 180)
            }
            .buttonStyle(.plain)

            Text(statusText)
                .font(OttoFont.body(16, weight: .light))
                .foregroundStyle(Color.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .animation(.easeInOut(duration: 0.15), value: statusText)
                .id(statusText)
                .transition(.opacity)

            // Live transcript during listening.
            if store.phase == .listening, !store.transcript.isEmpty {
                Text("\u{201C}\(store.transcript)\u{201D}")
                    .font(OttoFont.serif(17, weight: .light))
                    .italic()
                    .foregroundStyle(OttoColor.cream.opacity(0.85))
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

            Spacer()

            // Example prompt chips — tap to skip voice and generate directly.
            if store.phase == .idle {
                VStack(alignment: .leading, spacing: 10) {
                    Label2Mono(text: "Try")
                        .padding(.leading, 4)
                    ForEach(["How do I change a tire",
                             "How do I change the oil",
                             "How do I replace the cabin air filter"], id: \.self) { q in
                        Button {
                            Task { await store.generate(for: q) }
                        } label: {
                            HStack {
                                Text(q)
                                    .font(OttoFont.body(14, weight: .medium))
                                    .foregroundStyle(OttoColor.cream.opacity(0.85))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .light))
                                    .foregroundStyle(OttoColor.creamFaint)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(OttoColor.hairline, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            GlassNavBar(highlighted: .guide) { ottoNav($0, store: ottoStore) }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
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
        case .idle:              return "Tap and ask: \u{201C}how do I change a tire?\u{201D}"
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

// MARK: - Step viewer (matches mockup)

struct RepairGuideStepsView: View {
    @EnvironmentObject var store: RepairGuideStore
    @EnvironmentObject var ottoStore: OttoStore

    var body: some View {
        if let manual = store.manual {
            VStack(spacing: 0) {
                HeaderBar(title: "",
                          subtitle: "",
                          vehicle: manual.vehicle,
                          micAction: { store.beginStepListening() },
                          onBack: { store.reset() })
                    .padding(.top, 40)

                VStack(spacing: 6) {
                    Label2Mono(text: "Repair Guide")
                    Text(manual.title)
                        .font(OttoFont.serif(34, weight: .regular))
                        .foregroundStyle(OttoColor.cream)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    ProgressDots(current: store.currentStep, total: manual.steps.count)
                        .padding(.top, 6)
                }
                .padding(.top, 4)

                StepCard(step: manual.steps[store.currentStep],
                         index: store.currentStep,
                         total: manual.steps.count)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                Spacer()

                StepFooterControls(
                    onPrev: { store.prevStep() },
                    onSay:  { store.beginStepListening() },
                    onNext: { store.nextStep() },
                    heard:  store.commandHeard
                )
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

                Text("GUIDE \u{00B7} STEP \(store.currentStep + 1)")
                    .font(OttoFont.mono(10))
                    .tracking(3.0)
                    .foregroundStyle(OttoColor.creamFaint)
                    .padding(.bottom, 18)
            }
        }
    }
}

// MARK: - Header (vehicle pill + optional mic)

private struct HeaderBar: View {
    var title: String
    var subtitle: String
    var vehicle: String
    var micAction: (() -> Void)? = nil
    var onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                ZStack {
                    Circle().stroke(OttoColor.hairline, lineWidth: 1)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OttoColor.cream)
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)

            Spacer()

            VehiclePill(vehicle: vehicle)

            Spacer()

            if let action = micAction {
                Button(action: action) {
                    ZStack {
                        Circle().stroke(OttoColor.hairline, lineWidth: 1)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(OttoColor.cream)
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 18)
    }
}

private struct VehiclePill: View {
    var vehicle: String
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(OttoColor.orange).frame(width: 7, height: 7)
            Text(vehicle)
                .font(OttoFont.body(13, weight: .medium))
                .foregroundStyle(OttoColor.cream)
            Text("\(batteryPercent)%")
                .font(OttoFont.mono(11))
                .foregroundStyle(OttoColor.creamFaint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(Color.white.opacity(0.04))
        )
        .overlay(
            Capsule().stroke(OttoColor.hairline, lineWidth: 1)
        )
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

// MARK: - Progress dots

private struct ProgressDots: View {
    var current: Int
    var total: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == current ? OttoColor.orange : OttoColor.cream.opacity(0.18))
                    .frame(width: 26, height: 3)
            }
        }
    }
}

// MARK: - The big wireframe card

private struct StepCard: View {
    var step: RepairStep
    var index: Int
    var total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Illustration area
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(OttoColor.hairline, lineWidth: 1)
                    )
                    .overlay(
                        GridBackground(spacing: 22)
                            .opacity(0.25)
                            .mask(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    )

                imageLayer
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(2)

                Text(String(format: "STEP %02d / %02d", index + 1, total))
                    .font(OttoFont.mono(10, weight: .medium))
                    .tracking(2.0)
                    .foregroundStyle(OttoColor.creamFaint)
                    .padding(.leading, 14)
                    .padding(.top, 12)
            }
            .frame(height: 260)

            VStack(alignment: .leading, spacing: 10) {
                Text(step.title)
                    .font(OttoFont.serif(24, weight: .regular))
                    .foregroundStyle(OttoColor.cream)

                Text(step.description)
                    .font(OttoFont.body(14, weight: .regular))
                    .foregroundStyle(OttoColor.cream.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)

                if !step.tools.isEmpty {
                    Label2Mono(text: "Tools needed")
                        .padding(.top, 4)
                    FlowRow(spacing: 8) {
                        ForEach(step.tools, id: \.self) { tool in
                            ToolChip(name: tool)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OttoColor.navy.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(OttoColor.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let path = step.imagePNGPath, let ui = UIImage(contentsOfFile: path) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Spacer()
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 42, weight: .ultraLight))
                    .foregroundStyle(OttoColor.creamFaint)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ToolChip: View {
    var name: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(OttoColor.orange).frame(width: 6, height: 6)
            Text(name)
                .font(OttoFont.body(13, weight: .medium))
                .foregroundStyle(OttoColor.cream)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.03)))
        .overlay(Capsule().stroke(OttoColor.hairline, lineWidth: 1))
    }
}

// MARK: - Step footer (prev • SAY NEXT • orange next)

private struct StepFooterControls: View {
    var onPrev: () -> Void
    var onSay:  () -> Void
    var onNext: () -> Void
    var heard:  String

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onPrev) {
                ZStack {
                    Circle().stroke(OttoColor.hairline, lineWidth: 1)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OttoColor.cream)
                }
                .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)

            Button(action: onSay) {
                HStack(spacing: 10) {
                    Circle().fill(OttoColor.orange).frame(width: 7, height: 7)
                    Text(heard.isEmpty ? "SAY \u{201C}NEXT\u{201D}" : "HEARD \u{201C}\(heard.uppercased())\u{201D}")
                        .font(OttoFont.mono(12, weight: .medium))
                        .tracking(2.5)
                        .foregroundStyle(OttoColor.cream)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .overlay(Capsule().stroke(OttoColor.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button(action: onNext) {
                ZStack {
                    Circle().fill(OttoColor.orange)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(OttoColor.navyDeep)
                }
                .frame(width: 52, height: 52)
                .shadow(color: OttoColor.orange.opacity(0.55), radius: 16, x: 0, y: 0)
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
                .font(OttoFont.body(14, weight: .regular))
                .foregroundStyle(OttoColor.cream.opacity(0.85))
                .multilineTextAlignment(.center)

            Button(action: onRetry) {
                Text("TRY AGAIN")
                    .font(OttoFont.mono(11, weight: .semibold))
                    .tracking(2.5)
                    .foregroundStyle(OttoColor.navyDeep)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(OttoColor.orange))
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

// MARK: - Simple flow-row wrapping HStack (for tool chips)

private struct FlowRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        // For 1–2 chips (our typical case) this is indistinguishable from HStack
        // and avoids hand-rolling a layout.
        HStack(spacing: spacing) {
            content()
            Spacer(minLength: 0)
        }
    }
}
