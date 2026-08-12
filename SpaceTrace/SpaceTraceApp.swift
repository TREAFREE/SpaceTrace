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
                baselineScanModel: appDelegate.baselineScanModel,
                directoryHistoryModel: appDelegate.directoryHistoryModel,
                historicalFindingsModel: appDelegate.historicalFindingsModel,
                diagnosticExportModel: appDelegate.diagnosticExportModel,
                databaseRecoveryModel: appDelegate.databaseRecoveryModel
            )
        }
        .defaultSize(width: 1_080, height: 720)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarStatusView(
                authorizationModel: appDelegate.authorizationModel,
                baselineModel: appDelegate.baselineScanModel,
                statusModel: appDelegate.menuBarStatusModel,
                recoveryModel: appDelegate.databaseRecoveryModel
            )
        } label: {
            Label(
                "SpaceTrace",
                systemImage: MenuBarOperationalState.resolve(
                    storage: appDelegate.menuBarStatusModel.storageState,
                    authorization: appDelegate.authorizationModel.summary,
                    baseline: appDelegate.baselineScanModel.state,
                    recoveryIsActive:
                        appDelegate.databaseRecoveryModel.overview != nil
                ).symbolName
            )
        }
        .menuBarExtraStyle(.window)
    }
}
