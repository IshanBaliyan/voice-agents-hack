import Foundation
import SwiftUI

// Local  = on-device Gemma 4 E2B via Cactus, with Gemini cloud fallback for
//          structured repair-guide JSON (already wired in GemmaInstructionService).
// Remote = relay voice/image turns to a Mac server running the larger E4B model
//          over WebSocket. Matches the changmin-test-ios-app protocol.
enum AppMode: String, CaseIterable, Codable, Identifiable {
    case local
    case remote

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:  return "On-device (E2B)"
        case .remote: return "Mac relay (E4B)"
        }
    }
}

enum AppModeDefaults {
    static let storageKey = "app.mode"
    static let relayURLKey = "app.relay.url"

    // Single source of truth for the Mac relay URL. Swap when the tunnel
    // changes. Matches cactus_server/relay.py's /ws endpoint; the
    // `audio_format=pcm16_base64` query param tells the relay how the client
    // will encode mic PCM.
    static let fallbackRelayURL = "wss://4e0b-50-175-245-62.ngrok-free.app/ws?audio_format=pcm16_base64"
}
