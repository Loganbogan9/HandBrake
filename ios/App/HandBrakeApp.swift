/* This file is part of HandBrake. Licensed under GPL-2.0-or-later. */

import SwiftUI

@main
struct HandBrakeApp: App {
    @StateObject private var model = HandBrakeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    model.handleScenePhase(phase)
                }
        }
    }
}
