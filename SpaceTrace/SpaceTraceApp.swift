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
        Window("SpaceTrace", id: "main") {
            ContentView(
                authorizationModel: appDelegate.authorizationModel,
                baselineScanModel: appDelegate.baselineScanModel
            )
        }
        .defaultSize(width: 920, height: 620)
        .windowToolbarStyle(.unified)

        MenuBarExtra("SpaceTrace", systemImage: "externaldrive") {
            MenuBarStatusView(model: appDelegate.authorizationModel)
        }
        .menuBarExtraStyle(.window)
    }
}
