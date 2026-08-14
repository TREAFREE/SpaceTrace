import AppKit
import Foundation

@MainActor
protocol DirectorySelecting {
    func selectDirectory() async -> URL?
}

@MainActor
struct SystemDirectoryPicker: DirectorySelecting {
    func selectDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择要由 SpaceTrace 监控的目录")
        panel.message = String(localized: "SpaceTrace 将只读取所选目录中的文件系统元数据。")
        panel.prompt = String(localized: "授权此目录")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false

        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }
}
