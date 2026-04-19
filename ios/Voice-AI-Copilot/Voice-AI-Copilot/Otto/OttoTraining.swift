import SwiftUI

// MARK: - Training
// Canonical entry point for the Training tab. Presents the course list over
// the shared frosted-glass atmosphere; taps open a full-screen AR session.

struct TrainingView: View {
    @EnvironmentObject var store: OttoStore
    @State private var activeCourse: TrainingCourse?

    var body: some View {
        ZStack {
            OttoAtmosphere()

            VStack(spacing: 0) {
                OttoTopBar(vehicle: "2018 Honda Civic", battery: 96)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Training")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(OttoColor.ink)
                        .kerning(-0.6)
                    OttoEyebrow(text: "Practice with AR + voice")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 8)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(TrainingCourse.all) { course in
                            Button { activeCourse = course } label: {
                                courseCard(course)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                }

                GlassNavBar(highlighted: .training) { ottoNav($0, store: store) }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $activeCourse) { course in
            TrainingSessionView(course: course)
        }
    }

    // MARK: - Subviews

    private func courseCard(_ course: TrainingCourse) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(
                        colors: [OttoColor.accentWarm.opacity(0.20), OttoColor.fog1.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: course.iconSystemName)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(OttoColor.accentWarm)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(course.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OttoColor.ink)
                Text(course.subtitle)
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(OttoColor.ink2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(OttoColor.ink3)
                .padding(.top, 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 30/255, green: 44/255, blue: 72/255).opacity(0.45),
                             Color(red: 16/255, green: 26/255, blue: 46/255).opacity(0.65)],
                    startPoint: UnitPoint(x: 0.15, y: 0.0),
                    endPoint: UnitPoint(x: 0.85, y: 1.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OttoColor.fog3.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 8)
    }
}
