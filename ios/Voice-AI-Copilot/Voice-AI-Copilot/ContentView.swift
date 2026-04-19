import SwiftUI

private enum SpotifyPalette {
    static let background = Color.black
    static let card = Color(red: 0.11, green: 0.11, blue: 0.11)       // #1C1C1C
    static let field = Color(red: 0.18, green: 0.18, blue: 0.18)      // #2E2E2E
    static let accent = Color(red: 0.114, green: 0.725, blue: 0.329)  // #1DB954
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.7)
    static let danger = Color(red: 0.95, green: 0.3, blue: 0.3)
}

struct ContentView: View {
    var body: some View {
        OttoRootView()
    }
}

#Preview {
    ContentView()
        .environmentObject(InferenceController())
}
