//
//  PushUpApp.swift
//  PushUp
//
//  Created by sangmin han on 4/7/26.
//

import SwiftUI
import SwiftData

@main
struct PushUpApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            AppState.self,
            WorkoutCompletion.self
        ])
    }
}
