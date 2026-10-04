import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var character: PetCharacter {
        didSet { defaults.set(character.rawValue, forKey: "character") }
    }
    @Published var workingDirectory: String {
        didSet { defaults.set(workingDirectory, forKey: "workingDirectory") }
    }
    /// Đường dẫn tới `claude`; để trống thì tự dò.
    @Published var claudePath: String {
        didSet { defaults.set(claudePath, forKey: "claudePath") }
    }
    /// Model truyền qua --model; để trống thì dùng mặc định của CLI.
    @Published var model: String {
        didSet { defaults.set(model, forKey: "model") }
    }
    /// Model cho phiên trợ lý; để trống thì dùng `model`.
    @Published var assistantModel: String {
        didSet { defaults.set(assistantModel, forKey: "assistantModel") }
    }
    /// Thư mục "nhà" của trợ lý — nơi phiên trợ lý chạy, chứa CLAUDE.md (trí nhớ) và notes/.
    @Published var assistantFolder: String {
        didSet { defaults.set(assistantFolder, forKey: "assistantFolder") }
    }
    /// Các hồ sơ tài khoản Claude Code (luôn có hồ sơ "Mặc định" = ~/.claude).
    @Published var profiles: [AccountProfile] {
        didSet { defaults.set(try? JSONEncoder().encode(profiles), forKey: "profiles") }
    }
    /// Hồ sơ dùng cho trợ lý và phiên mới.
    @Published var defaultProfileId: UUID {
        didSet { defaults.set(defaultProfileId.uuidString, forKey: "defaultProfileId") }
    }
    /// Trợ lý đọc to câu trả lời.
    @Published var speakReplies: Bool {
        didSet { defaults.set(speakReplies, forKey: "speakReplies") }
    }
    @Published var petSize: Double {
        didSet { defaults.set(petSize, forKey: "petSize") }
    }
    @Published var walkingEnabled: Bool {
        didSet { defaults.set(walkingEnabled, forKey: "walkingEnabled") }
    }
    @Published var sleepAfterMinutes: Double {
        didSet { defaults.set(sleepAfterMinutes, forKey: "sleepAfterMinutes") }
    }

    /// Công tắc tổng cho trợ lý điều khiển máy (chuột, phím, màn hình, script, hệ thống).
    @Published var controlEnabled: Bool {
        didSet { defaults.set(controlEnabled, forKey: ControlPolicy.enabledKey) }
    }
    /// Mức quyền từng nhóm: [ControlGroup.rawValue: ControlMode.rawValue]; thiếu = mặc định của nhóm.
    @Published var controlModes: [String: String] {
        didSet { defaults.set(controlModes, forKey: ControlPolicy.modesKey) }
    }

    func controlMode(_ g: ControlGroup) -> ControlMode {
        controlModes[g.rawValue].flatMap(ControlMode.init) ?? g.defaultMode
    }

    func setControlMode(_ m: ControlMode, for g: ControlGroup) {
        controlModes[g.rawValue] = m.rawValue
    }

    private init() {
        character = PetCharacter(rawValue: defaults.string(forKey: "character") ?? "") ?? .beNon
        workingDirectory = defaults.string(forKey: "workingDirectory") ?? NSHomeDirectory()
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        model = defaults.string(forKey: "model") ?? ""
        assistantModel = defaults.string(forKey: "assistantModel") ?? ""
        assistantFolder = defaults.string(forKey: "assistantFolder") ?? NSHomeDirectory() + "/DeskPet"
        speakReplies = defaults.object(forKey: "speakReplies") as? Bool ?? true
        var loaded = (defaults.data(forKey: "profiles").flatMap { try? JSONDecoder().decode([AccountProfile].self, from: $0) }) ?? []
        if !loaded.contains(where: { $0.id == AccountProfile.systemId }) { loaded.insert(.system, at: 0) }
        profiles = loaded
        defaultProfileId = defaults.string(forKey: "defaultProfileId").flatMap(UUID.init) ?? AccountProfile.systemId
        petSize = defaults.object(forKey: "petSize") as? Double ?? 120
        walkingEnabled = defaults.object(forKey: "walkingEnabled") as? Bool ?? true
        sleepAfterMinutes = defaults.object(forKey: "sleepAfterMinutes") as? Double ?? 2
        controlEnabled = defaults.object(forKey: ControlPolicy.enabledKey) as? Bool ?? true
        controlModes = defaults.dictionary(forKey: ControlPolicy.modesKey) as? [String: String] ?? [:]
        migrateLegacySession()
    }

    /// session_id gần nhất của từng thư mục: --resume chỉ tìm thấy session trong đúng project đó.
    private var sessionsByFolder: [String: String] {
        get { defaults.dictionary(forKey: "sessionsByFolder") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "sessionsByFolder") }
    }

    func profile(_ id: UUID?) -> AccountProfile {
        profiles.first { $0.id == (id ?? defaultProfileId) } ?? profiles.first { $0.id == defaultProfileId } ?? .system
    }

    var defaultProfile: AccountProfile { profile(defaultProfileId) }

    /// Tìm hồ sơ theo tên (không phân biệt hoa thường) — cho trợ lý.
    func profile(named name: String) -> AccountProfile? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return profiles.first { $0.name.lowercased() == n } ?? profiles.first { $0.name.lowercased().contains(n) }
    }

    func sessionId(for folder: String) -> String? {
        sessionsByFolder[SessionHistory.normalize(folder)]
    }

    func setSessionId(_ id: String?, for folder: String) {
        var map = sessionsByFolder
        map[SessionHistory.normalize(folder)] = id
        sessionsByFolder = map
    }

    /// Chuyển dữ liệu từ bản cũ (chỉ nhớ một session).
    private func migrateLegacySession() {
        guard !defaults.bool(forKey: "migratedSessions") else { return }
        defaults.set(true, forKey: "migratedSessions")
        if let id = defaults.string(forKey: "sessionId"), let cwd = defaults.string(forKey: "sessionCwd") {
            setSessionId(id, for: cwd)
        }
    }
}
