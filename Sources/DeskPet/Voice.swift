import AVFoundation
import Speech

/// Giọng nói: giữ ⌥Space để nói (Speech framework, tiếng Việt), đọc to câu trả lời (AVSpeechSynthesizer).
final class VoiceController: NSObject, ObservableObject {
    static let shared = VoiceController()

    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var isSpeaking = false
    @Published var lastError: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishHandler: ((String) -> Void)?
    /// Người dùng còn muốn nghe không (false khi đã thả phím / bấm dừng, kể cả trước khi mic kịp mở).
    private var wantsListening = false
    private var sessionToken = 0
    private static let maxDuration: TimeInterval = 60
    /// Im lặng bao lâu (sau khi đã nghe được chữ) thì tự chốt câu và gửi.
    private static let silenceTimeout: TimeInterval = 2.5
    private var silenceWork: DispatchWorkItem?
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Nghe

    /// Bắt đầu nghe. `onFinish` nhận câu nói cuối cùng khi gọi `stopListening()`.
    func startListening(onFinish: @escaping (String) -> Void) {
        guard !isListening, !wantsListening else { return }
        stopSpeaking()
        lastError = nil
        transcript = ""
        finishHandler = onFinish
        wantsListening = true
        sessionToken += 1
        let token = sessionToken
        let askedAt = Date()
        requestPermissions { [weak self] ok, message in
            guard let self, token == self.sessionToken else { return }
            guard ok else { self.wantsListening = false; self.finishHandler = nil; self.lastError = message; return }
            // Đã thả phím trong lúc chờ (thường là lúc macOS hỏi quyền lần đầu) → không tự nghe.
            guard self.wantsListening else {
                self.finishHandler = nil
                if Date().timeIntervalSince(askedAt) > 1 {
                    self.lastError = "Đã có quyền micro — giữ ⌥Space và nói lại nhé."
                }
                return
            }
            do { try self.beginRecognition() } catch {
                self.lastError = "Không mở được micro: \(error.localizedDescription)"
                self.cleanup()
            }
        }
    }

    /// Thả phím: dừng thu âm, đợi nhận dạng chốt câu rồi gọi onFinish.
    func stopListening() {
        wantsListening = false
        guard isListening else {
            finishHandler = nil
            return
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Cho nhận dạng tối đa 1.5s để trả kết quả cuối.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.deliver() }
    }

    private func beginRecognition() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "DeskPet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "nhận dạng tiếng Việt đang không dùng được (cần mạng?)"])
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isListening = true
        // Chốt an toàn: không bao giờ nghe quá 60 giây.
        let token = sessionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxDuration) { [weak self] in
            guard let self, self.isListening, token == self.sessionToken else { return }
            self.stopListening()
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self.deliver(); return }
                    self.armSilenceTimer()
                }
                if error != nil, self.isListening == false { self.deliver() }
            }
        }
    }

    /// Mỗi lần nghe thêm chữ thì đặt lại đồng hồ; im đủ lâu → tự gửi (không cần thả phím / Enter).
    private func armSilenceTimer() {
        silenceWork?.cancel()
        guard isListening, !transcript.isEmpty else { return }
        let token = sessionToken
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isListening, token == self.sessionToken else { return }
            self.stopListening()
        }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silenceTimeout, execute: work)
    }

    private func deliver() {
        guard let handler = finishHandler else { return }
        finishHandler = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup()
        handler(text)
    }

    private func cleanup() {
        silenceWork?.cancel()
        silenceWork = nil
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        wantsListening = false
    }

    private func requestPermissions(_ done: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    done(false, "Chưa có quyền Nhận dạng giọng nói — bật trong System Settings → Privacy & Security → Speech Recognition.")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    done(granted, granted ? nil : "Chưa có quyền Micro — bật trong System Settings → Privacy & Security → Microphone.")
                }
            }
        }
    }

    // MARK: - Đọc to

    func speak(_ markdown: String) {
        let text = Self.plainText(markdown)
        guard !text.isEmpty else { return }
        stopSpeaking()
        let u = AVSpeechUtterance(string: String(text.prefix(900)))
        u.voice = Self.vietnameseVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(u)
    }

    func stopSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Giọng tiếng Việt tốt nhất có trên máy (ưu tiên bản Enhanced/Premium nếu đã tải).
    static let vietnameseVoice: AVSpeechSynthesisVoice? = {
        let vi = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("vi") }
        return vi.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "vi-VN")
    }()

    /// Bỏ markdown, link, code để đọc cho tự nhiên.
    static func plainText(_ md: String) -> String {
        var s = md
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (đoạn code) ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "https?://\\S+", with: "đường link", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_`#>|]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\s*[-•]\\s+", with: "", options: .regularExpression)
        s = s.unicodeScalars.filter { !($0.properties.isEmojiPresentation) }.map(String.init).joined()
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }
}
