import SwiftUI

// Exploded-view page. Hosts the engine library picker between Otto's top
// bar and the shared glass nav bar. Tapping an engine opens the full
// 3D viewer (EngineDetailView) as a full-screen cover.

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
                .padding(.bottom, 8)

                EnginesPicker()

                GlassNavBar(highlighted: .exploded) { ottoNav($0, store: store) }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
            }
        }
    }
}
