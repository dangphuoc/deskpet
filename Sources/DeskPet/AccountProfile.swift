import Foundation

/// Hồ sơ tài khoản Claude Code = một thư mục cấu hình (CLAUDE_CONFIG_DIR) với đăng nhập, settings,
/// skills, lịch sử phiên riêng. Hồ sơ "Mặc định" dùng ~/.claude như khi gõ `claude` bình thường.
struct AccountProfile: Codable, Identifiable, Hashable {
    static let systemId = UUID(uuidString: "00000000-0000-0000-0000-0000000C1A0D")!
    static let system = AccountProfile(id: systemId, name: "Mặc định", configDir: "")

    var id: UUID
    var name: String
    /// Rỗng = ~/.claude (không đặt CLAUDE_CONFIG_DIR).
    var configDir: String

    var isSystem: Bool { configDir.isEmpty }
    var displayDir: String { isSystem ? "~/.claude" : configDir }

    /// Đường dẫn thật tới thư mục cấu hình.
    var rootPath: String {
        (isSystem ? NSHomeDirectory() + "/.claude" : (configDir as NSString).expandingTildeInPath)
    }

    /// Giá trị CLAUDE_CONFIG_DIR cần đặt (nil với hồ sơ mặc định).
    var envConfigDir: String? { isSystem ? nil : rootPath }
}
