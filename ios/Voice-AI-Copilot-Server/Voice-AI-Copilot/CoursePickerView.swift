import SwiftUI

struct CoursePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var activeCourse: TrainingCourse?

    var body: some View {
        NavigationStack {
            ZStack {
                OttoBackground()

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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(OttoColor.cream)
                            .padding(10)
                            .background(OttoColor.navy.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $activeCourse) { course in
                TrainingSessionView(course: course)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                Text("Training")
                    .font(OttoFont.serif(34, weight: .light))
                    .foregroundStyle(OttoColor.cream)
                Circle().fill(OttoColor.orange)
                    .frame(width: 7, height: 7)
                    .offset(y: 14)
            }
            Label2Mono(text: "Hands-on repair with AR + your voice coach")
        }
        .padding(.top, 8)
    }

    private func courseCard(_ course: TrainingCourse) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OttoColor.orange.opacity(0.18))
                    .frame(width: 58, height: 58)
                Image(systemName: course.iconSystemName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(OttoColor.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(course.title)
                    .font(OttoFont.serif(18, weight: .regular))
                    .foregroundStyle(OttoColor.cream)
                Text(course.subtitle)
                    .font(OttoFont.body(13))
                    .foregroundStyle(OttoColor.creamDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OttoColor.creamFaint)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OttoColor.navy.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(OttoColor.hairline, lineWidth: 1)
        )
    }
}
