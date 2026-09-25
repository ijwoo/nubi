import SwiftUI
import UIKit

@main
struct NubiApp: App {
    @State private var store = Store()

    init() { Secrets.migrateFromKeychain() }

    var body: some Scene {
        WindowGroup {
            HomeView().environment(store)
        }
    }
}

/// 앱과 잠금화면이 같이 쓰는 대화를 화면들이 같이 봅니다.
@Observable
final class Store {
    var turns: [Turn] = []
    var busy = false
    var liveIsOn = false

    func refresh() {
        turns = Thread.load()
        liveIsOn = LiveAnswer.isRunning
    }

    @MainActor
    func ask(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        await Nubi.turn(trimmed, viaIntent: false)
        refresh()
        busy = false
    }

    /// 대화창을 살립니다. **새로 만들 수 있는 것은 앞에 떠 있는 앱뿐입니다.**
    func revive() async {
        if let last = Thread.last {
            await LiveAnswer.show(last)
        } else {
            await LiveAnswer.welcome()
        }
        liveIsOn = LiveAnswer.isRunning
    }
}

/// 이 앱의 색. **하나만 씁니다.**
///
/// 아이콘과 잠금화면 대화창이 이미 청록이라 앱까지 같이 갑니다. 강조가 둘이면
/// 무엇이 중요한지 말하지 못합니다.
enum Ink {
    static let accent = Color.teal
    static let mine = Color.teal.opacity(0.16)
    static let surface = Color.primary.opacity(0.06)
    static let warn = Color.orange
}

/// 말풍선 모양. 말하는 쪽 아래 모서리만 눌러 방향을 줍니다.
struct Bubble: Shape {
    var mine: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 18, small: CGFloat = 5
        return UnevenRoundedRectangle(
            topLeadingRadius: big,
            bottomLeadingRadius: mine ? big : small,
            bottomTrailingRadius: mine ? small : big,
            topTrailingRadius: big,
            style: .continuous
        ).path(in: rect)
    }
}

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func done() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// 누르면 살짝 눌리는 버튼. 서랍과 카드에 씁니다.
struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

enum Stamp {
    static func of(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "a h:mm" : "M월 d일 a h:mm"
        return f.string(from: date)
    }
}
