import SwiftUI
@preconcurrency import WebKit

// Manual tab. Pulls the owner's manual for whatever vehicle the user entered
// in onboarding by loading a Google search for "<year> <make> <model> owner's
// manual pdf" inside an embedded WKWebView. Using search (instead of trying
// to scrape a direct PDF URL) keeps this robust across arbitrary makes and
// models without any API keys.
//
// If the user skipped onboarding we show an empty-state with a CTA back to
// the car-info form.
struct ManualView: View {
    @EnvironmentObject var store: OttoStore
    @ObservedObject private var profiles = CarProfileStore.shared

    var body: some View {
        ZStack {
            OttoAtmosphere()

            VStack(spacing: 0) {
                OttoTopBar(vehicle: profiles.profile?.display ?? "No vehicle set",
                           battery: 96)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Manual")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(OttoColor.ink)
                        .kerning(-0.6)
                    OttoEyebrow(text: profiles.profile?.display ?? "Owner's manual")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 12)

                content
                    .padding(.horizontal, 14)

                GlassNavBar(highlighted: .manual) { ottoNav($0, store: store) }
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let profile = profiles.profile, let url = profile.manualSearchURL {
            ManualWebView(url: url)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(OttoColor.fog3.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 16)
                .frame(maxHeight: .infinity)
        } else {
            emptyState
                .frame(maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(OttoColor.ink3)
            Text("No vehicle on file")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(OttoColor.ink)
            Text("Tell Otto your make, model, and year\nand we'll pull the owner's manual.")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(OttoColor.ink3)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button {
                store.go(.onboardingCar)
            } label: {
                Text("Add your car")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OttoColor.bg0)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [OttoColor.accentWarm, OttoColor.fog2],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .shadow(color: OttoColor.accentWarm.opacity(0.35), radius: 16, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}

private struct ManualWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
}
