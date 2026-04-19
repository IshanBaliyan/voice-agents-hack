import SwiftUI

struct OttoSplashView: View {
    var onFinish: () -> Void

    @State private var appeared = false
    @State private var fadeOut = false

    var body: some View {
        ZStack {
            // Same background as the mic page.
            OttoBackground()

            VStack(spacing: 0) {
                Spacer().frame(height: 80)

                HStack(alignment: .top, spacing: 4) {
                    Text("Otto")
                        .font(OttoFont.serif(54, weight: .light))
                        .foregroundStyle(OttoColor.cream)
                    Circle()
                        .fill(OttoColor.orange)
                        .frame(width: 10, height: 10)
                        .offset(y: 22)
                        .shadow(color: OttoColor.orange.opacity(0.6), radius: 6)
                }

                Text("YOUR POCKET MECHANIC")
                    .font(OttoFont.mono(11, weight: .regular))
                    .tracking(3.2)
                    .foregroundStyle(OttoColor.creamDim)
                    .padding(.top, 6)

                Spacer().frame(height: 30)

                Image("OttoSplash")
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 36)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.98)

                Spacer()
            }
            .opacity(appeared ? 1 : 0)
        }
        .opacity(fadeOut ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { appeared = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                withAnimation(.easeInOut(duration: 0.5)) { fadeOut = true }
                try? await Task.sleep(nanoseconds: 500_000_000)
                onFinish()
            }
        }
    }
}

#Preview { OttoSplashView(onFinish: {}) }
