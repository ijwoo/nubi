import SwiftUI
import UIKit

@main
struct NubiApp: App {
    @State private var store = Store()

    init() { Secrets.migrateFromKeychain() }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                // **어두운 쪽으로 못 박습니다.** 잠금화면 대화창이 검은 판인데
                // 앱만 밝으면 두 화면이 다른 물건으로 보입니다. 밝은 모드를
                // 따라가게 두면 사람마다 다른 물건을 쓰게 됩니다.
                .preferredColorScheme(.dark)
                .tint(Ink.accent)
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

/// 이 앱의 색. **강조는 하나만 씁니다.**
///
/// 잠금화면 대화창이 검은 판에 회색 말풍선입니다. 앱이 거기 맞춰 갑니다 —
/// 두 화면이 한 물건으로 보여야 합니다.
///
/// **밝은 판은 고르지 않았습니다.** 위젯은 배경을 흐릴 수 없어서, 잠금화면에서
/// 밝은 판은 배경화면에 따라 읽히는 정도가 달라집니다. 검은 판으로 못 박은
/// 것이 그 때문이고, 앱이 그쪽으로 옵니다.
enum Ink {
    /// 화면 바닥.
    static let ground = Color(red: 0.035, green: 0.035, blue: 0.043)
    /// 카드와 입력줄.
    static let surface = Color(red: 0.086, green: 0.086, blue: 0.102)
    /// 카드 테두리.
    static let edge = Color(red: 0.165, green: 0.165, blue: 0.192)
    static let accent = Color(red: 0.424, green: 0.412, blue: 0.878)
    static let done = Color(red: 0.09, green: 0.745, blue: 0.545)
    static let warn = Color(red: 0.941, green: 0.639, blue: 0.169)
    /// 내가 한 말. 강조색을 머금은 어두운 보라입니다.
    static let mine = Color(red: 0.173, green: 0.169, blue: 0.278)
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
