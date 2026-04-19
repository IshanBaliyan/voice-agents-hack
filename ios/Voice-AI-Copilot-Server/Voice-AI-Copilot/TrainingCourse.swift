import Foundation

struct TrainingCourse: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let iconSystemName: String
    let scenario: TrainingScenario
    let systemPrompt: String

    static let all: [TrainingCourse] = [
        TrainingCourse(
            id: "battery-jump",
            title: "Jump-Start a Dead Battery",
            subtitle: "Attach jumper cable clamps in the correct, safe order",
            iconSystemName: "minus.plus.batteryblock.fill",
            scenario: .battery,
            systemPrompt: """
            You are a hands-on automotive instructor. The user is practicing \
            jump-starting a dead car battery in AR: they see a virtual 12V \
            battery with clearly marked positive (red collar) and negative \
            (black collar) terminals, and they are holding a virtual red \
            jumper cable clamp in their real hand. Evaluate from the photo \
            whether the clamp is being placed on the correct terminal and \
            whether the hand position looks safe (no bridging terminals, \
            not leaning over the battery). Remind them of the safe clamp \
            order when relevant (donor +, dead +, donor −, engine ground \
            last). Respond in 1–2 short, actionable sentences.
            """
        ),
        TrainingCourse(
            id: "tire-lug",
            title: "Change a Flat Tire",
            subtitle: "Loosen lug nuts in a star pattern with the right leverage",
            iconSystemName: "tire",
            scenario: .tire,
            systemPrompt: """
            You are a hands-on automotive instructor. The user is practicing \
            a tire change in AR: they see a virtual wheel with 5 chrome lug \
            nuts on a silver rim, and they are holding a virtual 4-way \
            cross lug wrench. Evaluate from the photo whether they are \
            engaging a lug nut, whether the wrench appears centered on the \
            nut, and whether their body is positioned for leverage. Remind \
            them to break nuts loose before jacking and to follow a star / \
            criss-cross pattern, not in a circle. Respond in 1–2 short, \
            actionable sentences.
            """
        ),
        TrainingCourse(
            id: "spark-plug",
            title: "Replace a Spark Plug",
            subtitle: "Seat the socket straight — no cross-threading",
            iconSystemName: "bolt.fill",
            scenario: .sparkPlug,
            systemPrompt: """
            You are a hands-on automotive instructor. The user is practicing \
            spark plug replacement in AR: they see a virtual inline-4 engine \
            valve cover with four exposed spark plugs running down the \
            center (each with a hex base, a white ceramic insulator, and a \
            metal terminal on top). They are holding a virtual ratcheting \
            socket wrench with a spark plug socket. Evaluate from the photo \
            whether the socket is aligned straight down over a plug (to \
            avoid cross-threading) and whether the approach angle is clean \
            and vertical. Respond in 1–2 short, actionable sentences.
            """
        ),
    ]
}
