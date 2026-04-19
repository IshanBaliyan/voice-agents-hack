import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            ContentView()
                .tabItem {
                    Label("Copilot", systemImage: "mic.fill")
                }

            CoursePickerView()
                .tabItem {
                    Label("Training", systemImage: "wrench.and.screwdriver.fill")
                }

            EnginesView()
                .tabItem {
                    Label("Engines", systemImage: "gearshape.2.fill")
                }
        }
        .tint(Color(red: 0.114, green: 0.725, blue: 0.329))
    }
}

#Preview {
    MainTabView()
        .environmentObject(InferenceController())
}
