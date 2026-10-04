# DeskPet — ghi chú cho Claude

App macOS (Swift, AppKit + SwiftUI) — linh vật nổi trên màn hình làm giao diện cho Claude Code CLI:
bảng nhiều phiên, trợ lý giọng nói tiếng Việt có MCP server riêng, điều khiển máy, theo dõi phiên chạy ngoài DeskPet.
Chi tiết tính năng cho người dùng: `README.md`. Người dùng nói tiếng Việt — trả lời bằng tiếng Việt.

## Setup trên máy mới (làm giúp người dùng theo thứ tự)

1. Kiểm tra: `xcode-select -p` (cần Command Line Tools), `which claude` (Claude Code đã cài + đăng nhập).
2. `./build.sh install` — build, chép vào `/Applications/DeskPet.app`, mở app. Không cần Xcode.
3. Nếu macOS báo "Apple could not verify DeskPet": không phải malware (ký ad-hoc). Hướng dẫn
   System Settings → Privacy & Security → **Open Anyway**, hoặc `xattr -dr com.apple.quarantine /Applications/DeskPet.app`.
4. Nhắc người dùng cấp quyền trong Cài đặt DeskPet → Điều khiển máy: **Accessibility**, **Screen Recording**.
   Bảng quyền đầy đủ ở README → "Cài trên máy mới". Không tự sửa TCC.
5. Tuỳ chọn, chỉ khi người dùng muốn: Cài đặt → Phiên ngoài DeskPet → bật hook (sửa `~/.claude/settings.json` của máy đó).

Cài đặt/phiên/trí nhớ trợ lý là dữ liệu cục bộ từng máy (UserDefaults `com.deskpet.app`,
`~/Library/Application Support/DeskPet/`, `~/DeskPet/`) — không nằm trong repo.

## Build & lỗi môi trường

- `./build.sh` (release → `build/DeskPet.app`), `./build.sh debug`, `./build.sh run`, `./build.sh install`.
  Build bằng `swiftc` trực tiếp, `-swift-version 5`, target macOS 13; SwiftPM (`Package.swift`) chỉ là phương án phụ.
- SDK mới hơn compiler (vd. SDK 26.x + Swift 6.1 → "this SDK is not supported by the compiler"):
  `build.sh` tự chuyển sang `MacOSX15.sdk`. Thiếu SDK đó → bảo người dùng cập nhật CLT.
- CLT 16.3 thừa `module.modulemap` → `build.sh` che bằng VFS overlay. Không sửa file hệ thống.
- App ký ad-hoc: mỗi lần build lại có thể mất quyền Accessibility/Screen Recording — nói trước với người dùng.
- `./build.sh install` sẽ **tắt và mở lại DeskPet** đang chạy (các phiên tự resume) — báo người dùng trước khi chạy.

## Test

- Dùng file chạy trần `.build/direct/DeskPet`. File trong bundle mới ký có thể đứng im vài phút (macOS quét) — không phải lỗi.
- MCP: `printf '%s\n' '<json-rpc>' … | .build/direct/DeskPet --mcp` (mỗi dòng một request: `tools/list`, `tools/call`).
  Chỉ thử tool vô hại (`system_status`, `list_windows`, `screenshot`, `list_sessions`); **không** click/gõ/gửi vào phiên thật.
- Gõ vào iTerm: thử trên cửa sổ iTerm tạm chạy `/bin/cat -v`, không gõ vào phiên Claude thật của người dùng.
- Hook trạng thái: **không thử trên `~/.claude/settings.json` thật**. Dựng harness: chép `Sources/DeskPet/*.swift` trừ
  `main.swift` + một `main.swift` gọi `StatusHooks.setEnabled(_, roots: [<thư mục profile tạm>])`, chạy với
  `DESKPET_SUPPORT_DIR=<thư mục tạm>`, rồi gọi lệnh hook bằng `/bin/sh -c` với JSON giả trên stdin.
- Giao diện: `DESKPET_SUPPORT_DIR=<tạm> .build/direct/DeskPet --snapshot <thư mục>` render PNG (pet, bảng phiên,
  `dashboard_external.png` nếu đang có phiên claude ngoài DeskPet) — xem ảnh để kiểm tra, không cần mở app.
  Luôn đặt `DESKPET_SUPPORT_DIR` tạm: snapshot tạo phiên mẫu và sẽ ghi đè danh sách phiên thật nếu dùng thư mục mặc định.
- Sau khi sửa `ExternalSessions`, chạy lại `list_sessions` qua `--mcp` để chắc vẫn thấy phiên ngoài (lỗi tách cột `ps` từng làm mất hết).
- Lệnh dev khác (`--selftest`, `--assistant`, `--snapshot`, `--sessions`…): README → "Công cụ dev".
- Trong phiên Claude Code có hook RTK: dùng đường dẫn tuyệt đối (`/bin/ps`, `/usr/bin/grep`) nếu kết quả `ps`/`grep` lạ.

## Bản đồ mã (`Sources/DeskPet/`)

| File | Vai trò |
|---|---|
| `main.swift` | Điểm vào; các chế độ CLI (`--mcp`, `--selftest`, `--snapshot`) chạy trước NSApplication |
| `AppDelegate.swift` | Pet panel, chat, toast, thông báo, menu bar 🐾 (gồm menu "Điều khiển máy") |
| `SessionRunner.swift` | Một phiên `claude -p --input-format stream-json …`; xin quyền qua `control_request can_use_tool`; `autoDecide` |
| `SessionManager.swift` | Danh sách phiên, `state.json` cho MCP, lệnh từ MCP (DistributedNotification), cấu hình + system prompt trợ lý, cảnh báo |
| `DeskPetMCP.swift` | MCP server stdio của trợ lý; tool cơ bản (`baseToolNames` → `--allowedTools`) |
| `ComputerControl.swift` | `ControlGroup`/`ControlMode`/`ControlPolicy` (mức quyền đọc thẳng UserDefaults) + tool điều khiển máy |
| `ExternalSessions.swift` | Dò `claude` chạy ngoài DeskPet (ps/lsof), gõ vào / focus tab iTerm-Terminal qua AppleScript |
| `DashboardView.swift` | Bảng phiên; nhóm "Ngoài DeskPet" (`ExternalRow`, `ExternalDetailView`) lấy từ `SessionManager.externalSessions` |
| `StatusHooks.swift` | Cài/gỡ hook trạng thái trong settings.json, đọc `hooks/*.json`; `ExternalMonitor` báo pet |
| `SessionHistory.swift` | Đọc transcript `~/.claude/projects/<thư mục mã hoá>/*.jsonl`, `ProjectIndex` |
| `Settings.swift` / `SettingsView.swift` | `AppSettings` (UserDefaults) và cửa sổ Cài đặt |
| `ChatModels.swift` | `ChatItem`, diff, `ToolDescriber` (mô tả tool tiếng Việt + icon) |
| `Voice.swift`, `HotKey.swift` | Nhận dạng/đọc tiếng Việt, phím ⌥ Space |
| `TerminalLauncher.swift`, `ClaudeLocator.swift`, `AccountProfile.swift`, `LoginItem.swift` | Mở Terminal, tìm `claude` + env, hồ sơ tài khoản, mở khi đăng nhập |

## Quy ước

- Chuỗi giao diện, comment, system prompt: tiếng Việt, giọng ngắn gọn như code hiện có.
- Thêm tool MCP: định nghĩa trong `DeskPetMCP.tools` (vô hại) hoặc `ComputerControl.tools` + `ControlGroup.tools`
  (điều khiển máy), thêm mô tả trong `ToolDescriber`, cập nhật `assistantPrompt` và bảng trong README.
- Tool điều khiển máy phải tôn trọng `ControlPolicy.mode` ở cả hai lớp: app (`autoDecide`) và MCP (từ chối khi Tắt).
- Sửa `settings.json` của Claude Code chỉ qua `StatusHooks` (giữ hook khác, có backup). Không đụng hook RTK của người dùng.
- Cập nhật README (và file này nếu cần) khi thêm tính năng — người dùng chạy project trên nhiều máy.
- Commit thì được; **push** để người dùng tự chạy (chế độ auto của Claude Code chặn push).
