import Foundation

// MARK: - Config Models

struct Config: Codable {
    let workspaces: [WorkspaceConfig]
}

struct WorkspaceConfig: Codable {
    let name: String
    let placements: [PlacementConfig]
    let boards: [BoardConfig]
}

struct PlacementConfig: Codable {
    let virtualMonitor: String
    let left: String    // e.g. "0%", "50%"
    let top: String     // e.g. "0%", "50%"
    let width: String   // e.g. "100%", "50%"
    let height: String  // e.g. "100%", "50%"

    enum CodingKeys: String, CodingKey {
        case virtualMonitor = "virtual_monitor"
        case left, top, width, height
    }
}

struct BoardConfig: Codable {
    let name: String
    let slots: [SlotConfig]
}

struct SlotConfig: Codable {
    let left: String
    let top: String
    let width: String
    let height: String
    let appId: String?
    let titleMatch: String?

    enum CodingKeys: String, CodingKey {
        case left, top, width, height
        case appId = "app_id"
        case titleMatch = "title_match"
    }
}

// MARK: - Resolved runtime models

struct ResolvedSlot {
    let appId: String?
    let titleMatch: String?
    let frame: CGRect  // absolute screen coordinates
}

func parsePercent(_ s: String) -> Double? {
    guard s.hasSuffix("%"), let val = Double(s.dropLast()) else { return nil }
    return val / 100.0
}

func loadConfig(from path: String) throws -> Config {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decoder = JSONDecoder()
    return try decoder.decode(Config.self, from: data)
}
