import Foundation

// MARK: - cc-switch Locator
// 解析 cc-switch 数据库的实际位置。cc-switch 支持「自定义配置目录」：
// macOS 上覆盖路径写在 Tauri store
//   ~/Library/Application Support/com.ccswitch.desktop/app_paths.json
// 的 app_config_dir_override 键（cc-switch 源码 app_store.rs / config.rs 的解析顺序），
// 未设置时默认 ~/.cc-switch。此前 Claude/Codex/OpenCode 三处同步都硬编码默认路径，
// 用户迁移过配置目录后会读到陈旧库（同步结果为空或过期）。
// 解析优先级：设置页手动指定目录 > app_paths.json 自动探测 > 默认 ~/.cc-switch。

enum CCSwitchLocator {

    /// cc-switch 数据库路径。手动指定目录视为权威（即使 db 缺失也不回退，
    /// 让同步报「数据库不存在」提示用户路径填错）；自动探测则要求 db 存在才生效。
    static func databasePath() -> String {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        if let userDir = userConfigDirOverride() {
            return (userDir as NSString).appendingPathComponent("cc-switch.db")
        }

        if let overrideDir = configDirOverride(home: home) {
            let candidate = (overrideDir as NSString).appendingPathComponent("cc-switch.db")
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return (home as NSString).appendingPathComponent(".cc-switch/cc-switch.db")
    }

    /// 设置页手动指定的 cc-switch 配置目录（仅路径，非凭据，存 UserDefaults）。
    static func userConfigDirOverride() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKey.ccSwitchConfigDirOverride)?.nilIfBlank else {
            return nil
        }
        return (raw as NSString).expandingTildeInPath
    }

    private static func configDirOverride(home: String) -> String? {
        let storePath = (home as NSString).appendingPathComponent(
            "Library/Application Support/com.ccswitch.desktop/app_paths.json")
        guard let data = FileManager.default.contents(atPath: storePath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dir = (json["app_config_dir_override"] as? String)?.nilIfBlank else {
            return nil
        }
        return (dir as NSString).expandingTildeInPath
    }
}
