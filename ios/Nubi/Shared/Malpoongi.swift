import SwiftUI

/// 말풍이. 잠금화면에서 상태를 전하는 얼굴.
///
/// **바탕 표정은 하나입니다.** 동그란 눈과 볼터치. 상태는 입과 눈썹과 색으로만
/// 갈립니다. 얼굴을 통째로 바꾸면 같은 캐릭터로 안 보입니다.
///
/// 듣는 얼굴에 소리 물결을 달아봤다가 뺐습니다. 물결은 마이크로 듣는다는
/// 뜻인데 누비는 소리를 듣지 않습니다. **하지 않는 일을 그리면 안 됩니다.**
///
/// **오브 하나로는 무슨 일이 일어나는지 말할 수 없었습니다.** 색만으로는
/// "듣는 중" 과 "생각 중" 이 구별되지 않습니다. 표정이 그 일을 합니다.
///
/// 그림 파일이 아니라 도형입니다. 잠금화면에서 18pt, 카드에서 34pt 로 쓰이는데
/// 비트맵은 작은 쪽에서 뭉개집니다. 작을 때는 볼터치와 눈빛을 빼서 형태만 남깁니다.
struct Malpoongi: View {
    enum Mood {
        case listening, thinking, done, waiting

        var fill: Color {
            switch self {
            case .listening, .thinking: Color(red: 0.97, green: 0.97, blue: 1.0)
            case .done: Color(red: 0.70, green: 0.94, blue: 0.88)
            case .waiting: Color(red: 0.99, green: 0.91, blue: 0.73)
            }
        }

        var badge: (symbol: String, color: Color)? {
            switch self {
            case .done: ("checkmark", Color(red: 0.06, green: 0.71, blue: 0.51))
            case .waiting: ("exclamationmark", Color(red: 0.96, green: 0.62, blue: 0.07))
            default: nil
            }
        }
    }

    var size: CGFloat
    var mood: Mood

    private var ink: Color { Color(red: 0.16, green: 0.16, blue: 0.24) }
    /// 작을 때는 형태만 남깁니다. 볼터치와 눈빛은 뭉개지기만 합니다.
    private var detailed: Bool { size >= 26 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                BubbleShape().fill(mood.fill)
                BubbleShape().stroke(ink, lineWidth: size * 0.055)
                Face(mood: mood, ink: ink, detailed: detailed)
            }
            .frame(width: size, height: size)

            if detailed, let badge = mood.badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: size * 0.2, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.34, height: size * 0.34)
                    .background(Circle().fill(badge.color))
                    .overlay(Circle().stroke(.white, lineWidth: size * 0.03))
                    .offset(x: size * 0.06, y: -size * 0.04)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 말풍선 몸통. 꼬리는 왼쪽 아래입니다.
private struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }
        let r: CGFloat = 0.24
        var path = Path()
        path.move(to: p(0.04 + r, 0.03))
        path.addLine(to: p(0.96 - r, 0.03))
        path.addQuadCurve(to: p(0.96, 0.03 + r), control: p(0.96, 0.03))
        path.addLine(to: p(0.96, 0.78 - r))
        path.addQuadCurve(to: p(0.96 - r, 0.78), control: p(0.96, 0.78))
        // 꼬리는 짧고 뭉툭해야 말풍선으로 읽힙니다. 길면 창처럼 보입니다.
        path.addLine(to: p(0.44, 0.78))
        path.addQuadCurve(to: p(0.19, 0.95), control: p(0.33, 0.88))
        path.addLine(to: p(0.28, 0.78))
        path.addLine(to: p(0.04 + r, 0.78))
        path.addQuadCurve(to: p(0.04, 0.78 - r), control: p(0.04, 0.78))
        path.addLine(to: p(0.04, 0.03 + r))
        path.addQuadCurve(to: p(0.04 + r, 0.03), control: p(0.04, 0.03))
        path.closeSubpath()
        return path
    }
}

/// 표정.
///
/// **바탕은 하나입니다** — 동그란 눈과 볼터치. 상태는 입과 눈썹으로만 갈립니다.
/// 얼굴을 통째로 바꾸면 같은 캐릭터로 안 보입니다.
private struct Face: View {
    let mood: Malpoongi.Mood
    let ink: Color
    let detailed: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // 생각할 때는 눈이 조금 올라갑니다. 위를 보는 얼굴입니다.
            let eyeY = h * (mood == .thinking ? 0.33 : 0.38)
            ZStack {
                if detailed {
                    cheek(at: CGPoint(x: w * 0.19, y: h * 0.50), w: w)
                    cheek(at: CGPoint(x: w * 0.81, y: h * 0.50), w: w)
                }

                if mood == .done {
                    arcEye(at: CGPoint(x: w * 0.34, y: eyeY), w: w)
                    arcEye(at: CGPoint(x: w * 0.66, y: eyeY), w: w)
                } else {
                    roundEye(at: CGPoint(x: w * 0.34, y: eyeY), w: w)
                    roundEye(at: CGPoint(x: w * 0.66, y: eyeY), w: w)
                }

                if mood == .waiting {
                    // 살짝 긴장한 눈썹. 안쪽 끝이 내려옵니다.
                    brow(at: CGPoint(x: w * 0.33, y: eyeY - h * 0.15), w: w, mirrored: false)
                    brow(at: CGPoint(x: w * 0.67, y: eyeY - h * 0.15), w: w, mirrored: true)
                }

                mouth(w: w, h: h)
            }
        }
    }

    @ViewBuilder
    private func mouth(w: CGFloat, h: CGFloat) -> some View {
        switch mood {
        case .thinking:
            // 말을 고르는 중. 입 자리에 점 셋이 옵니다.
            HStack(spacing: w * 0.055) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(ink).frame(width: w * 0.075, height: w * 0.075)
                }
            }
            .position(x: w * 0.5, y: h * 0.57)
        case .done:
            smile(w: w, h: h, wide: true)
        case .waiting:
            Capsule().fill(ink)
                .frame(width: w * 0.15, height: w * 0.05)
                .position(x: w * 0.5, y: h * 0.56)
        case .listening:
            smile(w: w, h: h, wide: false)
        }
    }

    private func roundEye(at point: CGPoint, w: CGFloat) -> some View {
        ZStack {
            Ellipse().fill(ink).frame(width: w * 0.15, height: w * 0.19)
            if detailed {
                Circle().fill(.white)
                    .frame(width: w * 0.05, height: w * 0.05)
                    .offset(x: -w * 0.025, y: -w * 0.04)
            }
        }
        .position(point)
    }

    private func arcEye(at point: CGPoint, w: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: w * 0.07))
            p.addQuadCurve(to: CGPoint(x: w * 0.17, y: w * 0.07),
                           control: CGPoint(x: w * 0.085, y: -w * 0.06))
        }
        .stroke(ink, style: StrokeStyle(lineWidth: w * 0.055, lineCap: .round))
        .frame(width: w * 0.17, height: w * 0.14)
        .position(point)
    }

    private func brow(at point: CGPoint, w: CGFloat, mirrored: Bool) -> some View {
        Capsule().fill(ink)
            .frame(width: w * 0.15, height: w * 0.042)
            .rotationEffect(.degrees(mirrored ? -13 : 13))
            .position(point)
    }

    private func smile(w: CGFloat, h: CGFloat, wide: Bool) -> some View {
        Path { p in
            let width = w * (wide ? 0.22 : 0.15)
            p.move(to: CGPoint(x: 0, y: 0))
            p.addQuadCurve(to: CGPoint(x: width, y: 0),
                           control: CGPoint(x: width / 2, y: w * (wide ? 0.14 : 0.1)))
        }
        .stroke(ink, style: StrokeStyle(lineWidth: w * 0.05, lineCap: .round))
        .frame(width: w * (wide ? 0.22 : 0.15), height: w * 0.1)
        .position(x: w * 0.5, y: h * 0.55)
    }

    private func cheek(at point: CGPoint, w: CGFloat) -> some View {
        Ellipse()
            .fill(Color(red: 1.0, green: 0.72, blue: 0.75).opacity(0.85))
            .frame(width: w * 0.16, height: w * 0.1)
            .position(point)
    }
}
