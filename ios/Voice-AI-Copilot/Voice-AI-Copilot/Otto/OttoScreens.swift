import SwiftUI

// MARK: - Root

struct OttoRootView: View {
    @EnvironmentObject private var engine: InferenceController
    @StateObject private var store = OttoStore()

    var body: some View {
        ZStack {
            OttoBackground()

            switch store.route {
            case .home:        OttoLandingWebView(onTap: { store.go(.session) })
                                   .background(Color(red: 0.02, green: 0.03, blue: 0.06))
                                   .ignoresSafeArea()
            case .session:     ActiveSessionView().environmentObject(store)
            case .camera:      CameraScanView().environmentObject(store)
            case .history:     HistoryView().environmentObject(store)
            case .profile:     ProfileView().environmentObject(store)
            case .repairGuide: RepairGuideRootView().environmentObject(store)
            case .training:    TrainingView().environmentObject(store)
            case .exploded:    ExplodedView().environmentObject(store)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Wire the environment-injected controller into OttoStore, then warm it up.
            store.attach(engine: engine)
            await store.warmUp()
        }
    }
}

// MARK: - Home
// Landing page. On first appear the porsche drives top → bottom across the
// screen, then exits off the bottom and the Otto home UI fades in.

struct VoiceHomeView: View {
    @EnvironmentObject var store: OttoStore

    @State private var arrived = false
    @State private var drive: CGFloat = 0          // 0 = off-top, 1 = off-bottom
    @State private var introOpacity: Double = 1
    @State private var homeOpacity: Double = 0
    @State private var showHome = false

    private let carAspect: CGFloat = 752.0 / 1402.0

    private func dockedHeight(_ geo: GeometryProxy) -> CGFloat {
        min(geo.size.height * 0.26, 230)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                OttoAtmosphere()
                    .ignoresSafeArea()

                introLayer(geo: geo)
                    .opacity(introOpacity)
                    .allowsHitTesting(!showHome)

                if showHome {
                    homeLayer(geo: geo)
                        .opacity(homeOpacity)
                }
            }
        }
        .task {
            guard !arrived else { return }
            arrived = true
            withAnimation(.linear(duration: 10.5)) { drive = 1.0 }
            try? await Task.sleep(nanoseconds: 10_600_000_000)
            showHome = true
            withAnimation(.easeInOut(duration: 0.55)) {
                introOpacity = 0
                homeOpacity = 1
            }
        }
    }

    // Intro: porsche drives top → bottom at constant size.
    private func introLayer(geo: GeometryProxy) -> some View {
        let carH = dockedHeight(geo)
        let carW = carH * carAspect
        let startY = -carH
        let endY = geo.size.height + carH * 0.5
        let carY = startY + (endY - startY) * drive

        return Image("PorscheClipart")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: carW, height: carH)
            .rotationEffect(.degrees(180))
            .shadow(color: OttoColor.accentWarm.opacity(0.35), radius: 28, x: 0, y: 14)
            .position(x: geo.size.width / 2, y: carY)
    }

    // Home: wordmark + docked porsche + nav. Tap anywhere opens session.
    private func homeLayer(geo: GeometryProxy) -> some View {
        let carH = min(geo.size.height * 0.42, 380)
        let carW = carH * carAspect

        return Button {
            store.go(.session)
        } label: {
            VStack(spacing: 0) {
                OttoTopBar(vehicle: "2018 Honda Civic", battery: 96, showWordmark: false)
                    .padding(.top, 4)

                Spacer().frame(height: 16)

                OttoWordmark(size: 56)
                OttoEyebrow(text: "Your pocket mechanic")
                    .padding(.top, 6)

                Spacer()

                Image("PorscheClipart")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: carW, height: carH)
                    .rotationEffect(.degrees(180))
                    .shadow(color: OttoColor.accentWarm.opacity(0.30), radius: 34, x: 0, y: 20)

                Spacer()

                OttoEyebrow(text: "Tap anywhere to talk")
                    .padding(.bottom, 20)

                GlassNavBar(highlighted: .home) { ottoNav($0, store: store) }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active Session (Listening + Speaking + Thinking + Idle)
// Mirrors design screens 02 (Listening) and 03 (Otto responds).

struct ActiveSessionView: View {
    @EnvironmentObject var store: OttoStore
    @EnvironmentObject var engine: InferenceController

    @State private var presentedPage: RetrievedPage?

    private var isRecording: Bool { store.voice == .listening }

    /// RAG pages come from the remote relay only. Empty in local mode.
    private var retrievedPages: [RetrievedPage] {
        engine.remote.retrievedPages
    }

    var body: some View {
        ZStack {
            OttoAtmosphere()

            VStack(spacing: 0) {
                OttoTopBar(vehicle: "2018 Honda Civic", battery: 96, showWordmark: true)
                    .padding(.top, 4)

                statusBadge
                    .padding(.top, 8)

                // Snapchat-style live camera viewport fills the middle area.
                // Transcript + waveform are overlaid on the bottom half with a
                // readability scrim so they stay legible on any camera content.
                cameraViewport
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .frame(maxHeight: .infinity)

                // Floating mic — docked bottom-right above the nav bar.
                HStack {
                    Spacer()
                    Button { store.tapMic() } label: {
                        BreathingOrb(state: store.voice, size: orbSize)
                            .frame(width: orbSize * 1.9, height: orbSize * 1.9)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 18)
                .padding(.bottom, 6)

                GlassNavBar(highlighted: .home) { ottoNav($0, store: store) }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: retrievedPages.count)
        .sheet(item: $presentedPage) { page in
            OttoPageViewerSheet(page: page)
        }
    }

    @ViewBuilder
    private var cameraViewport: some View {
        ZStack(alignment: .bottom) {
            #if os(iOS) && !targetEnvironment(simulator)
            SessionCameraBackdrop(camera: store.camera)
            #else
            Color.black
            #endif

            // Bottom-up scrim so overlay text stays readable on bright scenes.
            LinearGradient(
                colors: [.clear, .clear, Color.black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            // Transcript + waveform overlaid on the lower portion of the
            // camera card. Gives the feed breathing room up top, like
            // Snapchat's viewfinder with captions on the bottom.
            VStack(spacing: 14) {
                transcriptBlock
                    .padding(.horizontal, 20)

                if store.voice == .listening {
                    OttoWaveLine(color: OttoColor.fog2, active: true, width: 240, height: 28)
                }

                if store.voice == .speaking {
                    speakingActions
                        .padding(.horizontal, 20)
                }

                // RAG citation chips — tap to open the source page. Stays
                // visible after Otto stops speaking so the user can still
                // reference what was cited.
                if !retrievedPages.isEmpty {
                    citationChipRow
                        .padding(.horizontal, 20)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(OttoColor.fog3.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 16)
    }

    private var orbSize: CGFloat { 54 }   // nav-bar icon pill (44) + ~20%

    @ViewBuilder
    private var statusBadge: some View {
        switch store.voice {
        case .listening:
            HStack(spacing: 8) {
                PulsingDot(color: OttoColor.fog2)
                OttoEyebrow(text: "Listening", color: OttoColor.fog2)
            }
        case .thinking:
            HStack(spacing: 8) {
                PulsingDot(color: OttoColor.accent)
                OttoEyebrow(text: "Thinking", color: OttoColor.accent)
            }
        case .speaking:
            HStack(spacing: 8) {
                PulsingDot(color: OttoColor.accentWarm)
                OttoEyebrow(text: "Otto is speaking", color: OttoColor.accentWarm)
            }
        case .idle:
            EmptyView()
        }
    }

    // Live transcript while listening, Otto's streaming answer while speaking,
    // and a soft hint at idle. Same content as before — just restyled.
    @ViewBuilder private var transcriptBlock: some View {
        Group {
            switch store.voice {
            case .listening:
                Text(store.partialTranscript.isEmpty ? "Listening…" : store.partialTranscript)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(OttoColor.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .lineLimit(4)

            case .thinking:
                Text("Thinking…")
                    .font(OttoFont.body(15, weight: .light))
                    .foregroundStyle(OttoColor.ink2)

            case .speaking:
                // Prefer the live streaming partial (tokens as they arrive
                // from the relay) over `currentAnswer`, which is only set
                // after the full turn completes. Falls back to currentAnswer
                // once the turn is done.
                let streaming = engine.partial.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalized = store.currentAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                let a = !streaming.isEmpty ? streaming : finalized
                OttoCard(padding: 18, corner: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        OttoEyebrow(text: engine.mode == .remote ? "Otto · Mac relay" : "Otto · on-device")
                        Text(a.isEmpty ? "Speaking…" : a)
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(OttoColor.ink)
                            .lineSpacing(3)
                            .multilineTextAlignment(.leading)
                    }
                }

            case .idle:
                if let last = store.history.last, last.role == .otto {
                    Text(last.text)
                        .font(OttoFont.body(14))
                        .foregroundStyle(OttoColor.ink3)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                } else {
                    Text("Tap to talk")
                        .font(OttoFont.body(14, weight: .light))
                        .foregroundStyle(OttoColor.ink3)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .animation(.easeInOut(duration: 0.2), value: store.voice)
    }

    // Horizontally scrolling list of citation chips sourced from the Mac
    // server's RAG hits. Tapping a chip opens the corresponding PDF page in
    // a modal viewer (OttoPageViewerSheet).
    @ViewBuilder private var citationChipRow: some View {
        VStack(spacing: 6) {
            OttoEyebrow(text: "SOURCES · TAP TO VIEW", color: OttoColor.ink3)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(retrievedPages) { page in
                        Button {
                            presentedPage = page
                        } label: {
                            HStack(spacing: 6) {
                                Text("[\(page.citation)]")
                                    .font(OttoFont.mono(11, weight: .bold))
                                    .foregroundStyle(OttoColor.accentWarm)
                                Text("\(page.source) · p. \(page.page)")
                                    .font(OttoFont.body(12))
                                    .foregroundStyle(OttoColor.ink)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(.ultraThinMaterial)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(OttoColor.fog3.opacity(0.25), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reference \(page.citation), \(page.source) page \(page.page). Tap to view.")
                    }
                }
            }
        }
    }

    // "Start guide / Not now" chips appear while Otto is speaking — matches
    // the redesign's gentle hand-off pattern.
    @ViewBuilder private var speakingActions: some View {
        HStack(spacing: 10) {
            Button { store.go(.repairGuide) } label: {
                OttoChip(text: "Start guide", active: true)
            }
            .buttonStyle(.plain)

            Button { store.resetSession() } label: {
                OttoChip(text: "Not now")
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
    }
}

// Small pulsing status dot.
struct PulsingDot: View {
    var color: Color
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color, radius: 6)
            .opacity(pulse ? 0.5 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Shared nav routing

func ottoNav(_ item: GlassNavBar.Item, store: OttoStore) {
    switch item {
    case .home:     store.go(.session)
    case .guide:    store.go(.repairGuide)
    case .exploded: store.go(.exploded)
    case .history:  store.go(.history)
    case .training: store.go(.training)
    case .profile:  store.go(.profile)
    }
}

// MARK: - History
// Live, persistent log of past Q&A and Repair Guide manuals. Pulls from
// HistoryStore.shared — written into by OttoStore (Q&A turns) and
// RepairGuideStore (manuals + their step images).

struct HistoryView: View {
    @EnvironmentObject var store: OttoStore
    @StateObject private var history = HistoryStore.shared
    @State private var selected: HistoryEntry?

    var body: some View {
        ZStack {
            OttoAtmosphere()

            VStack(spacing: 0) {
                OttoTopBar(vehicle: "2018 Honda Civic", battery: 96)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("History")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(OttoColor.ink)
                        .kerning(-0.6)
                    OttoEyebrow(text: "Your past conversations")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 8)

                if history.entries.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(history.entries) { entry in
                                Button { selected = entry } label: {
                                    HistoryCardRow(
                                        entry: entry,
                                        meta: history.relativeMeta(for: entry),
                                        tail: history.tail(for: entry)
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        history.delete(entry)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                    }
                }

                GlassNavBar(highlighted: .history) { ottoNav($0, store: store) }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
            }
        }
        .sheet(item: $selected) { entry in
            HistoryDetailView(entry: entry)
        }
        .onAppear { history.load() }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(OttoColor.ink3)
            Text("Nothing here yet")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(OttoColor.ink2)
            Text("Ask Otto a question or generate a repair\nguide — they'll show up here.")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(OttoColor.ink3)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}

private struct HistoryCardRow: View {
    let entry: HistoryEntry
    let meta: String
    let tail: String

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(OttoColor.ink)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(meta)
                        .font(OttoFont.mono(11))
                        .foregroundStyle(OttoColor.ink3)
                    Circle().fill(OttoColor.ink4).frame(width: 3, height: 3)
                    Text(tail)
                        .font(.system(size: 11))
                        .foregroundStyle(OttoColor.ink3)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(OttoColor.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 6)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if entry.kind == .manual,
           let path = entry.thumbnailPath,
           let ui = UIImage(contentsOfFile: path) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
                .overlay(Circle().stroke(OttoColor.fog3.opacity(0.20), lineWidth: 1))
        } else {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [OttoColor.accentWarm.opacity(0.18), OttoColor.fog1.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 1))
                Image(systemName: entry.kind == .manual ? "wrench.and.screwdriver" : "waveform")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(OttoColor.accentWarm)
            }
        }
    }
}

// MARK: - History Detail
// Sheet that opens when a History row is tapped. Two layouts:
//
//   • Manual:  shows the original question, manual title, and every step with
//              its illustration — a scrollable, document-style replay.
//   • Q&A:     shows the question and Otto's answer, formatted as a transcript.

struct HistoryDetailView: View {
    let entry: HistoryEntry

    @Environment(\.dismiss) private var dismiss
    @State private var manual: RepairManual?

    var body: some View {
        ZStack {
            OttoAtmosphere()

            VStack(spacing: 0) {
                detailHeader
                    .padding(.top, 4)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        // Original question — always shown.
                        VStack(alignment: .leading, spacing: 8) {
                            OttoEyebrow(text: "You asked")
                            Text(entry.query)
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(OttoColor.ink)
                                .kerning(-0.2)
                                .lineSpacing(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(.ultraThinMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(OttoColor.fog3.opacity(0.10), lineWidth: 1)
                        )

                        if entry.kind == .manual {
                            manualBody
                        } else {
                            qaBody
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Resolve the cached manual lazily so the row tap is instant even
            // for big multi-step guides.
            if entry.kind == .manual {
                manual = HistoryStore.shared.loadManual(for: entry)
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                OttoNeuCircle(size: 40) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OttoColor.ink)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                OttoEyebrow(text: HistoryStore.shared.relativeMeta(for: entry))
                Text(entry.kind == .manual ? "Repair guide" : "Voice answer")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(OttoColor.ink2)
            }

            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var manualBody: some View {
        if let m = manual {
            VStack(alignment: .leading, spacing: 14) {
                Text(m.title)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(OttoColor.ink)
                    .kerning(-0.4)
                    .padding(.top, 6)

                if let overview = m.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(OttoColor.ink2)
                        .lineSpacing(3)
                }

                if !m.requiredTools.isEmpty {
                    OttoEyebrow(text: "Required tools")
                        .padding(.top, 4)
                    FlexibleChips(items: m.requiredTools)
                }

                if !m.safetyWarnings.isEmpty {
                    OttoEyebrow(text: "Safety")
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(m.safetyWarnings, id: \.self) { w in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(OttoColor.accentWarm)
                                    .padding(.top, 2)
                                Text(w)
                                    .font(.system(size: 13, weight: .light))
                                    .foregroundStyle(OttoColor.ink)
                            }
                        }
                    }
                }

                ForEach(Array(m.steps.enumerated()), id: \.element.id) { idx, step in
                    HistoryStepCard(step: step, index: idx, total: m.steps.count)
                }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().tint(OttoColor.accentWarm)
                Text("Loading manual…")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(OttoColor.ink3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
    }

    private var qaBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            OttoEyebrow(text: "Otto answered")
            Text(entry.answer ?? "")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(OttoColor.ink)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 30/255, green: 44/255, blue: 72/255).opacity(0.55),
                             Color(red: 16/255, green: 26/255, blue: 46/255).opacity(0.7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(OttoColor.fog3.opacity(0.10), lineWidth: 1)
        )
    }
}

// One step card in the manual viewer — illustration + body + tools.
private struct HistoryStepCard: View {
    let step: RepairStep
    let index: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 14/255, green: 22/255, blue: 40/255).opacity(0.85),
                                 Color(red: 22/255, green: 34/255, blue: 58/255).opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))

                if let p = step.imagePNGPath, let ui = UIImage(contentsOfFile: p) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(2)
                } else {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 38, weight: .ultraLight))
                        .foregroundStyle(OttoColor.ink3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Text(String(format: "STEP %02d / %02d", index + 1, total))
                    .font(OttoFont.mono(9.5, weight: .medium))
                    .tracking(2.0)
                    .foregroundStyle(OttoColor.ink3)
                    .padding(.leading, 14)
                    .padding(.top, 12)
            }
            .frame(height: 200)

            VStack(alignment: .leading, spacing: 10) {
                Text(step.title)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(OttoColor.ink)
                    .kerning(-0.3)

                Text(step.description)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(OttoColor.ink2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !step.tools.isEmpty {
                    OttoEyebrow(text: "Tools")
                        .padding(.top, 4)
                    FlexibleChips(items: step.tools)
                }
            }
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 30/255, green: 44/255, blue: 72/255).opacity(0.55),
                             Color(red: 16/255, green: 26/255, blue: 46/255).opacity(0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(OttoColor.fog3.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 8)
    }
}

// Wrap-flow row of small chips (used for tools / required tools).
private struct FlexibleChips: View {
    let items: [String]

    var body: some View {
        // SwiftUI doesn't ship a wrap-flow layout pre-iOS 16 friendly enough
        // to use here — VStack of HStacks via chunking keeps it simple. Up to
        // ~6 chips per row before clipping; tools lists are short by design.
        let rows = chunked(items, perRow: 3)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { chip in
                        HStack(spacing: 6) {
                            Circle().fill(OttoColor.fog2).frame(width: 5, height: 5)
                                .shadow(color: OttoColor.fog2, radius: 3)
                            Text(chip)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(OttoColor.ink)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(OttoColor.fog3.opacity(0.06)))
                        .overlay(Capsule().stroke(OttoColor.fog3.opacity(0.12), lineWidth: 1))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chunked(_ arr: [String], perRow: Int) -> [[String]] {
        stride(from: 0, to: arr.count, by: perRow).map {
            Array(arr[$0..<min($0 + perRow, arr.count)])
        }
    }
}

// MARK: - Profile

struct ProfileView: View {
    @EnvironmentObject var store: OttoStore
    @EnvironmentObject var engine: InferenceController

    var body: some View {
        ZStack {
            OttoAtmosphere()

            VStack(spacing: 0) {
                OttoTopBar(vehicle: "2018 Honda Civic", battery: 96)
                    .padding(.top, 4)

                VStack(spacing: 4) {
                    Text("Profile")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(OttoColor.ink)
                        .kerning(-0.5)
                    OttoEyebrow(text: "Your garage")
                }
                .padding(.top, 8)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        avatar
                            .padding(.top, 22)

                        VStack(spacing: 4) {
                            Text("Alex Chen")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(OttoColor.ink)
                                .kerning(-0.2)
                            OttoEyebrow(text: "2018 Honda Civic · EX")
                        }
                        .padding(.top, 14)

                        VStack(spacing: 8) {
                            ProfileGlassRow(icon: "car.fill", label: "Vehicles", count: "2")
                            ProfileGlassRow(icon: "wrench.and.screwdriver.fill", label: "Saved guides", count: "7")
                            ProfileGlassRow(icon: "gearshape.fill", label: "Settings", count: nil)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 22)

                        AIModeSection(engine: engine)
                            .padding(.horizontal, 20)
                            .padding(.top, 22)
                            .padding(.bottom, 24)
                    }
                }

                GlassNavBar(highlighted: .profile) { ottoNav($0, store: store) }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
            }
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [OttoColor.fog2.opacity(0.6), OttoColor.fog1.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    Circle().fill(RadialGradient(
                        colors: [Color.white.opacity(0.30), .clear],
                        center: UnitPoint(x: 0.30, y: 0.25),
                        startRadius: 0,
                        endRadius: 60))
                )
                .overlay(Circle().stroke(OttoColor.fog3.opacity(0.18), lineWidth: 1))
            Image(systemName: "person.fill")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(OttoColor.ink)
        }
        .frame(width: 96, height: 96)
        .shadow(color: OttoColor.fog2.opacity(0.35), radius: 30)
        .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 12)
    }
}

// AI mode — two side-by-side cards.
private struct AIModeSection: View {
    @ObservedObject var engine: InferenceController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OttoEyebrow(text: "AI Mode")
                .padding(.leading, 4)

            HStack(spacing: 10) {
                AIModeCard(
                    icon: "iphone",
                    title: "On-device",
                    sub: "Runs fully on your iPhone",
                    status: statusLine(for: .local),
                    selected: engine.mode == .local,
                    action: { engine.mode = .local }
                )
                AIModeCard(
                    icon: "laptopcomputer",
                    title: "Mac relay",
                    sub: "Routes voice + image to your Mac",
                    status: statusLine(for: .remote),
                    selected: engine.mode == .remote,
                    action: { engine.mode = .remote }
                )
            }
        }
    }

    private func statusLine(for mode: AppMode) -> String {
        guard mode == engine.mode else {
            return mode == .local ? "Ready · on-device" : "Standby"
        }
        switch engine.loadState {
        case .idle:    return "Idle"
        case .loading: return mode == .local ? "Loading on-device weights…" : "Connecting to relay…"
        case .ready:   return mode == .local ? "Ready · on-device" : "Connected · Mac relay"
        case .failed(let msg): return msg
        }
    }
}

private struct AIModeCard: View {
    let icon: String
    let title: String
    let sub: String
    let status: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(OttoColor.accentWarm.opacity(0.14))
                            .frame(width: 26, height: 26)
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(OttoColor.accentWarm)
                    }
                    Spacer()
                    if selected {
                        ZStack {
                            Circle().fill(OttoColor.accentWarm)
                                .frame(width: 16, height: 16)
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(OttoColor.bg0)
                        }
                    }
                }
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OttoColor.ink)
                    .padding(.top, 8)
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(OttoColor.ink3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 3)
                Text(status.uppercased())
                    .font(OttoFont.mono(9.5, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(selected ? OttoColor.accentWarm : OttoColor.ink4)
                    .padding(.top, 10)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(
                        colors: selected
                            ? [OttoColor.fog2.opacity(0.18), OttoColor.fog1.opacity(0.18)]
                            : [Color(red: 30/255, green: 44/255, blue: 72/255).opacity(0.45),
                               Color(red: 16/255, green: 26/255, blue: 46/255).opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(selected ? OttoColor.fog2.opacity(0.55) : OttoColor.fog3.opacity(0.08),
                            lineWidth: selected ? 1.2 : 1)
            )
            .shadow(color: selected ? OttoColor.fog2.opacity(0.30) : .black.opacity(0.20),
                    radius: selected ? 18 : 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct ProfileGlassRow: View {
    let icon: String
    let label: String
    let count: String?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(
                        colors: [OttoColor.accentWarm.opacity(0.20), OttoColor.fog1.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(OttoColor.accentWarm)
            }
            .frame(width: 32, height: 32)

            Text(label)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(OttoColor.ink)
            Spacer()
            if let count {
                Text(count)
                    .font(OttoFont.mono(13))
                    .foregroundStyle(OttoColor.ink3)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(OttoColor.ink3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
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
}

// MARK: - Camera

struct CameraScanView: View {
    @EnvironmentObject var store: OttoStore

    #if os(iOS) && !targetEnvironment(simulator)
    @StateObject private var camera = CameraController()
    #endif

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            cameraBackground

            VStack {
                HStack {
                    Button {
                        store.go(.home)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OttoColor.ink)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.ultraThinMaterial))
                            .overlay(Circle().stroke(OttoColor.fog3.opacity(0.20), lineWidth: 1))
                            .shadow(color: .black.opacity(0.5), radius: 10)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                Spacer()

                Button {
                    #if os(iOS) && !targetEnvironment(simulator)
                    Task { _ = await camera.capture() }
                    #endif
                } label: {
                    ZStack {
                        Circle().stroke(OttoColor.ink, lineWidth: 3).frame(width: 72, height: 72)
                        Circle().fill(OttoColor.ink.opacity(isSimulator ? 0.35 : 1.0))
                            .frame(width: 58, height: 58)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSimulator)
                .padding(.bottom, 34)
            }
        }
        #if os(iOS) && !targetEnvironment(simulator)
        .task {
            _ = await camera.requestAuthorization()
            camera.configureIfNeeded()
            camera.start()
        }
        .onDisappear { camera.stop() }
        #endif
    }

    @ViewBuilder
    private var cameraBackground: some View {
        #if os(iOS) && !targetEnvironment(simulator)
        if camera.isAuthorized {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
        } else {
            permissionPlaceholder
        }
        #else
        simulatorPlaceholder
        #endif
    }

    private var permissionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(OttoColor.ink2)
            Text("Camera access needed")
                .font(OttoFont.body(15, weight: .medium))
                .foregroundStyle(OttoColor.ink)
            Text("Enable in Settings to scan tools & parts.")
                .font(OttoFont.body(13))
                .foregroundStyle(OttoColor.ink3)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
    }

    private var simulatorPlaceholder: some View {
        ZStack {
            OttoAtmosphere()
            VStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 50, weight: .ultraLight))
                    .foregroundStyle(OttoColor.ink2)
                OttoEyebrow(text: "Camera unavailable in simulator")
                Text("Run on a real device to scan tools and parts.")
                    .font(OttoFont.body(13))
                    .foregroundStyle(OttoColor.ink3)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
        }
    }
}

// MARK: - PDF page viewer
// Shown when the user taps a citation chip in ActiveSessionView. Displays
// the retrieved PDF page at full size with pinch + double-tap to zoom.

struct OttoPageViewerSheet: View {
    let page: RetrievedPage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Image(uiImage: page.image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { zoom = max(1.0, min($0, 4.0)) }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            zoom = zoom > 1.0 ? 1.0 : 2.0
                        }
                    }
            }
            .background(Color.white)
            .navigationTitle("[\(page.citation)] \(page.source)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("p. \(page.page) · \(String(format: "%.2f", page.score))")
                        .font(OttoFont.mono(10))
                        .foregroundStyle(Color.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    OttoRootView()
        .environmentObject(InferenceController())
}
