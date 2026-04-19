//
//  Voice_AI_CopilotApp.swift
//  Voice-AI-Copilot
//
//  Created by Ishan Baliyan on 2026-04-18.
//

import SwiftUI

@main
struct Voice_AI_CopilotApp: App {
    // One inference controller for the whole app — loading the Gemma weights
    // twice OOMs the phone, so every view shares this. Routes between local
    // (on-device Cactus) and remote (Mac relay) based on AppMode.
    @StateObject private var engine = InferenceController()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(engine)
        }
    }
}
