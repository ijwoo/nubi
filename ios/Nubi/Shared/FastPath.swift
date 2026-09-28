import Foundation

/// 모델을 거치지 않고 바로 답하는 몇 마디.
///
/// **갈래는 모델이 고릅니다.** 다만 잠금화면 버튼과 추천 칩이 보내는 말은 정해져
/// 있고, 그건 두 자리 밀리초에 끝납니다. 그 몇 개까지 왕복을 태우면 잠금화면에서
/// 오늘 일정을 보는 데 2초가 걸립니다.
///
/// **정확히 같을 때만** 걸립니다. 비슷하면 모델로 보냅니다 — 규칙으로 비슷함을
/// 판정하려던 것이 지금까지의 문제였습니다.
enum FastPath {
    private static let known: [String: NubiIntent] = [
        "오늘 일정": .events(offset: 0, span: 1, label: "오늘"),
        "내일 일정": .events(offset: 1, span: 1, label: "내일"),
        "모레 일정": .events(offset: 2, span: 1, label: "모레"),
        "이번 주 일정": .events(offset: 0, span: 7, label: "이번 주"),
        "오늘 할일": .reminders,
        "할일": .reminders,
    ]

    static func match(_ utterance: String) -> NubiIntent? {
        known[utterance.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}
