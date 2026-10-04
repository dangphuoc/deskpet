import AppKit

enum PetCharacter: String, CaseIterable, Identifiable {
    case beNon = "be_non"
    case dom = "dom"
    case lacLac = "lac_lac"
    case ngheO = "nghe_o"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .beNon: return "Bé Nón"
        case .dom: return "Đom"
        case .lacLac: return "Lạc Lạc"
        case .ngheO: return "Nghé Ơ"
        }
    }

    /// Hướng nhân vật đang nhìn trong ảnh "di_chuyen" — để lật ảnh đúng chiều khi đi dạo.
    var walkFacing: Facing {
        switch self {
        case .beNon: return .front
        case .dom, .lacLac: return .left
        case .ngheO: return .right
        }
    }

    enum Facing { case left, right, front }
}

enum Pose: String, CaseIterable {
    case standing = "cam_do"
    case pointing = "chi_tay"
    case laughing = "cuoi"
    case moving = "di_chuyen"
    case sitting = "ngoi"
    case talking = "noi"
    case oops = "sai_roi"
    case inspecting = "soi_kinh"
}

enum CharacterLibrary {
    private static var cache: [String: NSImage] = [:]

    static let baseURL: URL? = {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Characters"),
           FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        // Chạy bằng `swift run`: lấy thẳng từ thư mục Resources của repo.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Characters")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }()

    static func image(_ character: PetCharacter, _ pose: Pose) -> NSImage? {
        let key = "\(character.rawValue)/\(pose.rawValue)"
        if let img = cache[key] { return img }
        guard let url = baseURL?.appendingPathComponent(key + ".png"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[key] = img
        return img
    }
}
