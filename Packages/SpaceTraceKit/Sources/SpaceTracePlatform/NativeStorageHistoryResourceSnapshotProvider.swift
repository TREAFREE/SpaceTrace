import Darwin
import Foundation
import SpaceTraceApplication

public enum NativeStorageHistoryResourceSnapshotError: Error, Equatable {
    case processResourceUnavailable
    case continuousClockUnavailable
    case databaseSizeOverflow
}

public struct NativeStorageHistoryResourceSnapshotProvider:
    StorageHistorySoakResourceSnapshotProviding,
    Sendable
{
    private let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func snapshot() throws -> (
        continuousTimeMilliseconds: Int64,
        resource: StorageHistorySoakResourceSnapshot
    ) {
        (
            continuousTimeMilliseconds: try continuousMilliseconds(),
            resource: StorageHistorySoakResourceSnapshot(
                cumulativeCPUMilliseconds: try cpuMilliseconds(),
                residentMemoryBytes: try residentMemoryBytes(),
                databaseBytes: try databaseBytes()
            )
        )
    }

    private func cpuMilliseconds() throws -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw NativeStorageHistoryResourceSnapshotError
                .processResourceUnavailable
        }
        let user = milliseconds(usage.ru_utime)
        let system = milliseconds(usage.ru_stime)
        let (total, overflow) = user.addingReportingOverflow(system)
        guard overflow == false else {
            throw NativeStorageHistoryResourceSnapshotError
                .processResourceUnavailable
        }
        return total
    }

    private func milliseconds(_ value: timeval) -> Int64 {
        Int64(value.tv_sec) * 1_000 + Int64(value.tv_usec) / 1_000
    }

    private func residentMemoryBytes() throws -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS,
              info.resident_size <= UInt64(Int64.max) else {
            throw NativeStorageHistoryResourceSnapshotError
                .processResourceUnavailable
        }
        return Int64(info.resident_size)
    }

    private func continuousMilliseconds() throws -> Int64 {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS,
              timebase.denom != 0 else {
            throw NativeStorageHistoryResourceSnapshotError
                .continuousClockUnavailable
        }
        let ticks = mach_continuous_time()
        let nanoseconds = ticks.multipliedFullWidth(
            by: UInt64(timebase.numer)
        )
        let divisor = UInt64(timebase.denom) * 1_000_000
        let quotient = divisor.dividingFullWidth(nanoseconds).quotient
        guard quotient <= UInt64(Int64.max) else {
            throw NativeStorageHistoryResourceSnapshotError
                .continuousClockUnavailable
        }
        return Int64(quotient)
    }

    private func databaseBytes() throws -> Int64 {
        let fileManager = FileManager.default
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(
                fileURLWithPath: databaseURL.path + suffix,
                isDirectory: false
            )
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values.fileSize ?? 0)
            let (next, overflow) = total.addingReportingOverflow(size)
            guard overflow == false else {
                throw NativeStorageHistoryResourceSnapshotError
                    .databaseSizeOverflow
            }
            total = next
        }
        return total
    }
}
