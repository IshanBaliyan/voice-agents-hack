import SwiftUI

struct ContentView: View {
    var body: some View {
        OttoRootView()
    }
}

#Preview {
    ContentView()
        .environmentObject(CactusEngine())
}
