import SwiftUI

// Exploded-view page. Placeholder for the interactive 3D part-separation
// workflow — for now, shows the title, a schematic illustration, and the
// shared glass nav bar so navigation remains consistent.

struct ExplodedView: View {
    @EnvironmentObject var store: OttoStore

    var body: some View {
        ZStack {
            OttoAtmosphere()

            VStack(spacing: 0) {
                OttoTopBar(vehicle: "2018 Honda Civic", battery: 96, showWordmark: true)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 6) {
                    OttoEyebrow(text: "Exploded View")
                    Text("Inspect every part,\npulled apart.")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(OttoColor.ink)
                        .kerning(-0.6)
                        .lineSpacing(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 12)

                Spacer()

                // Schematic placeholder — three stacked layered planes to
                // suggest the exploded-parts concept until we wire a real
                // 3D viewer.
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(OttoColor.fog2.opacity(0.25), lineWidth: 1)
                            )
                            .frame(width: 240 - CGFloat(i) * 12, height: 120)
                            .offset(y: CGFloat(i) * -44)
                            .shadow(color: OttoColor.fog2.opacity(0.18), radius: 24, x: 0, y: 10)
                    }
                }
                .frame(height: 240)

                Spacer()

                OttoEyebrow(text: "Coming soon — interactive 3D")
                    .padding(.bottom, 18)

                GlassNavBar(highlighted: .exploded) { ottoNav($0, store: store) }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
            }
        }
    }
}
