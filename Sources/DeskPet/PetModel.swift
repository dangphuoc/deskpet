import Foundation

enum PetMood: Equatable {
    case idle
    case walking
    case thinking            // Claude đang xử lý, chưa có output
    case working(String)     // đang dùng tool — kèm SF Symbol của tool
    case talking             // text đang stream về
    case permission          // chờ người dùng cho phép
    case happy               // xong việc
    case error
    case sleeping
    case listening           // đang nghe bạn nói
}

/// Hoạt động từ phía Claude mà con pet cần phản ứng.
enum PetActivity {
    case thinking, talking, working(String), permission, done, failed
    /// Không còn phiên nào bận — thôi trạng thái làm việc.
    case idle
    case listening
}

final class PetModel: ObservableObject {
    @Published private(set) var mood: PetMood = .idle
    @Published private(set) var moodStart = Date()
    @Published var movingLeft = false

    private(set) var busy = false
    private var lastInteraction = Date()
    private var nextWalkAt = Date().addingTimeInterval(8)

    private func set(_ m: PetMood) {
        guard m != mood else { return }
        mood = m
        moodStart = Date()
    }

    func handle(_ activity: PetActivity) {
        lastInteraction = Date()
        switch activity {
        case .thinking: busy = true; set(.thinking)
        case .talking: busy = true; set(.talking)
        case .working(let icon): busy = true; set(.working(icon))
        case .permission: busy = true; set(.permission)
        case .done: busy = false; set(.happy)
        case .failed: busy = false; set(.error)
        case .listening: set(.listening)
        case .idle:
            busy = false
            switch mood {
            case .thinking, .working, .talking, .permission, .listening: set(.idle)
            default: break
            }
        }
    }

    func poke() {
        lastInteraction = Date()
        if mood == .sleeping || mood == .walking { set(.idle) }
        nextWalkAt = Date().addingTimeInterval(.random(in: 6...14))
    }

    func startWalking(left: Bool) {
        movingLeft = left
        set(.walking)
    }

    func stopWalking() {
        if mood == .walking { set(.idle) }
        nextWalkAt = Date().addingTimeInterval(.random(in: 8...20))
    }

    /// Gọi định kỳ; trả về true nếu tới lúc nên đi dạo.
    func tick(sleepAfter: TimeInterval, canWalk: Bool) -> Bool {
        let now = Date()
        let inMood = now.timeIntervalSince(moodStart)
        switch mood {
        case .happy where inMood > 4, .error where inMood > 5:
            set(.idle)
        case .idle:
            if now.timeIntervalSince(lastInteraction) > sleepAfter {
                set(.sleeping)
            } else if canWalk && now >= nextWalkAt {
                return true
            }
        default:
            break
        }
        return false
    }
}
