import SwiftUI
#if os(iOS)
import UIKit
#endif

// Onboarding form shown right after the landing page. Collects make, model,
// year so the Manual tab can fetch the right owner's manual. Users who don't
// want to hand over car details can Skip and still get into the app.
struct OnboardingCarView: View {
    @EnvironmentObject var store: OttoStore
    @ObservedObject private var profiles = CarProfileStore.shared

    @State private var make: String = ""
    @State private var model: String = ""
    @State private var year: String = ""
    @FocusState private var focused: Field?

    private enum Field { case make, model, year }

    private var canContinue: Bool {
        !make.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && !year.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            OttoAtmosphere()

            VStack(spacing: 0) {
                OttoTopBar(vehicle: "New driver", battery: 100, showWordmark: true)
                    .padding(.top, 4)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                            .padding(.top, 12)

                        OttoCard(padding: 20, corner: 26) {
                            VStack(alignment: .leading, spacing: 18) {
                                OttoEyebrow(text: "Your vehicle")

                                field(label: "Make",  text: $make,  placeholder: "Honda",       field: .make,  next: .model)
                                field(label: "Model", text: $model, placeholder: "Civic EX",    field: .model, next: .year)
                                field(label: "Year",  text: $year,  placeholder: "2018",        field: .year,  next: nil, keyboard: .numberPad)
                            }
                        }

                        OttoEyebrow(text: "We'll pull your owner's manual and keep it in the Manual tab.")
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)

                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                }

                actionRow
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
            }
        }
        .onTapGesture { focused = nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tell Otto about your car")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(OttoColor.ink)
                .kerning(-0.6)
            Text("Make, model, and year — that's all it takes.")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(OttoColor.ink2)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func field(label: String,
                       text: Binding<String>,
                       placeholder: String,
                       field: Field,
                       next: Field?,
                       keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OttoEyebrow(text: label, color: OttoColor.ink3)
            TextField("", text: text, prompt:
                Text(placeholder)
                    .foregroundStyle(OttoColor.ink4)
            )
            .textInputAutocapitalization(keyboard == .numberPad ? .never : .words)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .focused($focused, equals: field)
            .submitLabel(next == nil ? .done : .next)
            .onSubmit {
                if let next { focused = next } else { focused = nil }
            }
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(OttoColor.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(focused == field ? OttoColor.fog2.opacity(0.55)
                                             : OttoColor.fog3.opacity(0.12),
                            lineWidth: 1)
            )
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                profiles.skip()
                store.go(.session)
            } label: {
                OttoChip(text: "Skip for now")
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                let trimmed = CarProfile(
                    make: make.trimmingCharacters(in: .whitespaces),
                    model: model.trimmingCharacters(in: .whitespaces),
                    year: year.trimmingCharacters(in: .whitespaces)
                )
                profiles.save(trimmed)
                store.go(.manual)
            } label: {
                Text("Save & view manual")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(canContinue ? OttoColor.bg0 : OttoColor.ink3)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(canContinue
                            ? LinearGradient(colors: [OttoColor.accentWarm, OttoColor.fog2],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [OttoColor.fog3.opacity(0.14),
                                                       OttoColor.fog3.opacity(0.10)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(Capsule().stroke(OttoColor.fog2.opacity(canContinue ? 0.6 : 0.15),
                                              lineWidth: 1))
                    .shadow(color: canContinue ? OttoColor.accentWarm.opacity(0.35) : .clear,
                            radius: canContinue ? 16 : 0, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .disabled(!canContinue)
        }
    }
}
