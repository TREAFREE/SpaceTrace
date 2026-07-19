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
            ContentView(model: appDelegate.authorizationModel)
        }
        .defaultSize(width: 640, height: 460)
    }
}
