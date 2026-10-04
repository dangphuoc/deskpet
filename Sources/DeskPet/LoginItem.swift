import Foundation
import ServiceManagement

/// Bật/tắt "Mở khi đăng nhập" (System Settings → General → Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Đang chạy từ /Applications chưa — login item nên trỏ vào bản cài, không phải bản trong build/.
    static var isInstalled: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// Trả về thông báo lỗi (nếu có).
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
