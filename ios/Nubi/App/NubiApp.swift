import SwiftUI

@main
struct NubiApp: App {
    init() { Secrets.migrateFromKeychain() }

    var body: some Scene {
        WindowGroup { ChatView() }
    }
}

/// 이 앱의 색. **하나만 씁니다.**
///
/// 아이콘과 잠금화면 대화창이 이미 청록이라 앱까지 같이 갑니다. 강조가 둘이면
/// 무엇이 중요한지 말하지 못합니다.
enum Ink {
    static let accent = Color.teal
    static let mine = Color.teal.opacity(0.16)
    static let theirs = Color.primary.opacity(0.06)
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
