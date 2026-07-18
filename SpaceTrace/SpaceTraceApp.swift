//
//  SpaceTraceApp.swift
//  SpaceTrace
//
//  Created by ma yue on 7/18/26.
//

import SwiftUI

@main
struct SpaceTraceApp: App {
    @NSApplicationDelegateAdaptor(SpaceTraceAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
