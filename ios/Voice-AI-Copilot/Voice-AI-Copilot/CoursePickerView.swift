import SwiftUI

private enum PickerPalette {
    static let background = Color.black
    static let card = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let accent = Color(red: 0.114, green: 0.725, blue: 0.329)
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.7)
}

struct CoursePickerView: View {
    @State private var activeCourse: TrainingCourse?

    var body: some View {
        NavigationStack {
            ZStack {
                PickerPalette.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        ForEach(TrainingCourse.all) { course in
                            Button { activeCourse = course } label: {
                                courseCard(course)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
            .preferredColorScheme(.dark)
            .navigationBarHidden(true)
            .fullScreenCover(item: $activeCourse) { course in
                TrainingSessionView(course: course)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Training")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(PickerPalette.primaryText)
                .kerning(-0.5)
            Text("Practice hands-on repair with AR + your voice coach")
                .font(.footnote)
                .foregroundStyle(PickerPalette.secondaryText)
        }
    }

    private func courseCard(_ course: TrainingCourse) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(PickerPalette.accent.opacity(0.18))
                    .frame(width: 58, height: 58)
                Image(systemName: course.iconSystemName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(PickerPalette.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(course.title)
                    .font(.headline)
                    .foregroundStyle(PickerPalette.primaryText)
                Text(course.subtitle)
                    .font(.footnote)
                    .foregroundStyle(PickerPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(PickerPalette.secondaryText)
        }
        .padding(16)
        .background(PickerPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
