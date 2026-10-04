# DeskPet 🐾

Linh vật nổi trên màn hình macOS, làm giao diện cho **Claude Code CLI**.

## Cài trên máy mới

Cần: macOS 13+, **Command Line Tools** (`xcode-select --install`; không cần Xcode),
**Claude Code CLI** đã cài và đăng nhập (`claude` chạy được trong terminal).

```sh
git clone git@github.com:dangphuoc/deskpet.git && cd deskpet
./build.sh install        # build, chép vào /Applications, mở app
```

Lần đầu mở trên mỗi máy:

1. **"Apple could not verify DeskPet…"** (app ký ad-hoc, không phải malware): bấm *Done* →
   System Settings → Privacy & Security → kéo xuống → **Open Anyway**.
   (`build.sh install` đã tự gỡ cờ quarantine nên thường chỉ gặp khi chép app từ máy khác.)
2. **Cấp quyền** (macOS hỏi dần, hoặc vào Cài đặt DeskPet → Điều khiển máy → "Cấp quyền…"):

   | Quyền | Để làm gì | Khi nào hỏi |
   |---|---|---|
   | Notifications | thông báo phiên cần bạn / xong | lần mở đầu |
   | Microphone + Speech Recognition | giữ ⌥ Space để nói | lần nói đầu |
   | **Accessibility** | trợ lý click / gõ phím | bấm "Cấp quyền…" |
   | **Screen Recording** | trợ lý chụp màn hình (thiếu → ảnh chỉ thấy hình nền) | bấm "Cấp quyền…" |
   | Automation → iTerm / Terminal / System Events | gõ vào phiên trong iTerm, đổi dark mode | lần dùng đầu |

   App ký ad-hoc → **mỗi lần build lại, macOS có thể coi là app mới** và đòi cấp lại Accessibility /
   Screen Recording. Nếu công tắc trong System Settings đã bật mà vẫn không chạy: bỏ DeskPet khỏi danh sách (–) rồi thêm lại.
3. **Theo dõi phiên ngoài DeskPet** (tuỳ chọn, theo từng máy vì sửa `~/.claude/settings.json` của máy đó):
   Cài đặt → Phiên ngoài DeskPet → bật. Xem [mục bên dưới](#phiên-ngoài-deskpet-iterm--terminal).
4. Tuỳ chọn: Cài đặt → "Mở khi đăng nhập"; Cài đặt → Tài khoản Claude nếu dùng nhiều tài khoản.

Cài đặt (nhân vật, hồ sơ, mức quyền điều khiển máy…) lưu trong UserDefaults `com.deskpet.app` của từng máy,
danh sách phiên ở `~/Library/Application Support/DeskPet/` — **không đồng bộ giữa các máy**.
Trí nhớ trợ lý ở `~/DeskPet/CLAUDE.md` (muốn dùng chung thì tự đồng bộ thư mục đó).

## Bật / tắt

Sau khi `./build.sh install`, app nằm ở **`/Applications/DeskPet.app`** (bật "Mở khi đăng nhập" trong Cài đặt để tự chạy).

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

`build.sh` tự xử lý 2 lỗi môi trường hay gặp:

- **SDK mới hơn compiler** — vd. CLT cài kèm SDK macOS 26.x nhưng `swiftc` là 6.1:
  `this SDK is not supported by the compiler … Please select a toolchain which matches the SDK`.
  Script thấy SDK ≥ 26 mà Swift < 6.2 thì dùng `MacOSX15.sdk` đi kèm (in dòng `▸ Swift … → dùng …`).
  Muốn chọn tay: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk ./build.sh`.
  Máy không có SDK 15 → cập nhật CLT (Software Update) để `swiftc` khớp SDK.
- **CLT 16.3** để thừa `usr/include/swift/module.modulemap` (trùng module `SwiftBridging`) khiến mọi
  `import AppKit` hỏng — script che file đó bằng VFS overlay, không sửa file hệ thống.

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

Phiên trợ lý có thêm MCP server của DeskPet (`DeskPet --mcp`, mã ở `DeskPetMCP.swift`).
Tool cơ bản **được chạy không cần hỏi** vì vô hại (liệt kê tường minh trong `--allowedTools`):

| Tool | Việc |
|---|---|
| `open_url` (chỉ http/https/mailto), `open_app`, `play_youtube`, `open_search` | Mở web / app / nhạc |
| `list_sessions`, `get_session` | Xem trạng thái & nội dung mọi phiên — trong DeskPet **và** đang chạy ngoài (iTerm/Terminal/IDE) |
| `find_projects`, `list_project_sessions`, `list_profiles` | Tìm project, phiên cũ, hồ sơ tài khoản |
| `send_to_session` | Gõ vào phiên: trong DeskPet → gõ thẳng; trong iTerm/Terminal → gõ vào đúng tab; chưa có phiên nào chạy → mở phiên trong DeskPet nối tiếp phiên gần nhất rồi gửi |
| `start_session`, `focus_session`, `clear_session`, `rename_session`, `remote_control` | Điều phối phiên (phiên đó vẫn hỏi bạn trước khi sửa file/chạy lệnh) |

Tool **điều khiển máy** (mục dưới) không nằm trong `--allowedTools`: mỗi lần gọi đi qua `SessionRunner.autoDecide`,
tra mức quyền hiện tại (Tắt → từ chối, Hỏi trước → thẻ Cho phép, Tự chạy → cho luôn).

Trợ lý được dặn không tự sửa code trong project (Bash chỉ cho việc trên máy); việc trong project thì mở phiên riêng.

### Phiên ngoài DeskPet (iTerm / Terminal)
- Trợ lý thấy cả các phiên `claude` chạy ngoài DeskPet (`list_sessions`, `get_session`) và gõ được vào phiên
  trong iTerm / Terminal (`send_to_session`); chưa có phiên nào chạy cho project thì tự mở phiên trong DeskPet.
- **Cài đặt → Phiên ngoài DeskPet → Theo dõi chính xác** (mặc định tắt): thêm hook báo trạng thái
  (`SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`) vào `settings.json` của mọi hồ sơ.
  Pet báo khi phiên ngoài cần cho phép / làm xong; bấm thông báo là nhảy tới đúng tab. Hook khác giữ nguyên,
  có bản sao `settings.json.deskpet-backup`, tắt là gỡ sạch. Chỉ áp dụng cho phiên mở sau khi bật.
- Cách hoạt động: hook chạy `~/Library/Application Support/DeskPet/hook.sh <sự kiện>`, ghi
  `…/DeskPet/hooks/<session_id>.json` (sự kiện mới nhất + pid claude + input của hook). App đọc thư mục đó mỗi 1,5 giây
  (`ExternalMonitor`), MCP đọc khi `list_sessions`. Hook nhận diện bằng chuỗi `#deskpet-status-hook` trong lệnh;
  phiên do DeskPet chạy có `DESKPET_SESSION=1` nên bị bỏ qua. Không có hook thì trạng thái chỉ là đoán theo giờ ghi transcript.
- Gõ vào iTerm/Terminal dùng AppleScript theo tty của tiến trình `claude`; prompt nhiều dòng được gộp một dòng
  (Enter là gửi). Phiên trong VS Code/IDE chỉ xem được — muốn điều khiển thì thoát ở đó rồi resume trong DeskPet.

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

Mẹo: test bằng file chạy trần `.build/direct/DeskPet` (build xong là có). Chạy file trong bundle
(`build/DeskPet.app/Contents/MacOS/DeskPet`) ngay sau khi build có thể **đứng im vài phút** do macOS
quét app mới ký — không phải lỗi code.

```sh
# Gọi thẳng MCP server (mỗi dòng một JSON-RPC) — test tool mà không cần Claude:
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"system_status","arguments":{}}}' \
  | .build/direct/DeskPet --mcp
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
