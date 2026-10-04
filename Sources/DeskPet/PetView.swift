import SwiftUI

/// Một khung hình của nhân vật: tư thế + biến đổi tạo chuyển động.
struct PetFrame {
    var pose: Pose = .standing
    var dx: CGFloat = 0
    var dy: CGFloat = 0          // âm = nhảy lên
    var rotation: Double = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var flip = false
}

enum PetAnimator {
    static func frame(mood: PetMood, character: PetCharacter, movingLeft: Bool,
                      t: Double, elapsed: Double, size: CGFloat) -> PetFrame {
        var f = PetFrame()
        let u = size / 120 // biên độ tỉ lệ theo kích thước
        switch mood {
        case .idle:
            // Thở nhẹ; thỉnh thoảng vẫy tay chào.
            let breath = sin(t * 2.2)
            f.scaleY = 1 + 0.022 * breath
            f.scaleX = 1 - 0.012 * breath
            let cycle = elapsed.truncatingRemainder(dividingBy: 14)
            if cycle > 10 && cycle < 12 {
                f.pose = .talking
                f.rotation = sin(t * 9) * 3
            }
        case .walking:
            f.pose = .moving
            let step = t * 7
            f.dy = -abs(sin(step)) * 7 * u
            f.rotation = sin(step) * 4
            f.scaleY = 1 - 0.04 * abs(cos(step))
            switch character.walkFacing {
            case .left: f.flip = !movingLeft
            case .right: f.flip = movingLeft
            case .front: f.flip = false
            }
        case .thinking, .working:
            f.pose = .inspecting
            f.rotation = sin(t * 1.8) * 6
            f.dx = sin(t * 1.8) * 3 * u
            f.dy = -abs(sin(t * 3.6)) * 2 * u
        case .talking:
            f.pose = .talking
            let b = sin(t * 11)
            f.scaleY = 1 + 0.03 * b
            f.scaleX = 1 - 0.015 * b
            f.rotation = sin(t * 3) * 2
        case .permission:
            f.pose = .pointing
            let p = sin(t * 5)
            f.dx = p * 3 * u
            f.rotation = p * 2
        case .happy:
            f.pose = .laughing
            let j = abs(sin(t * 7.5))
            f.dy = -j * 16 * u
            f.scaleY = 1 + 0.05 * j
            f.scaleX = 1 - 0.03 * j
            f.rotation = sin(t * 3.75) * 5
        case .error:
            f.pose = .oops
            if elapsed < 0.7 { f.dx = sin(elapsed * 60) * 5 * u * (1 - elapsed / 0.7) }
            f.scaleY = 1 + 0.015 * sin(t * 2)
        case .listening:
            // Nghiêng đầu lắng nghe
            f.pose = .standing
            f.rotation = -5 + sin(t * 2) * 2
            f.scaleY = 1 + 0.015 * sin(t * 4)
        case .sleeping:
            f.pose = .sitting
            let breath = sin(t * 1.3)
            f.scaleY = 1 + 0.03 * breath
            f.scaleX = 1 + 0.012 * breath
        }
        return f
    }
}

struct PetView: View {
    @ObservedObject var model: PetModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        let size = CGFloat(settings.petSize)
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let elapsed = ctx.date.timeIntervalSince(model.moodStart)
            let f = PetAnimator.frame(mood: model.mood, character: settings.character,
                                      movingLeft: model.movingLeft, t: t, elapsed: elapsed, size: size)
            ZStack(alignment: .bottom) {
                // Bóng dưới chân, nhỏ lại khi nhảy lên.
                Ellipse()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: size * 0.55 * (1 + f.dy / (size * 0.6)), height: size * 0.07)
                    .blur(radius: 2)
                    .offset(y: -2)

                if let img = CharacterLibrary.image(settings.character, f.pose) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size, alignment: .bottom)
                        .scaleEffect(x: f.flip ? -f.scaleX : f.scaleX, y: f.scaleY, anchor: .bottom)
                        .rotationEffect(.degrees(f.rotation), anchor: .bottom)
                        .offset(x: f.dx, y: f.dy - size * 0.03)
                }

                accessory(t: t, elapsed: elapsed, size: size)
                    .offset(x: size * 0.42, y: -size * 1.0)
            }
            .frame(width: size * 1.6, height: size * 1.55, alignment: .bottom)
        }
    }

    @ViewBuilder
    private func accessory(t: Double, elapsed: Double, size: CGFloat) -> some View {
        let fs = max(12, size * 0.16)
        switch model.mood {
        case .sleeping:
            ZStack {
                ForEach(0..<3) { i in
                    let phase = (t * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Text("z")
                        .font(.system(size: fs * (0.7 + phase * 0.6), weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(red: 0.35, green: 0.45, blue: 0.8))
                        .opacity(1 - phase)
                        .offset(x: phase * size * 0.2, y: -phase * size * 0.35 + size * 0.15)
                }
            }
        case .thinking:
            bubble {
                HStack(spacing: fs * 0.18) {
                    ForEach(0..<3) { i in
                        Circle()
                            .frame(width: fs * 0.32, height: fs * 0.32)
                            .offset(y: -abs(sin(t * 5 + Double(i) * 0.7)) * fs * 0.25)
                    }
                }
                .foregroundStyle(.secondary)
            }
        case .working(let icon):
            bubble {
                Image(systemName: icon)
                    .font(.system(size: fs * 0.8, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .rotationEffect(.degrees(sin(t * 4) * 8))
            }
        case .listening:
            bubble {
                HStack(spacing: 2) {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                    ForEach(0..<4) { i in
                        Capsule().fill(Color.red.opacity(0.7))
                            .frame(width: fs * 0.12, height: fs * (0.25 + 0.45 * abs(sin(t * 9 + Double(i) * 1.3))))
                    }
                }
                .font(.system(size: fs * 0.7, weight: .semibold))
            }
        case .permission:
            bubble {
                Text("!")
                    .font(.system(size: fs, weight: .black, design: .rounded))
                    .foregroundStyle(.orange)
            }
            .scaleEffect(1 + 0.12 * abs(sin(t * 4)))
        case .happy:
            ZStack {
                ForEach(0..<3) { i in
                    Image(systemName: "sparkle")
                        .font(.system(size: fs * 0.8))
                        .foregroundStyle(.yellow)
                        .opacity(0.5 + 0.5 * sin(t * 6 + Double(i) * 2))
                        .offset(x: CGFloat(i - 1) * size * 0.28 - size * 0.4, y: CGFloat(i % 2) * size * 0.15)
                }
            }
        default:
            EmptyView()
        }
    }

    private func bubble<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            )
            .environment(\.colorScheme, .light)
    }
}
