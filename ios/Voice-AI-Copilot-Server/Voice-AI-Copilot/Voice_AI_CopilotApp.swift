//
//  Voice_AI_CopilotApp.swift
//  Voice-AI-Copilot
//
//  Created by Ishan Baliyan on 2026-04-18.
//

import SwiftUI

@main
struct Voice_AI_CopilotApp: App {
    // One engine for the whole app — OttoRootView and the Training sheet both
    // read it via @EnvironmentObject, and a second CactusEngine would open a
    // second WebSocket to the server and fight over its pending-audio buffer.
    @StateObject private var engine = CactusEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
        }
    }
}
