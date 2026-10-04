# DeskPet 🐾

Linh vật nổi trên màn hình macOS, làm giao diện cho **Claude Code CLI**.

## Bật / tắt

App đã cài ở **`/Applications/DeskPet.app`** và **tự bật khi đăng nhập**.

| Việc | Cách |
|---|---|
| **Bật** | Spotlight (⌘Space) gõ "DeskPet", hoặc Launchpad / Finder → Applications |
| **Tắt** | Icon 🐾 trên menu bar → **Thoát DeskPet** (hoặc chuột phải vào pet → Thoát DeskPet) |
| Tắt khi bị treo | `pkill -x DeskPet` |
| Tự bật khi đăng nhập | Cài đặt DeskPet → "Mở khi đăng nhập" (hoặc System Settings → General → Login Items) |
| Cập nhật sau khi sửa code | `./build.sh install` (build, chép đè vào /Applications, mở lại) |

App không có icon ở Dock — chỉ có con pet trên màn hình và icon 🐾 trên menu bar.
Thoát app sẽ tắt luôn các tiến trình `claude` của các phiên; danh sách phiên được lưu lại,
lần bật sau nhắn tiếp là tự `--resume`.

## Build & chạy

```sh
./build.sh          # build/DeskPet.app (release)
./build.sh run      # build rồi mở bản trong build/ (để thử nhanh)
./build.sh install  # build, cài vào /Applications rồi mở
./build.sh debug    # bản debug
```

Build bằng `swiftc` trực tiếp (Command Line Tools là đủ, không cần Xcode).
`Package.swift` vẫn có cho máy có SwiftPM hoạt động bình thường (`swift build`).

> Command Line Tools 16.3 có lỗi để thừa `usr/include/swift/module.modulemap`
> (trùng module `SwiftBridging`) khiến mọi `import AppKit` hỏng. `build.sh` tự phát hiện
> và che file đó bằng VFS overlay — không sửa file hệ thống. Cách sửa tận gốc là cài lại CLT.

## Dùng

| Thao tác | Kết quả |
|---|---|
| **Giữ ⌥ Space** | **Nói** với trợ lý (tiếng Việt), thả ra là gửi; trợ lý đọc to câu trả lời |
| **⌥ Space** (nhấn nhanh) | Bong bóng **trợ lý** cạnh pet: "mở nhạc lofi", "mở Gmail", "phiên nào đang chờ mình?", "trong service-bank-v3 chạy test ekyc" |
| **Double-click** pet | **Bảng phiên**: nhiều phiên Claude Code chạy song song, thay cho 10 cửa sổ terminal |
| Bấm pet khi có "!" | Nhảy thẳng tới phiên đang cần bạn |
| Kéo thả / chuột phải | Di chuyển / menu |
| ⌘N trong bảng phiên | Phiên mới: chọn project (lấy từ `~/.claude/projects`), tiếp tục phiên cũ hoặc bắt đầu mới |

### Bảng phiên
- Cột trái chia nhóm **Cần bạn** (chờ cho phép / chờ trả lời) · **Đang làm** · **Xong · chưa xem** · Khác.
- Mỗi phiên: thẻ **Cho phép / Từ chối** có **diff** khi sửa file, thẻ **câu hỏi** (AskUserQuestion),
  bảng **việc cần làm** (TodoWrite / TaskCreate), nút **dừng** (như Esc), **phiên cũ** của thư mục,
  **mở trong Terminal** (`claude --resume`) khi cần giao diện đầy đủ.
- Phiên nào cần bạn / xong việc → pet phản ứng, bong bóng thông báo cạnh pet, thông báo macOS, số đếm trên menu bar.
- "Đóng phiên" chỉ bỏ khỏi danh sách — transcript của Claude Code vẫn còn, resume lại được.

### Trợ lý
Phiên Claude Code riêng chạy trong thư mục nhà **`~/DeskPet`** (đổi được trong Cài đặt):

- `~/DeskPet/CLAUDE.md` — **trí nhớ** của trợ lý, Claude Code tự đọc mỗi lần chạy. Bạn sửa tay thoải mái,
  hoặc nói "nhớ giúp mình …" để trợ lý ghi thêm vào mục "Ghi nhớ" (vẫn hỏi Cho phép trước khi ghi).
- `~/DeskPet/notes/` — ghi chú, tóm tắt, bản nháp trợ lý viết cho bạn.

Phiên trợ lý có thêm MCP server
của DeskPet (`DeskPet --mcp`), các tool **được chạy không cần hỏi** vì vô hại:

| Tool | Việc |
|---|---|
| `open_url` (chỉ http/https/mailto), `open_app`, `play_youtube`, `open_search` | Mở web / app / nhạc |
| `list_sessions`, `get_session` | Xem trạng thái & nội dung các phiên |
| `find_projects`, `list_project_sessions` | Tìm project, phiên cũ |
| `start_session`, `send_to_session`, `focus_session` | Điều phối phiên (phiên đó vẫn hỏi bạn trước khi sửa file/chạy lệnh) |

Trợ lý được dặn không tự sửa code; việc trong project thì mở phiên riêng.

### Phiên ngoài DeskPet (iTerm / Terminal)
- Trợ lý thấy cả các phiên `claude` chạy ngoài DeskPet (`list_sessions`, `get_session`) và gõ được vào phiên
  trong iTerm / Terminal (`send_to_session`); chưa có phiên nào chạy cho project thì tự mở phiên trong DeskPet.
- **Cài đặt → Phiên ngoài DeskPet → Theo dõi chính xác** (mặc định tắt): thêm hook báo trạng thái
  (`SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`) vào `settings.json` của mọi hồ sơ.
  Pet báo khi phiên ngoài cần cho phép / làm xong; bấm thông báo là nhảy tới đúng tab. Hook khác giữ nguyên,
  có bản sao `settings.json.deskpet-backup`, tắt là gỡ sạch. Chỉ áp dụng cho phiên mở sau khi bật.

### Điều khiển máy
Trợ lý điều khiển được máy Mac qua các tool MCP thêm, chia 4 nhóm. Mỗi nhóm có mức **Tắt / Hỏi trước / Tự chạy**,
đổi ở **Cài đặt → Điều khiển máy** hoặc **menu 🐾 → Điều khiển máy**; đổi là có hiệu lực ngay, không cần khởi động lại.

| Nhóm | Tool | Mặc định |
|---|---|---|
| Nhìn màn hình | `screenshot`, `list_windows` | Tự chạy |
| Chuột, bàn phím & thoát app | `mouse_click`, `scroll`, `type_text`, `key_press`, `quit_app` | Hỏi trước |
| AppleScript & lệnh terminal | `run_applescript`, `Bash` của Claude Code | Hỏi trước |
| Hệ thống | `system_status`, `set_volume`, `set_dark_mode`, `lock_screen`, `sleep_display` | Tự chạy |

Cần cấp cho DeskPet quyền **Accessibility** (chuột/phím) và **Screen Recording** (chụp màn hình) — có nút
"Cấp quyền…" trong Cài đặt. App ký ad-hoc nên sau mỗi lần build lại có thể phải cấp lại.

### Giọng nói
- Nhận dạng: Speech framework, `vi-VN` (máy chưa có gói tiếng Việt on-device → âm thanh gửi lên Apple để nhận dạng).
- Đọc to: `AVSpeechSynthesizer`, giọng tiếng Việt tốt nhất có trên máy (Linh). Tắt trong Cài đặt → Giọng nói.
- Quyền Micro + Speech Recognition hỏi ở lần đầu; app ký ad-hoc nên sau mỗi lần cài lại có thể bị hỏi lại.

### Tài khoản Claude (hồ sơ)
Mỗi hồ sơ = một thư mục cấu hình Claude Code (`CLAUDE_CONFIG_DIR`) với đăng nhập, settings, skills, lịch sử phiên riêng.
"Mặc định" = `~/.claude`. Cài đặt → Tài khoản Claude: thêm hồ sơ → "Đăng nhập…" (mở Terminal, gõ `/login`).
Chọn hồ sơ khi tạo phiên mới, hoặc nói với trợ lý "mở phiên ở X bằng tài khoản cá nhân".

### Remote Control
Nút 📡 trên phiên (hoặc nói "bật remote control"): mở phiên trong Terminal bằng
`claude --resume <id> --remote-control "<tên phiên>"` để điều khiển từ điện thoại / claude.ai.
Trong lúc đó DeskPet không gõ vào phiên này; đóng Terminal là dùng lại trong DeskPet.

## Cách nói chuyện với Claude

Mỗi phiên giữ **một tiến trình sống liên tục** (rảnh 15 phút thì tự tắt, lần sau `--resume`):

```
claude -p --input-format stream-json --output-format stream-json --verbose \
       --include-partial-messages --permission-prompt-tool stdio \
       --permission-mode default [--resume <session_id>]
```

Mỗi tin nhắn là một dòng JSON ghi vào **stdin**; dừng giữa chừng = `control_request` `interrupt`.
Cơ chế xin quyền cũng cần stdin mở:
khi Claude muốn dùng tool chưa được phép, CLI in ra `control_request` (`subtype: can_use_tool`)
và chờ app ghi lại `control_response` với `behavior: "allow"` / `"deny"`. Đây là giao thức
Agent SDK dùng — không cần dựng MCP server riêng cho `--permission-prompt-tool`.

`--permission-mode default` ép chế độ hỏi quyền kể cả khi settings của bạn đặt mặc định khác.
Luật `allow`/`deny` trong `~/.claude/settings.json` và `.claude/settings*.json` của project vẫn
áp dụng: tool đã được allow sẵn sẽ chạy không hỏi.

### Phiên & resume theo thư mục

- Mỗi thư mục làm việc nhớ `session_id` riêng. Chọn thư mục khác → app tự nạp phiên gần nhất
  của thư mục đó (hiện lại lịch sử chat), tin nhắn tiếp theo chạy `--resume <id>`.
- Nút 🕘 trên khung chat liệt kê **mọi** phiên Claude Code của thư mục, đọc từ
  `~/.claude/projects/<đường-dẫn-mã-hoá>/*.jsonl` — gồm cả phiên bạn chạy `claude` trong terminal.
  Chọn một phiên để tiếp tục nó.
- Nút ✎ → phiên mới cho thư mục hiện tại.
- Tránh resume cùng lúc một phiên đang mở trong terminal: hai bên sẽ ghi xen kẽ vào cùng transcript.

## Công cụ dev

```sh
.build/direct/DeskPet --selftest "<tin 1>" "<tin 2>" [--deny] # nhiều lượt trong 1 tiến trình, tự cho phép/từ chối
.build/direct/DeskPet --assistant "<tin nhắn>"               # hỏi trợ lý (có MCP DeskPet)
DESKPET_SUPPORT_DIR=/tmp/x …                                 # chạy test với dữ liệu riêng
/Applications/DeskPet.app/Contents/MacOS/DeskPet --login-item on|off|status
.build/direct/DeskPet --tts-check "<câu>"                    # thử đọc to (không phát loa)
/Applications/DeskPet.app/Contents/MacOS/DeskPet --stt-file <audio>   # thử nhận dạng tiếng Việt từ file
.build/direct/DeskPet --snapshot <thư mục>                   # render các trạng thái ra PNG
.build/direct/DeskPet --sessions <thư mục>                   # in danh sách phiên cũ của thư mục
python3 tools/slice_sheet.py <sheet.png> Resources/Characters # cắt lại sprite từ sheet 4×8
```
