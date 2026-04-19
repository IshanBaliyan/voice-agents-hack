//
//  Voice_AI_CopilotApp.swift
//  Voice-AI-Copilot
//
//  Created by Ishan Baliyan on 2026-04-18.
//

import SwiftUI

@main
struct Voice_AI_CopilotApp: App {
    // One model instance for the whole app — loading the Gemma weights twice
    // OOMs the phone, so ContentView and the Training tab share this.
    @StateObject private var engine = CactusEngine()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(engine)
        }
    }
}
