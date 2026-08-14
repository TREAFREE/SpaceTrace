import Foundation

public struct DiagnosticExportWriteReceipt: Sendable, Equatable {
    public let destinationURL: URL
    public let byteCount: Int

    public init(destinationURL: URL, byteCount: Int) {
        self.destinationURL = destinationURL
        self.byteCount = byteCount
    }
}

public protocol DiagnosticExportWriting: Sendable {
    func write(
        _ export: PreparedDiagnosticExport,
        to destinationURL: URL
    ) async throws -> DiagnosticExportWriteReceipt

    /// Removes only incomplete files owned by the diagnostic export writer.
    /// Unknown files and symbolic links must remain untouched.
    func recoverInterruptedExports() async throws -> Int
}
