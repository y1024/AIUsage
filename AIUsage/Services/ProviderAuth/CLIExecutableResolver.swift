import Foundation

func aiusageDefaultCLIPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let segments = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "\(home)/.local/bin",
        "\(home)/bin",
        "\(home)/.cargo/bin"
    ]

    var seen = Set<String>()
    return segments.filter { seen.insert($0).inserted }.joined(separator: ":")
}

func aiusageResolvedExecutable(named executable: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "/opt/homebrew/bin/\(executable)",
        "/usr/local/bin/\(executable)",
        "/usr/bin/\(executable)",
        "/bin/\(executable)",
        "\(home)/.local/bin/\(executable)",
        "\(home)/bin/\(executable)",
        "\(home)/.cargo/bin/\(executable)"
    ]

    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }

    return nil
}
