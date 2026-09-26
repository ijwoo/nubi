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

    /// 위치를 한 번 갱신합니다.
    ///
    /// **확장은 위치를 물을 수 없습니다.** 잠금화면 버튼이 장소를 찾으려면 앱이
    /// 마지막으로 알던 자리가 있어야 합니다.
    func refreshPlace() async {
        // 이미 허용한 경우에만 조용히 갱신합니다. 앱을 켜자마자 권한 창이 뜨는
        // 것은 무례합니다 — 처음 묻는 것은 시작하기 카드와 첫 장소 질문이 맡습니다.
        guard Places.isAllowed else { return }
        await Places.refreshLocation()
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
    /// 잠금화면 대화창의 오브와 같은 색입니다. 두 화면이 한 물건으로 보여야 합니다.
    static let accent = Color(red: 0.36, green: 0.35, blue: 0.85)
    static let done = Color(red: 0.06, green: 0.71, blue: 0.51)
    static let warn = Color(red: 0.96, green: 0.62, blue: 0.07)
    static let mine = Color(red: 0.36, green: 0.35, blue: 0.85).opacity(0.14)
    static let surface = Color.primary.opacity(0.06)
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
