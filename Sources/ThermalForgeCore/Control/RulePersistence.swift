import Foundation

public enum RulePersistence {
    public static var filePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/rules.json")
    }

    public static func load() -> [ThermalRule] {
        guard FileManager.default.fileExists(atPath: filePath.path) else { return [] }
        guard let data = try? Data(contentsOf: filePath) else { return [] }
        return (try? JSONDecoder().decode([ThermalRule].self, from: data)) ?? []
    }

    public static func save(_ rules: [ThermalRule]) throws {
        let dir = filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try data.write(to: filePath)
    }
}
