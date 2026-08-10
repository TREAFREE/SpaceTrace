import Foundation
import Testing
@testable import SpaceTraceQualification

@Suite("Activity Monitor Instruments evidence")
struct InstrumentsActivityMonitorReportTests {
    @Test("Resolves xctrace references and aggregates bounded slices")
    func aggregatesSlices() throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeSlice(
            to: directory,
            index: 1,
            offset: 0,
            firstCPU: 100_000_000,
            lastCPU: 250_000_000,
            firstWakeups: 10,
            lastWakeups: 13,
            firstWrites: 1_000,
            lastWrites: 1_400,
            firstReads: 500,
            lastReads: 700,
            maximumMemory: 60_000_000,
            cpuPercent: 0.1,
            appNap: true
        )
        try writeSlice(
            to: directory,
            index: 2,
            offset: 21_600,
            firstCPU: 1_000_000_000,
            lastCPU: 1_150_000_000,
            firstWakeups: 20,
            lastWakeups: 22,
            firstWrites: 4_000,
            lastWrites: 4_300,
            firstReads: 2_000,
            lastReads: 2_100,
            maximumMemory: 55_000_000,
            cpuPercent: 0.2,
            appNap: false
        )

        let report = try InstrumentsActivityMonitorAnalyzer().analyze(
            directory: directory
        )

        #expect(report.schemaVersion == 1)
        #expect(report.sliceCount == 2)
        #expect(report.totalCPUTimeNanoseconds == 300_000_000)
        #expect(report.totalIdleWakeups == 5)
        #expect(report.totalDiskBytesWritten == 700)
        #expect(report.totalDiskBytesRead == 300)
        #expect(report.maximumPhysicalFootprintBytes == 60_000_000)
        #expect(report.appNapSliceCount == 1)
        #expect(report.preventingSleepObserved == false)
        #expect(report.thermalStates == ["Nominal"])
        #expect(report.minimumSliceMeanCPUPercent == 0.1)
        #expect(report.maximumSliceMeanCPUPercent == 0.2)
        #expect(report.maximumInstantaneousCPUPercent == 0.2)
        #expect(report.slices.map(\.sliceID) == [
            "01-offset-000000",
            "02-offset-021600",
        ])

        let encoded = try JSONEncoder().encode(report)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        for forbidden in [
            "/Users/",
            "bookmark",
            "volumeUUID",
            "availableBytes",
            "commandLine",
            "fileName",
        ] {
            #expect(encodedText.contains(forbidden) == false)
        }
        #expect(
            try JSONDecoder().decode(
                InstrumentsActivityMonitorReport.self,
                from: encoded
            ) == report
        )
    }

    @Test("Fails closed when an exported companion table is missing")
    func rejectsMissingThermalTable() throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeSlice(
            to: directory,
            index: 1,
            offset: 0,
            firstCPU: 0,
            lastCPU: 1,
            firstWakeups: 0,
            lastWakeups: 1,
            firstWrites: 0,
            lastWrites: 1,
            firstReads: 0,
            lastReads: 1,
            maximumMemory: 1,
            cpuPercent: 0,
            appNap: false
        )
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(
                "activity-monitor-01-offset-000000-thermal.xml"
            )
        )

        #expect(throws: InstrumentsActivityMonitorAnalysisError.self) {
            try InstrumentsActivityMonitorAnalyzer().analyze(
                directory: directory
            )
        }
    }

    @Test("Fails closed when a cumulative process counter regresses")
    func rejectsCounterRegression() throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeSlice(
            to: directory,
            index: 1,
            offset: 0,
            firstCPU: 200,
            lastCPU: 100,
            firstWakeups: 2,
            lastWakeups: 1,
            firstWrites: 2,
            lastWrites: 1,
            firstReads: 2,
            lastReads: 1,
            maximumMemory: 1,
            cpuPercent: 0,
            appNap: false
        )

        #expect(throws: InstrumentsActivityMonitorAnalysisError.self) {
            try InstrumentsActivityMonitorAnalyzer().analyze(
                directory: directory
            )
        }
    }

    private func makeFixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func writeSlice(
        to directory: URL,
        index: Int,
        offset: Int,
        firstCPU: Int64,
        lastCPU: Int64,
        firstWakeups: Int64,
        lastWakeups: Int64,
        firstWrites: Int64,
        lastWrites: Int64,
        firstReads: Int64,
        lastReads: Int64,
        maximumMemory: Int64,
        cpuPercent: Double,
        appNap: Bool
    ) throws {
        let prefix = String(
            format: "activity-monitor-%02d-offset-%06d",
            index,
            offset
        )
        try ledgerXML(
            cpu: lastCPU,
            wakeups: lastWakeups,
            writes: lastWrites,
            reads: lastReads
        ).write(
            to: directory.appendingPathComponent("\(prefix)-ledger.xml"),
            atomically: true,
            encoding: .utf8
        )
        try liveXML(
            firstCPU: firstCPU,
            lastCPU: lastCPU,
            firstWakeups: firstWakeups,
            lastWakeups: lastWakeups,
            firstWrites: firstWrites,
            lastWrites: lastWrites,
            firstReads: firstReads,
            lastReads: lastReads,
            maximumMemory: maximumMemory,
            cpuPercent: cpuPercent,
            appNap: appNap
        ).write(
            to: directory.appendingPathComponent("\(prefix)-live.xml"),
            atomically: true,
            encoding: .utf8
        )
        try thermalXML.write(
            to: directory.appendingPathComponent("\(prefix)-thermal.xml"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func ledgerXML(
        cpu: Int64,
        wakeups: Int64,
        writes: Int64,
        reads: Int64
    ) -> String {
        """
        <?xml version="1.0"?>
        <trace-query-result><node><schema name="activity-monitor-process-ledger">
        <col><mnemonic>process</mnemonic></col>
        <col><mnemonic>cpu-total</mnemonic></col>
        <col><mnemonic>idle-wakeups</mnemonic></col>
        <col><mnemonic>disk-bytes-written</mnemonic></col>
        <col><mnemonic>disk-bytes-read</mnemonic></col>
        </schema><row>
        <process id="l1" fmt="SpaceTrace (42)"><pid>42</pid></process>
        <duration-on-core id="l2">\(cpu)</duration-on-core>
        <event-count id="l3">\(wakeups)</event-count>
        <size-in-bytes id="l4">\(writes)</size-in-bytes>
        <size-in-bytes id="l5">\(reads)</size-in-bytes>
        </row></node></trace-query-result>
        """
    }

    private func liveXML(
        firstCPU: Int64,
        lastCPU: Int64,
        firstWakeups: Int64,
        lastWakeups: Int64,
        firstWrites: Int64,
        lastWrites: Int64,
        firstReads: Int64,
        lastReads: Int64,
        maximumMemory: Int64,
        cpuPercent: Double,
        appNap: Bool
    ) -> String {
        let appNapValue = appNap ? 1 : 0
        return """
        <?xml version="1.0"?>
        <trace-query-result><node><schema name="activity-monitor-process-live">
        <col><mnemonic>start</mnemonic></col>
        <col><mnemonic>process</mnemonic></col>
        <col><mnemonic>pid</mnemonic></col>
        <col><mnemonic>duration</mnemonic></col>
        <col><mnemonic>cpu-percent</mnemonic></col>
        <col><mnemonic>cpu-total</mnemonic></col>
        <col><mnemonic>idle-wakeups</mnemonic></col>
        <col><mnemonic>memory-physical-footprint</mnemonic></col>
        <col><mnemonic>disk-bytes-written</mnemonic></col>
        <col><mnemonic>disk-bytes-read</mnemonic></col>
        <col><mnemonic>app-nap</mnemonic></col>
        <col><mnemonic>preventing-sleep</mnemonic></col>
        </schema>
        <row>
        <start-time id="s1">0</start-time>
        <process id="p1" fmt="SpaceTrace (42)"><pid id="pid1">42</pid></process>
        <pid ref="pid1"/>
        <duration id="d1">1000000000</duration>
        <sentinel/>
        <duration-on-core id="c1">\(firstCPU)</duration-on-core>
        <event-count id="w1">\(firstWakeups)</event-count>
        <size-in-bytes id="m1">\(maximumMemory - 1)</size-in-bytes>
        <disk-size-in-bytes id="dw1">\(firstWrites)</disk-size-in-bytes>
        <disk-size-in-bytes id="dr1">\(firstReads)</disk-size-in-bytes>
        <boolean id="b0">0</boolean>
        <boolean ref="b0"/>
        </row>
        <row>
        <start-time id="s2">1000000000</start-time>
        <process ref="p1"/>
        <pid ref="pid1"/>
        <duration ref="d1"/>
        <system-cpu-percent id="cp2">\(cpuPercent)</system-cpu-percent>
        <duration-on-core id="c2">\(lastCPU)</duration-on-core>
        <event-count id="w2">\(lastWakeups)</event-count>
        <size-in-bytes id="m2">\(maximumMemory)</size-in-bytes>
        <disk-size-in-bytes id="dw2">\(lastWrites)</disk-size-in-bytes>
        <disk-size-in-bytes id="dr2">\(lastReads)</disk-size-in-bytes>
        <boolean id="bn">\(appNapValue)</boolean>
        <boolean ref="b0"/>
        </row>
        </node></trace-query-result>
        """
    }

    private var thermalXML: String {
        """
        <?xml version="1.0"?>
        <trace-query-result><node><schema name="device-thermal-state-intervals">
        <col><mnemonic>start</mnemonic></col>
        <col><mnemonic>duration</mnemonic></col>
        <col><mnemonic>thermal-state</mnemonic></col>
        </schema><row>
        <start-time>0</start-time>
        <duration>300000000000</duration>
        <thermal-state id="t1" fmt="Nominal">Nominal</thermal-state>
        </row></node></trace-query-result>
        """
    }
}
