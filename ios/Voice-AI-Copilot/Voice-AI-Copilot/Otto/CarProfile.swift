import Foundation
import Combine

// Persisted vehicle the user entered during onboarding. Drives the Manual tab
// (Google-search lookup for the owner's manual) and the "vehicle" pill in the
// top bar. Skipping onboarding leaves `profile == nil` but still flips the
// onboarding-complete flag so we don't nag every launch.
struct CarProfile: Codable, Equatable {
    var make: String
    var model: String
    var year: String

    var display: String {
        "\(year) \(make) \(model)".trimmingCharacters(in: .whitespaces)
    }

    /// Google search URL that lands on the owner's manual for this vehicle.
    /// Using a search URL instead of a single scraped PDF makes the Manual tab
    /// robust to arbitrary makes/models without needing a crawler or API key.
    var manualSearchURL: URL? {
        let q = "\(display) owner's manual pdf"
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        return comps.url
    }
}

@MainActor
final class CarProfileStore: ObservableObject {
    static let shared = CarProfileStore()

    @Published private(set) var profile: CarProfile?
    @Published private(set) var onboardingComplete: Bool

    private let profileKey = "otto.carProfile.v1"
    private let onboardingKey = "otto.carProfile.onboardingComplete.v1"

    private init() {
        let d = UserDefaults.standard
        self.onboardingComplete = d.bool(forKey: onboardingKey)
        if let data = d.data(forKey: profileKey),
           let decoded = try? JSONDecoder().decode(CarProfile.self, from: data) {
            self.profile = decoded
        }
    }

    func save(_ profile: CarProfile) {
        self.profile = profile
        self.onboardingComplete = true
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profile) {
            d.set(data, forKey: profileKey)
        }
        d.set(true, forKey: onboardingKey)
    }

    func skip() {
        onboardingComplete = true
        UserDefaults.standard.set(true, forKey: onboardingKey)
    }

    func reset() {
        profile = nil
        onboardingComplete = false
        let d = UserDefaults.standard
        d.removeObject(forKey: profileKey)
        d.removeObject(forKey: onboardingKey)
    }
}
