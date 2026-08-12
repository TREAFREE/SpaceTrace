import AppKit
import UniformTypeIdentifiers

@MainActor
final class SystemDiagnosticExportDestinationSelector:
    DiagnosticExportDestinationSelecting
{
    private weak var activePanel: NSSavePanel?

    func selectDestination(suggestedFileName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "导出 SpaceTrace 诊断信息")
        panel.message = String(localized: "文件只会保存到你选择的位置，不会自动上传。")
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.json]
        activePanel = panel
        defer { activePanel = nil }
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    func cancel() {
        activePanel?.cancel(nil)
    }
}
